import { powerMonitor } from "electron";
import { execFile } from "node:child_process";
import { onLine, send } from "./native-helper";

/**
 * Battery as a live activity.
 *
 * The Swift sidecar (IOKit's power-source notification) says the instant the
 * charger comes or goes, and when Low Power Mode flips; `pmset` says how full
 * the battery is and which Energy Mode is set. powerMonitor is a fallback — it
 * stays silent on some macOS releases — and so is the minute poll, for a
 * checkout built without the sidecar. Whichever speaks first wins; the rest
 * see no change. One small spawn per minute on laptops, nothing on desktops
 * (no InternalBattery line → we publish null once and stop).
 */

export type PowerState = "charging" | "discharging" | "charged" | "ac";

/** System Settings → Battery → Energy Mode. The charge animation follows it. */
export type EnergyMode = "automatic" | "low" | "high";

export interface PowerReading {
  percent: number;
  state: PowerState;
  /** Minutes to empty (discharging) or to full (charging); null when unknown. */
  minutesRemaining: number | null;
}

export type PowerEvent = "plugged" | "unplugged" | null;

export interface PowerPayload extends PowerReading {
  /** Set on exactly one push — the transition itself — then null again. */
  event: PowerEvent;
  low: boolean;
  energyMode: EnergyMode;
}

/** Below this, on battery, the island keeps a small red battery in its wing. */
export const LOW_BATTERY_PERCENT = 20;

const BATTERY_LINE = /InternalBattery[^\n]*?\t(\d{1,3})%;\s*([^\n]*)/;

/** Parse `pmset -g batt`. Null when there is no internal battery (desktop Mac). */
export function parsePmset(stdout: string): PowerReading | null {
  const m = BATTERY_LINE.exec(stdout);
  if (!m) return null;
  const percent = Math.min(100, Math.max(0, Number(m[1])));
  const rest = m[2].toLowerCase();

  let state: PowerState;
  if (rest.includes("not charging")) state = "ac";
  else if (rest.includes("discharging")) state = "discharging";
  else if (rest.includes("charged")) state = "charged";
  else if (rest.includes("charging") || rest.includes("finishing charge")) state = "charging";
  else state = "ac";

  const remaining = /(\d+):(\d{2}) remaining/.exec(rest);
  const minutesRemaining = remaining ? Number(remaining[1]) * 60 + Number(remaining[2]) : null;
  return { percent, state, minutesRemaining };
}

/**
 * Parse `pmset -g` for the active energy mode: `powermode` 0/1/2 on current
 * macOS, `lowpowermode` 0/1 on older releases. Automatic when neither says.
 */
export function parseEnergyMode(stdout: string): EnergyMode {
  const mode = /^\s*powermode\s+(\d)/m.exec(stdout);
  if (mode) return mode[1] === "1" ? "low" : mode[1] === "2" ? "high" : "automatic";
  const legacy = /^\s*lowpowermode\s+(\d)/m.exec(stdout);
  return legacy?.[1] === "1" ? "low" : "automatic";
}

/** The moment between two readings, if any. */
export function detectPowerEvent(prev: PowerReading | null, next: PowerReading): PowerEvent {
  if (!prev) return null;
  const wasOnBattery = prev.state === "discharging";
  const isOnBattery = next.state === "discharging";
  if (wasOnBattery && !isOnBattery) return "plugged";
  if (!wasOnBattery && isOnBattery) return "unplugged";
  return null;
}

/**
 * powerMonitor knows about the charger before pmset does: read right after
 * "on-ac", pmset can still say "discharging". Trust the event for the power
 * source so the next reading doesn't see the same transition and fire it again.
 */
export function reconcile(reading: PowerReading, forced: PowerEvent): PowerReading {
  if (forced === "plugged" && reading.state === "discharging") {
    return { ...reading, state: "charging", minutesRemaining: null };
  }
  if (forced === "unplugged" && reading.state !== "discharging") {
    return { ...reading, state: "discharging", minutesRemaining: null };
  }
  return reading;
}

export type PowerSource = "ac" | "battery";

/** The charger moment, if the power source really changed. The first report only sets the baseline. */
export function sourceEvent(prev: PowerSource | null, next: PowerSource): PowerEvent {
  if (prev === null || prev === next) return null;
  return next === "ac" ? "plugged" : "unplugged";
}

/** The sidecar hears Low Power Mode flip before pmset settles; trust it for that one bit. */
export function resolveEnergyMode(fromPmset: EnergyMode, nativeLowPower: boolean | null): EnergyMode {
  if (nativeLowPower === true) return "low";
  if (nativeLowPower === false && fromPmset === "low") return "automatic";
  return fromPmset;
}

export function isLow(reading: PowerReading): boolean {
  return reading.state === "discharging" && reading.percent <= LOW_BATTERY_PERCENT;
}

type Listener = (payload: PowerPayload | null) => void;
let listeners: Listener[] = [];
let current: PowerReading | null = null;
let lastPayload: PowerPayload | null = null;
let enabled = false;
let timer: ReturnType<typeof setTimeout> | null = null;
let hasBattery = true;
let wired = false;
let source: PowerSource | null = null;
let nativeLowPower: boolean | null = null;

export function onPower(listener: Listener): () => void {
  listeners.push(listener);
  return () => {
    listeners = listeners.filter((l) => l !== listener);
  };
}

export function getPower(): PowerPayload | null {
  return lastPayload ? { ...lastPayload, event: null } : null;
}

function publish(payload: PowerPayload | null): void {
  lastPayload = payload;
  for (const l of listeners) l(payload);
}

function readPmset(...args: string[]): Promise<string> {
  return new Promise((resolve) => {
    execFile("pmset", ["-g", ...args], { timeout: 3000 }, (err, stdout) =>
      resolve(err ? "" : stdout),
    );
  });
}

async function refresh(forcedEvent: PowerEvent = null): Promise<void> {
  if (!enabled || !hasBattery) return;
  const [batt, settings] = await Promise.all([readPmset("batt"), readPmset()]);
  const raw = parsePmset(batt);
  if (!raw) {
    // Desktop Mac (or pmset failed the same way twice): nothing to show, ever.
    hasBattery = false;
    publish(null);
    return;
  }
  const reading = reconcile(raw, forcedEvent);
  const event = forcedEvent ?? detectPowerEvent(current, reading);
  current = reading;
  // Only a moment moves the baseline: a plain poll must not overwrite what the
  // sidecar just said with a pmset reading that hasn't caught up yet.
  if (event) source = event === "plugged" ? "ac" : "battery";
  else if (source === null) source = reading.state === "discharging" ? "battery" : "ac";
  const energyMode = resolveEnergyMode(parseEnergyMode(settings), nativeLowPower);
  publish({ ...reading, event, low: isLow(reading), energyMode });
  // pmset was behind: look again shortly for the real state and estimate.
  schedule(reading === raw ? 60_000 : 5_000);
}

function schedule(delay = 60_000): void {
  if (timer) clearTimeout(timer);
  timer = null;
  if (!enabled || !hasBattery) return;
  timer = setTimeout(() => {
    // Re-arms the sidecar's watch if it was respawned since; a no-op otherwise.
    send("power");
    void refresh();
  }, delay);
}

/** The charger went in or out, from whichever watcher noticed first. */
function sourceChanged(next: PowerSource): void {
  const event = sourceEvent(source, next);
  source = next;
  if (event && enabled) void refresh(event);
}

/** `power source ac|battery` / `power lowpower 0|1` from the Swift sidecar. */
function onNativeLine(line: string): void {
  const m = /^power (source|lowpower) (\w+)$/.exec(line);
  if (!m) return;
  if (m[1] === "source") {
    if (m[2] === "ac" || m[2] === "battery") sourceChanged(m[2]);
    return;
  }
  const low = m[2] === "1";
  if (low === nativeLowPower) return;
  const first = nativeLowPower === null;
  nativeLowPower = low;
  if (!first) void refresh();
}

export function startPower(on: boolean): void {
  enabled = on;
  if (!wired) {
    wired = true;
    onLine(onNativeLine);
    powerMonitor.on("on-ac", () => sourceChanged("ac"));
    powerMonitor.on("on-battery", () => sourceChanged("battery"));
    powerMonitor.on("resume", () => void refresh());
  }
  if (!enabled) {
    stopPower();
    return;
  }
  send("power");
  void refresh();
}

/** Dev builds only: replay the last reading as the charger going in, then out, alternately. */
let simulated: PowerEvent = "unplugged";
export function simulatePowerEvent(): void {
  if (!lastPayload) return;
  simulated = simulated === "plugged" ? "unplugged" : "plugged";
  publish({ ...lastPayload, event: simulated });
}

export function stopPower(): void {
  enabled = false;
  if (timer) clearTimeout(timer);
  timer = null;
  current = null;
  source = null;
  publish(null);
}

export function setPowerEnabled(on: boolean): void {
  if (on === enabled) return;
  startPower(on);
}

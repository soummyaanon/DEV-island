import { powerMonitor } from "electron";
import { execFile } from "node:child_process";

/**
 * Battery as a live activity.
 *
 * Electron's powerMonitor says the instant the charger comes or goes;
 * `pmset -g batt` says how full the battery is. No sidecar involvement — this
 * is one small spawn per minute on laptops and nothing at all on desktops
 * (no InternalBattery line → we publish null once and stop).
 */

export type PowerState = "charging" | "discharging" | "charged" | "ac";

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

/** The moment between two readings, if any. */
export function detectPowerEvent(prev: PowerReading | null, next: PowerReading): PowerEvent {
  if (!prev) return null;
  const wasOnBattery = prev.state === "discharging";
  const isOnBattery = next.state === "discharging";
  if (wasOnBattery && !isOnBattery) return "plugged";
  if (!wasOnBattery && isOnBattery) return "unplugged";
  return null;
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

function readPmset(): Promise<string> {
  return new Promise((resolve) => {
    execFile("pmset", ["-g", "batt"], { timeout: 3000 }, (err, stdout) =>
      resolve(err ? "" : stdout),
    );
  });
}

async function refresh(forcedEvent: PowerEvent = null): Promise<void> {
  if (!enabled || !hasBattery) return;
  const reading = parsePmset(await readPmset());
  if (!reading) {
    // Desktop Mac (or pmset failed the same way twice): nothing to show, ever.
    hasBattery = false;
    publish(null);
    return;
  }
  const event = forcedEvent ?? detectPowerEvent(current, reading);
  current = reading;
  publish({ ...reading, event, low: isLow(reading) });
  schedule();
}

function schedule(): void {
  if (timer) clearTimeout(timer);
  timer = null;
  if (!enabled || !hasBattery) return;
  timer = setTimeout(() => void refresh(), 60_000);
}

export function startPower(on: boolean): void {
  enabled = on;
  if (!wired) {
    wired = true;
    powerMonitor.on("on-ac", () => void refresh("plugged"));
    powerMonitor.on("on-battery", () => void refresh("unplugged"));
    powerMonitor.on("resume", () => void refresh());
  }
  if (!enabled) {
    stopPower();
    return;
  }
  void refresh();
}

export function stopPower(): void {
  enabled = false;
  if (timer) clearTimeout(timer);
  timer = null;
  current = null;
  publish(null);
}

export function setPowerEnabled(on: boolean): void {
  if (on === enabled) return;
  startPower(on);
}

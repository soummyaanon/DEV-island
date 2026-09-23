import { execFile } from "node:child_process";
import { Notification } from "electron";
import { onLine, send } from "./native-helper";

/**
 * The island's "Ask" bar: Apple's on-device model (Foundation Models, macOS
 * 26) driven through the native sidecar. Nothing leaves the Mac.
 *
 * Main only relays. The renderer sends a question plus a plain-text snapshot of
 * the sessions; the sidecar streams the reply back as cumulative base64 text
 * (spaces and newlines would break its line protocol), reports each tool step
 * as it starts, and reports tool results that need the app as actions.
 *
 * Harmless actions happen straight away — `open` jumps to a session, `timer`
 * starts a countdown here. Actions that do real work on the user's behalf —
 * `draft` (type into an agent) and `shortcut` (run one of their Shortcuts) —
 * go to the renderer, which shows them and waits for the user's click.
 */

/**
 * `available`: the on-device model answers. `basic`: the sidecar's command
 * reader does (opens, searches, timers, volume, Shortcuts) because the model
 * can't — see `assistantReason()` for why. `no-helper`: nothing can.
 */
export type AssistantSupport = "available" | "basic" | "no-helper";

export type AssistantAction =
  | { kind: "open"; project: string }
  | { kind: "draft"; project: string; message: string }
  | { kind: "timer"; minutes: number; label: string }
  | { kind: "shortcut"; name: string };

export type AssistantEvent =
  | { id: string; type: "delta"; text: string }
  | { id: string; type: "done" }
  | { id: string; type: "error"; reason: string }
  | { id: string; type: "tool"; name: string; step: string }
  | { id: string; type: "action"; action: AssistantAction };

const decode = (b64: string): string => Buffer.from(b64, "base64").toString("utf8");
const encode = (text: string): string => Buffer.from(text, "utf8").toString("base64");

/** `ai available` | `ai basic <reason>` → support + reason; anything else null. */
export function parseAssistantCaps(line: string): { support: AssistantSupport; reason: string } | null {
  const m = /^ai (available|basic ([\w-]+))$/.exec(line.trim());
  if (!m) return null;
  return m[2] ? { support: "basic", reason: m[2] } : { support: "available", reason: "" };
}

/** One streamed reply line → event; null for anything that isn't one. */
export function parseAssistantLine(line: string): AssistantEvent | null {
  const tool = /^ai tool (\S+) (\w+) (\S+)$/.exec(line.trim());
  if (tool) return { id: tool[1], type: "tool", name: tool[2], step: decode(tool[3]) };
  const m = /^ai (delta|done|error|action) (\S+)(?: (\S+))?$/.exec(line.trim());
  if (!m) return null;
  const [, type, id, arg = ""] = m;
  switch (type) {
    case "delta":
      return { id, type: "delta", text: decode(arg) };
    case "done":
      return { id, type: "done" };
    case "error":
      return { id, type: "error", reason: arg || "unknown" };
    default: {
      try {
        const raw = JSON.parse(decode(arg)) as Record<string, unknown>;
        const project = typeof raw.project === "string" ? raw.project : "";
        if (raw.kind === "open") return { id, type: "action", action: { kind: "open", project } };
        if (raw.kind === "timer") {
          const minutes = Number(raw.minutes);
          if (!Number.isFinite(minutes) || minutes < 1 || minutes > 720) return null;
          const label = typeof raw.label === "string" ? raw.label : "";
          return { id, type: "action", action: { kind: "timer", minutes: Math.round(minutes), label } };
        }
        if (raw.kind === "shortcut") {
          const name = typeof raw.name === "string" ? raw.name.trim() : "";
          return name ? { id, type: "action", action: { kind: "shortcut", name } } : null;
        }
        if (raw.kind === "draft") {
          const message = typeof raw.message === "string" ? raw.message : "";
          return { id, type: "action", action: { kind: "draft", project, message } };
        }
      } catch {
        /* a malformed action is dropped, not fatal */
      }
      return null;
    }
  }
}

/** The `ai ask` command line. Ids are restricted so they can't break the protocol. */
export function askCommand(id: string, prompt: string, context: string): string {
  const safeId = id.replace(/[^\w-]/g, "").slice(0, 32) || "q";
  return `ai ask ${safeId} ${encode(JSON.stringify({ prompt, context }))}`;
}

let support: AssistantSupport = "no-helper";
/** Why the model can't answer in basic mode: not-enabled, os, device-not-eligible, off, … */
let reason = "";
let started = false;
const supportListeners = new Set<(s: AssistantSupport) => void>();
const eventListeners = new Set<(e: AssistantEvent) => void>();

export function assistantSupport(): AssistantSupport {
  return support;
}

export function assistantReason(): string {
  return reason;
}

/** Settings: Apple Intelligence off keeps the command reader, drops the model. */
export function setAssistantModel(on: boolean): void {
  send(`ai mode ${on ? "auto" : "basic"}`);
}

/** Probe the sidecar once and start relaying its replies. */
export function initAssistant(): void {
  if (started) return;
  started = true;
  onLine((line) => {
    const caps = parseAssistantCaps(line);
    if (caps) {
      support = caps.support;
      reason = caps.reason;
      console.log(`[assistant] support=${support}${reason ? ` (${reason})` : ""}`);
      for (const l of supportListeners) l(support);
      return;
    }
    const event = parseAssistantLine(line);
    if (event) for (const l of eventListeners) l(event);
  });
  if (!send("ai caps")) console.log("[assistant] native helper unavailable");
}

export function onAssistantSupport(listener: (s: AssistantSupport) => void): () => void {
  supportListeners.add(listener);
  return () => supportListeners.delete(listener);
}

export function onAssistantEvent(listener: (e: AssistantEvent) => void): () => void {
  eventListeners.add(listener);
  return () => eventListeners.delete(listener);
}

/** Ask a question. False = the helper is unavailable; the caller shows why. */
export function askAssistant(id: string, prompt: string, context: string): boolean {
  if (support === "no-helper") return false;
  return send(askCommand(id, prompt, context));
}

export function cancelAssistant(id: string): void {
  send(`ai cancel ${id.replace(/[^\w-]/g, "")}`);
}

/** Forget the conversation (the on-device context window is small). */
export function resetAssistant(): void {
  send("ai reset");
}

/* ---- Timers ("remind me in 10 minutes") ---- */

const timers = new Set<ReturnType<typeof setTimeout>>();

/** Start a countdown; `onDone` runs with the label when it ends. */
export function startAssistantTimer(minutes: number, label: string, onDone: (label: string) => void): void {
  const handle = setTimeout(() => {
    timers.delete(handle);
    new Notification({
      title: label ? `Timer: ${label}` : "Timer done",
      body: `${minutes} minute${minutes === 1 ? "" : "s"} are up.`,
    }).show();
    onDone(label);
  }, minutes * 60_000);
  timers.add(handle);
}

export function clearAssistantTimers(): void {
  for (const t of timers) clearTimeout(t);
  timers.clear();
}

/* ---- Shortcuts, only after the user confirmed in the island ---- */

/** Run one of the user's Shortcuts by exact name. Resolves true on success. */
export function runShortcut(name: string): Promise<boolean> {
  return new Promise((resolve) => {
    // execFile, not a shell: the name is an argument, never interpreted.
    execFile("/usr/bin/shortcuts", ["run", name], { timeout: 120_000 }, (err) => {
      if (err) console.warn(`[assistant] shortcut "${name}" failed: ${err.message}`);
      resolve(!err);
    });
  });
}

import { isAvailable, send } from "./native-helper";

/**
 * Trackpad haptics, one pattern per event class.
 *
 * macOS exposes exactly three feedback primitives through
 * NSHapticFeedbackManager and no waveform or intensity control, so a
 * recognisable "feel" can only come from COUNT and SPACING. Every pattern
 * below is a rhythm built from those three taps — nothing here can make the
 * trackpad feel like rain, and pretending otherwise would just produce eight
 * indistinguishable buzzes.
 *
 * Hardware reality: Force Touch trackpads only, and macOS honours the user's
 * "Force Click and haptic feedback" setting. Desktop Macs feel nothing, which
 * is why the visual (edge-spark) and audio layers remain the primary feedback
 * and this is strictly additive.
 */

export type HapticPattern =
  | "success" // a session finished
  | "attention" // something needs you
  | "inquiry" // an agent asked a question
  | "failure" // a session failed
  | "commit" // you approved/denied — a decision landed
  | "tick" // lightest possible: row click, control press
  | "whisper" // ambient, non-alerting (weather refresh)
  | "rumble"; // ambient but heavy (thunder onset)

/**
 * Wire rhythms: alternating pattern name and gap in ms. `failure`'s tight 40ms
 * double reads as "wrong"; `rumble`'s slow 140ms spacing is the only thing
 * separating it from `attention`, so don't narrow it.
 */
export const RHYTHMS: Record<HapticPattern, string> = {
  success: "levelChange,55,levelChange",
  attention: "generic,90,generic,90,generic",
  inquiry: "alignment,70,levelChange",
  failure: "generic,40,generic",
  commit: "levelChange",
  tick: "alignment",
  whisper: "alignment",
  rumble: "generic,140,generic,140,generic",
};

/** Higher wins when several land in the same batch. */
export const PRIORITY: Record<HapticPattern, number> = {
  failure: 70,
  attention: 60,
  inquiry: 50,
  rumble: 45,
  success: 40,
  commit: 30,
  tick: 20,
  whisper: 10,
};

/**
 * Minimum gap between two rhythms. Ten sessions finishing in one snapshot must
 * land as ONE pulse — a machine-gunned trackpad is worse than silence.
 */
export const MIN_GAP_MS = 250;

/** Guard for values crossing IPC from the renderer. */
export function isHapticPattern(value: unknown): value is HapticPattern {
  return typeof value === "string" && value in RHYTHMS;
}

/** The winner of a batch: highest priority, or null for an empty batch. Pure. */
export function pickWinner(patterns: readonly HapticPattern[]): HapticPattern | null {
  let winner: HapticPattern | null = null;
  for (const pattern of patterns) {
    if (winner === null || PRIORITY[pattern] > PRIORITY[winner]) winner = pattern;
  }
  return winner;
}

/** Whether enough time has passed since the last rhythm. Pure. */
export function canFire(now: number, lastFiredAt: number): boolean {
  return now - lastFiredAt >= MIN_GAP_MS;
}

let enabled = true;
/** Focus is on: only interaction taps (tick, commit) get through. */
let quiet = false;
let lastFiredAt = Number.NEGATIVE_INFINITY;
let batch: HapticPattern[] = [];
let flushTimer: ReturnType<typeof setTimeout> | null = null;

export function setHapticsEnabled(on: boolean): void {
  enabled = on;
}

/** While a Focus is on, notification rhythms are dropped; taps you caused stay. */
export function setHapticsQuiet(on: boolean): void {
  quiet = on;
}

/** True when haptics could actually be felt — for Settings to explain itself. */
export function hapticsSupported(): boolean {
  return isAvailable();
}

function flush(): void {
  flushTimer = null;
  const winner = pickWinner(batch);
  batch = [];
  if (winner === null) return;

  const now = Date.now();
  // Dropped rather than deferred: a late tap is worse than none, and the
  // visual/audio layers already carried this event.
  if (!canFire(now, lastFiredAt)) return;
  if (send(`haptic ${RHYTHMS[winner]}`)) lastFiredAt = now;
}

/**
 * Request a pulse. Batched to the next tick so a whole snapshot's worth of
 * transitions collapses into one rhythm; the delay is sub-millisecond, so
 * press feedback still feels immediate.
 */
export function haptic(pattern: HapticPattern): void {
  if (!enabled) return;
  if (quiet && pattern !== "tick" && pattern !== "commit") return;
  batch.push(pattern);
  if (flushTimer === null) flushTimer = setTimeout(flush, 0);
}

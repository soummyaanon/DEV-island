/**
 * Two-finger swipe detection from wheel events.
 *
 * Wheel events are the only trackpad signal a web view gets, and they arrive
 * as a stream of small deltas. This accumulates them over a short sliding
 * window, fires once the sum crosses a threshold, then locks briefly so the
 * tail of the same swipe can't fire twice. Pure — no DOM, no timers — so the
 * thresholds are unit-tested and App.tsx stays plumbing.
 *
 * Direction is expressed as FINGER motion (down = fingers moved down), never
 * raw wheel sign: with macOS "natural scrolling" the two are inverted, and the
 * island's gestures must mean the same thing on every Mac.
 */

export type SwipeDirection = "down" | "up";

export interface WheelGestureOptions {
  /** Deltas older than this no longer count. */
  windowMs?: number;
  /** Summed finger travel (px) that counts as a swipe. */
  thresholdPx?: number;
  /** Quiet period after firing during which nothing else fires. */
  lockMs?: number;
}

interface Sample {
  t: number;
  dy: number;
}

export class WheelGesture {
  private readonly windowMs: number;
  private readonly thresholdPx: number;
  private readonly lockMs: number;
  private samples: Sample[] = [];
  private lockedUntil = Number.NEGATIVE_INFINITY;

  constructor(opts: WheelGestureOptions = {}) {
    this.windowMs = opts.windowMs ?? 160;
    this.thresholdPx = opts.thresholdPx ?? 28;
    this.lockMs = opts.lockMs ?? 250;
  }

  /** Feed one wheel event's finger delta. Returns a decision at most once per swipe. */
  feed(fingerDy: number, now: number): SwipeDirection | null {
    if (now < this.lockedUntil) return null;
    this.prune(now);
    this.samples.push({ t: now, dy: fingerDy });
    const sum = this.sum();
    if (Math.abs(sum) < this.thresholdPx) return null;
    this.samples = [];
    this.lockedUntil = now + this.lockMs;
    return sum > 0 ? "down" : "up";
  }

  /** How far toward a decision the current swipe is, −1..1. Positive = down. */
  progress(now: number): number {
    if (now < this.lockedUntil) return 0;
    this.prune(now);
    const fraction = this.sum() / this.thresholdPx;
    return Math.max(-1, Math.min(1, fraction));
  }

  reset(): void {
    this.samples = [];
    this.lockedUntil = Number.NEGATIVE_INFINITY;
  }

  private prune(now: number): void {
    const cutoff = now - this.windowMs;
    this.samples = this.samples.filter((s) => s.t >= cutoff);
  }

  private sum(): number {
    let total = 0;
    for (const s of this.samples) total += s.dy;
    return total;
  }
}

/**
 * Convert a wheel deltaY into finger travel. Natural scrolling (the macOS
 * default) moves content WITH the fingers, so fingers moving down produce a
 * negative wheel delta; the classic setting is the reverse.
 */
export function fingerDelta(wheelDeltaY: number, naturalScroll: boolean): number {
  return naturalScroll ? -wheelDeltaY : wheelDeltaY;
}

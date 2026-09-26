/**
 * Spring motion for the island, precomputed into CSS `linear()` easings.
 *
 * The overlay composites over the menu bar all day with hardware acceleration
 * off, so motion must stay declarative: no JS frame loop. A damped spring is
 * integrated ONCE here, sampled, and published as a `linear()` timing function
 * plus its settle time; CSS transitions and keyframes then read the variables.
 *
 * Pure on purpose — vitest covers the physics without a DOM.
 */

export interface SpringConfig {
  /** N/m — higher is snappier. */
  stiffness: number;
  /** N·s/m — higher settles sooner; below critical (2·√(k·m)) it overshoots. */
  damping: number;
  mass: number;
}

export interface SpringEasing {
  /** A CSS `linear(...)` timing function with evenly spaced stops. */
  easing: string;
  /** How long the spring takes to settle, in ms. Use as the duration. */
  ms: number;
}

/** Opening: quick and steady — lands with under 1% overshoot (a hint of life, no wobble). */
export const OPEN_SPRING: SpringConfig = { stiffness: 420, damping: 34, mass: 1 };
/** Adjusting while already open, and the count roll: firm, no visible overshoot, ~300ms. */
export const SETTLE_SPRING: SpringConfig = { stiffness: 380, damping: 36, mass: 1 };
/** Reduced motion: a step. 1ms rather than 0 so `transitionend` still fires. */
export const STEP_EASING: SpringEasing = { easing: "linear(0, 1)", ms: 1 };

/** Integration step (s) and ceiling (ms) for a spring that never settles. */
const DT = 0.001;
const MAX_MS = 1500;
/** Settled when within 0.5% of the target and nearly still — visually at rest. */
const SETTLE_DISTANCE = 0.005;
const SETTLE_VELOCITY = 0.1;

/**
 * Integrate a unit spring (0 → 1) with semi-implicit Euler at 1ms steps, then
 * sample the trajectory evenly over its settle time. The last sample is pinned
 * to exactly 1 so the easing always lands on the final value.
 */
export function sampleSpring(cfg: SpringConfig, samples = 48): { values: number[]; ms: number } {
  const trajectory: number[] = [0];
  let x = 0;
  let v = 0;
  let settledAt = MAX_MS;
  for (let step = 1; step <= MAX_MS; step++) {
    const acceleration = (cfg.stiffness * (1 - x) - cfg.damping * v) / cfg.mass;
    v += acceleration * DT;
    x += v * DT;
    trajectory.push(x);
    if (Math.abs(1 - x) < SETTLE_DISTANCE && Math.abs(v) < SETTLE_VELOCITY) {
      settledAt = step;
      break;
    }
  }

  const count = Math.max(2, Math.floor(samples));
  const values: number[] = [];
  for (let i = 0; i < count; i++) {
    const t = Math.round((i / (count - 1)) * settledAt);
    values.push(trajectory[Math.min(t, trajectory.length - 1)]);
  }
  values[0] = 0;
  values[count - 1] = 1;
  return { values, ms: settledAt };
}

/** The same trajectory as a CSS timing function string. */
export function springEasing(cfg: SpringConfig, samples = 48): SpringEasing {
  const { values, ms } = sampleSpring(cfg, samples);
  const stops = values.map((value) => String(Math.round(value * 1000) / 1000));
  return { easing: `linear(${stops.join(", ")})`, ms };
}

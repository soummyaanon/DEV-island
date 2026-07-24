/**
 * How wide the expanded island should be.
 *
 * The panel used to be pinned at `max(360px, notchWidth + 110px)` regardless of
 * what it contained, so a one-line session list and a 40-line diff got the same
 * box. Now the content reports its natural width and we clamp it — the floor is
 * the old fixed width (so nothing ever got narrower than before) and the
 * ceiling comes from the display.
 *
 * Pure on purpose: this is the part worth testing, and it keeps the React hook
 * down to plumbing.
 */

/** Narrowest the expanded island may be — the previous fixed width. */
export function minIslandWidth(notchWidth: number): number {
  return Math.max(360, notchWidth + 110);
}

/**
 * Clamp a measured content width into the allowed band. `maxWidth` is treated
 * as advisory when it would fall below the floor (a very small display), since
 * a panel narrower than its minimum is unusable either way.
 */
export function clampIslandWidth(contentWidth: number, minWidth: number, maxWidth: number): number {
  const ceiling = Math.max(minWidth, maxWidth);
  const wanted = Number.isFinite(contentWidth) ? contentWidth : minWidth;
  // Whole pixels: a fractional target makes the ResizeObserver re-fire forever.
  return Math.round(Math.min(Math.max(wanted, minWidth), ceiling));
}

/**
 * Whether a new width is worth applying. Sub-pixel churn from font rendering
 * would otherwise feed the observer its own output and thrash the transition.
 */
export function isSignificantChange(current: number, next: number): boolean {
  return Math.abs(current - next) > 2;
}

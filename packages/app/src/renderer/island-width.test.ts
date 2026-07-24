import { describe, expect, it } from "vitest";
import { clampIslandWidth, isSignificantChange, minIslandWidth } from "./island-width";

describe("minIslandWidth", () => {
  it("keeps the old fixed width as the floor on a typical notch", () => {
    // 196 + 110 = 306, so the 360 floor wins — exactly the previous behavior.
    expect(minIslandWidth(196)).toBe(360);
  });

  it("grows with the notch once the notch is the binding constraint", () => {
    expect(minIslandWidth(280)).toBe(390);
  });

  it("survives a notchless display reporting 0", () => {
    expect(minIslandWidth(0)).toBe(360);
  });
});

describe("clampIslandWidth", () => {
  it("uses the content width when it sits inside the band", () => {
    expect(clampIslandWidth(512, 360, 720)).toBe(512);
  });

  it("never goes below the floor — a short session list stays readable", () => {
    expect(clampIslandWidth(120, 360, 720)).toBe(360);
  });

  it("caps a wide diff at the ceiling instead of overflowing the display", () => {
    expect(clampIslandWidth(1400, 360, 720)).toBe(720);
  });

  it("rounds to whole pixels so the observer can't re-fire on itself", () => {
    expect(clampIslandWidth(512.4, 360, 720)).toBe(512);
    expect(clampIslandWidth(512.6, 360, 720)).toBe(513);
  });

  it("prefers the floor when a small display puts the ceiling below it", () => {
    // 1024-wide screen => max 944... but a contrived narrow case must not
    // produce a panel narrower than its own minimum.
    expect(clampIslandWidth(600, 360, 300)).toBe(360);
  });

  it("falls back to the floor for any non-finite measurement", () => {
    // Deliberately the floor rather than the ceiling: a measurement this broken
    // means something is wrong, and the safe failure is the narrow panel we
    // always used to draw — not a 720px one covering the menu bar.
    expect(clampIslandWidth(Number.NaN, 360, 720)).toBe(360);
    expect(clampIslandWidth(Number.POSITIVE_INFINITY, 360, 720)).toBe(360);
  });
});

describe("isSignificantChange", () => {
  it("ignores sub-pixel churn from font rendering", () => {
    expect(isSignificantChange(400, 401)).toBe(false);
    expect(isSignificantChange(400, 402)).toBe(false);
  });

  it("accepts a real resize", () => {
    expect(isSignificantChange(400, 403)).toBe(true);
    expect(isSignificantChange(400, 397)).toBe(true);
  });

  it("treats the very first measurement as significant", () => {
    expect(isSignificantChange(0, 360)).toBe(true);
  });
});

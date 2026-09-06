import { describe, expect, it } from "vitest";
import { WheelGesture, fingerDelta } from "./gesture";

describe("WheelGesture", () => {
  it("fires 'down' once the window's sum crosses the threshold", () => {
    const g = new WheelGesture({ thresholdPx: 28 });
    expect(g.feed(10, 0)).toBeNull();
    expect(g.feed(10, 20)).toBeNull();
    expect(g.feed(10, 40)).toBe("down");
  });

  it("fires 'up' for negative deltas", () => {
    const g = new WheelGesture({ thresholdPx: 28 });
    g.feed(-15, 0);
    expect(g.feed(-15, 10)).toBe("up");
  });

  it("forgets deltas older than the window", () => {
    const g = new WheelGesture({ windowMs: 160, thresholdPx: 28 });
    g.feed(20, 0);
    expect(g.feed(10, 500)).toBeNull();
  });

  it("locks out further decisions after firing", () => {
    const g = new WheelGesture({ thresholdPx: 28, lockMs: 250 });
    expect(g.feed(30, 0)).toBe("down");
    expect(g.feed(30, 100)).toBeNull();
    expect(g.feed(30, 249)).toBeNull();
    expect(g.feed(30, 251)).toBe("down");
  });

  it("reports progress toward the threshold, clamped", () => {
    const g = new WheelGesture({ thresholdPx: 40 });
    g.feed(10, 0);
    expect(g.progress(0)).toBeCloseTo(0.25);
    g.feed(-30, 5);
    expect(g.progress(5)).toBeCloseTo(-0.5);
    g.feed(-100, 6);
    expect(g.progress(6)).toBe(0);
  });

  it("progress decays to 0 once the window expires", () => {
    const g = new WheelGesture({ windowMs: 160, thresholdPx: 40 });
    g.feed(20, 0);
    expect(g.progress(1000)).toBe(0);
  });

  it("reset clears everything including the lock", () => {
    const g = new WheelGesture({ thresholdPx: 28, lockMs: 250 });
    g.feed(30, 0);
    g.reset();
    expect(g.feed(30, 1)).toBe("down");
  });
});

describe("fingerDelta", () => {
  it("with natural scrolling, a positive wheel delta means the fingers moved up", () => {
    expect(fingerDelta(12, true)).toBe(-12);
  });
  it("without natural scrolling, wheel and finger directions agree", () => {
    expect(fingerDelta(12, false)).toBe(12);
  });
});

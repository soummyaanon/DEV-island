import { describe, expect, it } from "vitest";
import { OPEN_SPRING, SETTLE_SPRING, STEP_EASING, sampleSpring, springEasing } from "./motion";

describe("sampleSpring", () => {
  it("starts at 0 and ends exactly at 1", () => {
    const { values } = sampleSpring(OPEN_SPRING);
    expect(values[0]).toBe(0);
    expect(values[values.length - 1]).toBe(1);
  });

  it("the open spring overshoots only a hint (steady, no wobble), then settles in under 600ms", () => {
    const { values, ms } = sampleSpring(OPEN_SPRING);
    const peak = Math.max(...values);
    expect(peak).toBeGreaterThan(1.004);
    expect(peak).toBeLessThan(1.02);
    expect(ms).toBeGreaterThanOrEqual(300);
    expect(ms).toBeLessThanOrEqual(600);
  });

  it("the settle spring never visibly overshoots and is quicker", () => {
    const { values, ms } = sampleSpring(SETTLE_SPRING);
    expect(Math.max(...values)).toBeLessThanOrEqual(1.005);
    expect(ms).toBeGreaterThanOrEqual(200);
    expect(ms).toBeLessThanOrEqual(450);
  });

  it("returns the requested number of samples", () => {
    expect(sampleSpring(OPEN_SPRING, 12).values).toHaveLength(12);
  });

  it("caps runaway springs at the integration ceiling instead of looping forever", () => {
    const { ms } = sampleSpring({ stiffness: 400, damping: 0.1, mass: 1 });
    expect(ms).toBe(1500);
  });
});

describe("springEasing", () => {
  it("emits a CSS linear() with evenly spaced stops", () => {
    const { easing, ms } = springEasing(OPEN_SPRING, 5);
    expect(easing.startsWith("linear(0, ")).toBe(true);
    expect(easing.endsWith(", 1)")).toBe(true);
    expect(easing.split(",").length).toBe(5);
    expect(ms).toBeGreaterThan(0);
  });

  it("rounds stops to three decimals so the string stays short", () => {
    const { easing } = springEasing(OPEN_SPRING, 40);
    for (const stop of easing.slice("linear(".length, -1).split(", ")) {
      expect(stop).toMatch(/^-?\d+(\.\d{1,3})?$/);
    }
  });
});

describe("STEP_EASING", () => {
  it("is an instant step for reduced motion", () => {
    expect(STEP_EASING).toEqual({ easing: "linear(0, 1)", ms: 1 });
  });
});

import { describe, expect, it } from "vitest";
import { wingContent } from "./wing-priority";

const base = { needsYou: 0, active: 0, activity: false, lowBattery: false, weather: false };

describe("wingContent", () => {
  it("attention beats everything", () => {
    expect(wingContent({ ...base, needsYou: 1, active: 2, activity: true, lowBattery: true, weather: true })).toBe(
      "attention",
    );
  });
  it("an agent's done/failed moment beats other agents working, but not attention", () => {
    expect(wingContent({ ...base, moment: true, active: 2, activity: true })).toBe("moment");
    expect(wingContent({ ...base, moment: true, needsYou: 1 })).toBe("attention");
  });
  it("working agents beat ambience and live activities", () => {
    expect(wingContent({ ...base, active: 1, activity: true, lowBattery: true, weather: true })).toBe("working");
  });
  it("the charger going in or out beats working agents, but not attention or a moment", () => {
    expect(wingContent({ ...base, active: 2, activity: true, powerMoment: true })).toBe("activity");
    expect(wingContent({ ...base, needsYou: 1, activity: true, powerMoment: true })).toBe("attention");
    expect(wingContent({ ...base, moment: true, activity: true, powerMoment: true })).toBe("moment");
  });
  it("a live activity beats low battery and weather", () => {
    expect(wingContent({ ...base, activity: true, lowBattery: true, weather: true })).toBe("activity");
  });
  it("low battery beats weather", () => {
    expect(wingContent({ ...base, lowBattery: true, weather: true })).toBe("low-battery");
  });
  it("weather when nothing else", () => {
    expect(wingContent({ ...base, weather: true })).toBe("weather");
  });
  it("empty otherwise", () => {
    expect(wingContent(base)).toBe("empty");
  });
});

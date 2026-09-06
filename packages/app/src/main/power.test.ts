import { describe, expect, it } from "vitest";
import { detectPowerEvent, isLow, parsePmset } from "./power";

const line = (tail: string) =>
  `Now drawing from 'Battery Power'\n -InternalBattery-0 (id=34668643)\t${tail} present: true\n`;

describe("parsePmset", () => {
  it("reads a discharging battery with an estimate", () => {
    expect(parsePmset(line("80%; discharging; 11:02 remaining"))).toEqual({
      percent: 80,
      state: "discharging",
      minutesRemaining: 662,
    });
  });
  it("reads charging with time to full", () => {
    expect(parsePmset(line("43%; charging; 1:20 remaining"))).toEqual({
      percent: 43,
      state: "charging",
      minutesRemaining: 80,
    });
  });
  it("reads a full battery", () => {
    expect(parsePmset(line("100%; charged; 0:00 remaining"))?.state).toBe("charged");
  });
  it("reads AC attached but not charging", () => {
    expect(parsePmset(line("85%; AC attached; not charging"))?.state).toBe("ac");
  });
  it("reads 'finishing charge' as charging", () => {
    expect(parsePmset(line("97%; finishing charge; 0:12 remaining"))?.state).toBe("charging");
  });
  it("copes with no estimate", () => {
    expect(parsePmset(line("80%; discharging; (no estimate)"))).toEqual({
      percent: 80,
      state: "discharging",
      minutesRemaining: null,
    });
  });
  it("is null on a desktop Mac", () => {
    expect(parsePmset("Now drawing from 'AC Power'\n")).toBeNull();
    expect(parsePmset("")).toBeNull();
  });
});

describe("detectPowerEvent", () => {
  const bat = { percent: 50, state: "discharging" as const, minutesRemaining: null };
  const ac = { percent: 50, state: "charging" as const, minutesRemaining: null };
  it("battery → charger is 'plugged'", () => expect(detectPowerEvent(bat, ac)).toBe("plugged"));
  it("charger → battery is 'unplugged'", () => expect(detectPowerEvent(ac, bat)).toBe("unplugged"));
  it("no change, or the first reading, is nothing", () => {
    expect(detectPowerEvent(bat, bat)).toBeNull();
    expect(detectPowerEvent(null, bat)).toBeNull();
  });
});

describe("isLow", () => {
  it("is low only on battery at or under 20%", () => {
    expect(isLow({ percent: 20, state: "discharging", minutesRemaining: null })).toBe(true);
    expect(isLow({ percent: 21, state: "discharging", minutesRemaining: null })).toBe(false);
    expect(isLow({ percent: 5, state: "charging", minutesRemaining: null })).toBe(false);
  });
});

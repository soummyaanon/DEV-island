import { describe, expect, it } from "vitest";
import { detectPowerEvent, isLow, parseEnergyMode, parsePmset, reconcile, resolveEnergyMode, sourceEvent } from "./power";

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

describe("parseEnergyMode", () => {
  const pmset = (tail: string) => `System-wide power settings:\nCurrently in use:\n standby              1\n${tail}\n sleep                1\n`;
  it("reads powermode 0 / 1 / 2", () => {
    expect(parseEnergyMode(pmset(" powermode            0"))).toBe("automatic");
    expect(parseEnergyMode(pmset(" powermode            1"))).toBe("low");
    expect(parseEnergyMode(pmset(" powermode            2"))).toBe("high");
  });
  it("reads the older lowpowermode flag", () => {
    expect(parseEnergyMode(pmset(" lowpowermode         1"))).toBe("low");
    expect(parseEnergyMode(pmset(" lowpowermode         0"))).toBe("automatic");
  });
  it("is automatic when pmset says nothing", () => {
    expect(parseEnergyMode("")).toBe("automatic");
  });
});

describe("reconcile", () => {
  const bat = { percent: 50, state: "discharging" as const, minutesRemaining: 300 };
  const ac = { percent: 50, state: "charging" as const, minutesRemaining: 90 };
  it("trusts 'plugged' over a stale discharging reading", () => {
    expect(reconcile(bat, "plugged")).toEqual({ percent: 50, state: "charging", minutesRemaining: null });
  });
  it("trusts 'unplugged' over a stale charging reading", () => {
    expect(reconcile(ac, "unplugged")).toEqual({ percent: 50, state: "discharging", minutesRemaining: null });
  });
  it("leaves readings that already agree, or no event, alone", () => {
    expect(reconcile(ac, "plugged")).toBe(ac);
    expect(reconcile(bat, null)).toBe(bat);
  });
  it("so the next real reading is not a second 'plugged'", () => {
    expect(detectPowerEvent(reconcile(bat, "plugged"), ac)).toBeNull();
  });
});

describe("sourceEvent", () => {
  it("the first report is only a baseline", () => {
    expect(sourceEvent(null, "ac")).toBeNull();
    expect(sourceEvent(null, "battery")).toBeNull();
  });
  it("battery → ac is 'plugged', ac → battery is 'unplugged'", () => {
    expect(sourceEvent("battery", "ac")).toBe("plugged");
    expect(sourceEvent("ac", "battery")).toBe("unplugged");
  });
  it("a second watcher repeating the same source is nothing", () => {
    expect(sourceEvent("ac", "ac")).toBeNull();
  });
});

describe("resolveEnergyMode", () => {
  it("trusts the sidecar's Low Power flag over pmset", () => {
    expect(resolveEnergyMode("automatic", true)).toBe("low");
    expect(resolveEnergyMode("low", false)).toBe("automatic");
  });
  it("keeps pmset's High Power and falls back to it without the sidecar", () => {
    expect(resolveEnergyMode("high", false)).toBe("high");
    expect(resolveEnergyMode("low", null)).toBe("low");
  });
});

describe("isLow", () => {
  it("is low only on battery at or under 20%", () => {
    expect(isLow({ percent: 20, state: "discharging", minutesRemaining: null })).toBe(true);
    expect(isLow({ percent: 21, state: "discharging", minutesRemaining: null })).toBe(false);
    expect(isLow({ percent: 5, state: "charging", minutesRemaining: null })).toBe(false);
  });
});

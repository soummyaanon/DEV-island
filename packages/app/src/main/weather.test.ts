import { describe, expect, it, vi } from "vitest";

vi.mock("electron", () => ({
  app: { getPath: () => "/tmp", getLocale: () => "en-GB" },
  net: { request: () => ({ on: () => {}, end: () => {} }) },
  powerMonitor: { on: () => {} },
}));

import { lastPrecipitationBefore, nearestSolarTime } from "./weather";

/** Epoch SECONDS, the way we ask Open-Meteo to report times. */
const secs = (iso: string) => Date.parse(iso) / 1000;
const NOON = Date.parse("2026-07-25T12:00:00Z");

describe("lastPrecipitationBefore", () => {
  it("finds the most recent wet hour", () => {
    const times = [secs("2026-07-25T09:00Z"), secs("2026-07-25T10:00Z")];
    expect(lastPrecipitationBefore(times, [0.4, 0], NOON)).toBe(Date.parse("2026-07-25T09:00Z"));
  });

  it("prefers the latest of several wet hours", () => {
    const times = [secs("2026-07-25T09:00Z"), secs("2026-07-25T10:00Z"), secs("2026-07-25T11:00Z")];
    expect(lastPrecipitationBefore(times, [0.4, 0.2, 0], NOON)).toBe(
      Date.parse("2026-07-25T10:00Z"),
    );
  });

  it("ignores forecast hours — rain still to come is not a rainbow", () => {
    const times = [secs("2026-07-25T11:00Z"), secs("2026-07-25T13:00Z")];
    expect(lastPrecipitationBefore(times, [0, 5], NOON)).toBeNull();
  });

  it("returns null when nothing fell", () => {
    const times = [secs("2026-07-25T09:00Z"), secs("2026-07-25T10:00Z")];
    expect(lastPrecipitationBefore(times, [0, 0], NOON)).toBeNull();
  });

  it("survives missing or mismatched arrays", () => {
    expect(lastPrecipitationBefore(undefined, undefined, NOON)).toBeNull();
    expect(lastPrecipitationBefore([secs("2026-07-25T09:00Z")], undefined, NOON)).toBeNull();
    // Short amounts array: read only as far as both go.
    expect(
      lastPrecipitationBefore([secs("2026-07-25T09:00Z"), secs("2026-07-25T10:00Z")], [0.5], NOON),
    ).toBe(Date.parse("2026-07-25T09:00Z"));
  });

  it("is immune to the timezone the app happens to run in", () => {
    // The whole reason for unixtime: this assertion holds in any TZ, whereas
    // zone-less ISO strings would shift with the machine's offset.
    const at = secs("2026-07-25T09:00Z");
    expect(lastPrecipitationBefore([at], [1], NOON)).toBe(at * 1000);
  });
});

describe("nearestSolarTime", () => {
  it("picks the closest of several days", () => {
    const values = [
      secs("2026-07-24T05:30Z"),
      secs("2026-07-25T05:30Z"),
      secs("2026-07-26T05:30Z"),
    ];
    expect(nearestSolarTime(values, Date.parse("2026-07-25T06:00Z"))).toBe(
      Date.parse("2026-07-25T05:30Z"),
    );
  });

  it("looks forward once today's has passed", () => {
    const values = [secs("2026-07-25T05:30Z"), secs("2026-07-26T05:30Z")];
    expect(nearestSolarTime(values, Date.parse("2026-07-25T23:00Z"))).toBe(
      Date.parse("2026-07-26T05:30Z"),
    );
  });

  it("returns null for missing or empty data — polar summer is a real case", () => {
    expect(nearestSolarTime(undefined, NOON)).toBeNull();
    expect(nearestSolarTime([], NOON)).toBeNull();
  });
});

import { afterEach, describe, expect, it } from "vitest";
import {
  coarsen,
  findZoneCoordinates,
  locationFromTimezone,
  parseIso6709,
  parseManualLocation,
  resolveZoneCoordinates,
  zoneCandidates,
  zoneFromLocaltimeLink,
} from "./location";

describe("parseIso6709", () => {
  it("reads degrees-minutes, the common zone.tab form", () => {
    // Asia/Kolkata: +2232+08822 -> 22°32'N 88°22'E
    const result = parseIso6709("+2232+08822");
    expect(result?.lat).toBeCloseTo(22.5333, 3);
    expect(result?.lon).toBeCloseTo(88.3667, 3);
  });

  it("reads the degrees-minutes-seconds form", () => {
    // America/New_York: +404251-0740023
    const result = parseIso6709("+404251-0740023");
    expect(result?.lat).toBeCloseTo(40.7142, 3);
    expect(result?.lon).toBeCloseTo(-74.0064, 3);
  });

  it("keeps southern and western hemispheres negative", () => {
    const result = parseIso6709("-3352+01825"); // Africa/Johannesburg
    expect(result?.lat).toBeLessThan(0);
    expect(result?.lon).toBeGreaterThan(0);
  });

  it("rejects malformed input rather than guessing", () => {
    expect(parseIso6709("")).toBeNull();
    expect(parseIso6709("2232+08822")).toBeNull(); // no leading sign
    expect(parseIso6709("+22+088")).toBeNull(); // too short
    expect(parseIso6709("not a coordinate")).toBeNull();
    expect(parseIso6709("+2232+08822extra")).toBeNull();
  });

  it("rejects out-of-range values", () => {
    expect(parseIso6709("+9932+08822")).toBeNull(); // 99 degrees latitude
    expect(parseIso6709("+2232+19922")).toBeNull(); // 199 degrees longitude
  });
});

const TABLE = [
  "# tz database comment",
  "#code\tcoordinates\tTZ\tcomments",
  "IN\t+2232+08822\tAsia/Kolkata",
  "US\t+404251-0740023\tAmerica/New_York\tEastern (most areas)",
  "GB\t+513030-0000731\tEurope/London",
  "BROKEN\tnonsense\tArea/Broken",
].join("\n");

describe("findZoneCoordinates", () => {
  it("finds a zone with no trailing comment", () => {
    const result = findZoneCoordinates(TABLE, "Asia/Kolkata");
    expect(result?.lat).toBeCloseTo(22.5333, 3);
  });

  it("finds a zone that has a trailing comment column", () => {
    expect(findZoneCoordinates(TABLE, "America/New_York")).not.toBeNull();
  });

  it("returns null for an unlisted zone instead of a nearby one", () => {
    expect(findZoneCoordinates(TABLE, "Mars/Olympus_Mons")).toBeNull();
  });

  it("returns null when the matched row has unparseable coordinates", () => {
    expect(findZoneCoordinates(TABLE, "Area/Broken")).toBeNull();
  });

  it("ignores comment lines that would otherwise match", () => {
    expect(findZoneCoordinates("#IN\t+2232+08822\tAsia/Kolkata", "Asia/Kolkata")).toBeNull();
  });

  it("survives an empty table", () => {
    expect(findZoneCoordinates("", "Asia/Kolkata")).toBeNull();
  });
});

describe("coarsen", () => {
  it("rounds to ~1km, which is all weather needs", () => {
    expect(coarsen(22.533333)).toBe(22.53);
    expect(coarsen(-74.006389)).toBe(-74.01);
  });

  it("leaves an already-coarse value alone", () => {
    expect(coarsen(22.53)).toBe(22.53);
  });
});

describe("parseManualLocation", () => {
  it("accepts comma-separated coordinates", () => {
    expect(parseManualLocation("22.57, 88.36")).toEqual({ lat: 22.57, lon: 88.36 });
  });

  it("accepts space-separated and negative values", () => {
    expect(parseManualLocation("-33.87 151.21")).toEqual({ lat: -33.87, lon: 151.21 });
  });

  it("coarsens what the user typed too — no reason to keep their extra digits", () => {
    expect(parseManualLocation("22.5678901, 88.3612345")).toEqual({ lat: 22.57, lon: 88.36 });
  });

  it("rejects prose, partials, and out-of-range values", () => {
    expect(parseManualLocation("Kolkata")).toBeNull();
    expect(parseManualLocation("22.57")).toBeNull();
    expect(parseManualLocation("")).toBeNull();
    expect(parseManualLocation("91, 0")).toBeNull();
    expect(parseManualLocation("0, 181")).toBeNull();
  });
});

describe("zoneFromLocaltimeLink", () => {
  it("extracts the canonical zone from a symlink target", () => {
    expect(zoneFromLocaltimeLink("/var/db/timezone/zoneinfo/Asia/Kolkata")).toBe("Asia/Kolkata");
    expect(zoneFromLocaltimeLink("../usr/share/zoneinfo/America/New_York")).toBe(
      "America/New_York",
    );
  });

  it("handles a three-part zone name", () => {
    expect(zoneFromLocaltimeLink("/usr/share/zoneinfo/America/Argentina/Buenos_Aires")).toBe(
      "America/Argentina/Buenos_Aires",
    );
  });

  it("rejects targets that aren't zones", () => {
    expect(zoneFromLocaltimeLink("/usr/share/zoneinfo/posixrules")).toBeNull();
    expect(zoneFromLocaltimeLink("/etc/some/other/path")).toBeNull();
    expect(zoneFromLocaltimeLink("")).toBeNull();
  });
});

describe("zoneCandidates", () => {
  const originalTz = process.env.TZ;
  afterEach(() => {
    if (originalTz === undefined) delete process.env.TZ;
    else process.env.TZ = originalTz;
  });

  it("puts an explicit TZ first", () => {
    process.env.TZ = "Pacific/Auckland";
    expect(zoneCandidates()[0]).toBe("Pacific/Auckland");
  });

  it("returns candidates without duplicates", () => {
    const candidates = zoneCandidates();
    expect(new Set(candidates).size).toBe(candidates.length);
  });

  it("finds at least one zone on a normally configured machine", () => {
    expect(zoneCandidates().length).toBeGreaterThan(0);
  });
});

describe("resolveZoneCoordinates", () => {
  // The regression this guards: Intl reports the DEPRECATED alias
  // "Asia/Calcutta" while zone.tab lists only the canonical "Asia/Kolkata", so
  // consulting Intl's answer alone silently found nothing. Same story for
  // Europe/Kiev, Asia/Saigon, America/Buenos_Aires and every other backward
  // link. Tested through candidate lists rather than the machine's own clock,
  // which is why this survives a CI runner set to UTC.
  it("finds nothing when only the deprecated alias is offered", () => {
    expect(resolveZoneCoordinates(TABLE, ["Asia/Calcutta"])).toBeNull();
  });

  it("resolves once the canonical name is also a candidate", () => {
    const result = resolveZoneCoordinates(TABLE, ["Asia/Calcutta", "Asia/Kolkata"]);
    expect(result?.label).toBe("Asia/Kolkata");
    expect(result?.source).toBe("timezone");
    expect(result?.lat).toBe(22.53);
    expect(result?.lon).toBe(88.37);
  });

  it("takes the first candidate that is actually listed", () => {
    expect(resolveZoneCoordinates(TABLE, ["America/New_York", "Asia/Kolkata"])?.label).toBe(
      "America/New_York",
    );
  });

  it("returns coarsened coordinates", () => {
    const result = resolveZoneCoordinates(TABLE, ["America/New_York"]);
    expect(result!.lat).toBe(coarsen(result!.lat));
    expect(result!.lon).toBe(coarsen(result!.lon));
  });

  it("returns null for a UTC-only machine — there is no city to point at", () => {
    // Exactly the CI runner's situation: a legitimate null, not a failure.
    expect(resolveZoneCoordinates(TABLE, ["UTC"])).toBeNull();
    expect(resolveZoneCoordinates(TABLE, [])).toBeNull();
  });
});

describe("locationFromTimezone", () => {
  // Deliberately tolerant: the result depends on how the machine's clock is
  // configured, and null is correct on a UTC box. Only the shape is asserted.
  it("returns either null or sane, coarsened coordinates", () => {
    const result = locationFromTimezone();
    if (result === null) return;
    expect(result.source).toBe("timezone");
    expect(Math.abs(result.lat)).toBeLessThanOrEqual(90);
    expect(Math.abs(result.lon)).toBeLessThanOrEqual(180);
    expect(result.lat).toBe(coarsen(result.lat));
    expect(result.lon).toBe(coarsen(result.lon));
  });
});

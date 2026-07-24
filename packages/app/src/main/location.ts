import { existsSync, readFileSync, readlinkSync } from "node:fs";
import { isAvailable, send, onLine } from "./native-helper";

/**
 * Where to ask about the weather.
 *
 * Three layers, and the ordering matters more than it looks:
 *
 *  1. **Manual** — whatever the user typed in Settings. Always wins.
 *  2. **Timezone** — parsed from the tz database already on every Mac. Instant,
 *     needs no permission, makes no network request, and is accurate to roughly
 *     the nearest big city.
 *  3. **CoreLocation** — precise, but requires a TCC grant that may never
 *     arrive (and demonstrably does not arrive for an unbundled helper).
 *
 * Layer 2 is the DEFAULT rather than a fallback: it resolves synchronously, so
 * weather can render immediately, and CoreLocation is only ever a background
 * upgrade that replaces the guess if and when it answers. That way a denied,
 * disabled, or silently broken location grant costs the user nothing — not even
 * a spinner.
 */

export interface Coordinates {
  lat: number;
  lon: number;
  /** How we got here — surfaced in Settings so the guess is never mistaken for a fix. */
  source: "manual" | "device" | "timezone";
  /** Human label, e.g. "Asia/Kolkata" or whatever the user typed. */
  label: string;
}

/**
 * macOS keeps the tz database here; /usr/share/zoneinfo is usually a symlink to
 * it. Both are checked because the symlink has moved between releases.
 */
const ZONE_TAB_PATHS = [
  "/var/db/timezone/zoneinfo/zone.tab",
  "/usr/share/zoneinfo/zone.tab",
];

/**
 * Parse an ISO 6709 coordinate as zone.tab writes it: `+2232+08822` or
 * `+404251-0740023` (degrees-minutes, optionally with seconds; latitude is
 * 2-digit degrees, longitude 3-digit).
 *
 * Returns null for anything that doesn't match — zone.tab is system-owned and
 * we'd rather guess nothing than guess wrong.
 */
export function parseIso6709(value: string): { lat: number; lon: number } | null {
  const match = /^([+-])(\d{2})(\d{2})(\d{2})?([+-])(\d{3})(\d{2})(\d{2})?$/.exec(value.trim());
  if (!match) return null;

  const [, latSign, latDeg, latMin, latSec, lonSign, lonDeg, lonMin, lonSec] = match;
  const toDegrees = (deg: string, min: string, sec: string | undefined): number =>
    Number(deg) + Number(min) / 60 + (sec ? Number(sec) / 3600 : 0);

  const lat = toDegrees(latDeg, latMin, latSec) * (latSign === "-" ? -1 : 1);
  const lon = toDegrees(lonDeg, lonMin, lonSec) * (lonSign === "-" ? -1 : 1);
  if (Math.abs(lat) > 90 || Math.abs(lon) > 180) return null;
  return { lat, lon };
}

/**
 * Find a zone's coordinates in zone.tab content. Lines are
 * `CC<tab>coordinates<tab>TZ[<tab>comment]`, with `#` comments.
 */
export function findZoneCoordinates(
  tableContent: string,
  zone: string,
): { lat: number; lon: number } | null {
  for (const line of tableContent.split("\n")) {
    if (line.startsWith("#") || line.trim() === "") continue;
    const fields = line.split("\t");
    if (fields.length < 3 || fields[2].trim() !== zone) continue;
    return parseIso6709(fields[1]);
  }
  return null;
}

/** Round to ~1km. Weather is city-scale; more precision is leakage, not accuracy. */
export function coarsen(value: number): number {
  return Math.round(value * 100) / 100;
}

/**
 * The zone name from /etc/localtime's symlink target, which is always a
 * CANONICAL name (".../zoneinfo/Asia/Kolkata").
 */
export function zoneFromLocaltimeLink(linkTarget: string): string | null {
  const match = /(?:^|\/)zoneinfo\/(.+)$/.exec(linkTarget);
  const zone = match?.[1];
  // Sanity: a real zone is "Area/Location", not a stray file like "posixrules".
  return zone && zone.includes("/") ? zone : null;
}

/**
 * Zone names to try, best first.
 *
 * More than one is necessary because `Intl` may report a DEPRECATED ALIAS while
 * zone.tab lists only canonical names — "Asia/Calcutta" vs "Asia/Kolkata",
 * "Europe/Kiev" vs "Europe/Kyiv", "Asia/Saigon" vs "Asia/Ho_Chi_Minh". Looking
 * up only what Intl says silently finds nothing for those users. The symlink
 * target is canonical by construction, so it resolves the alias without us
 * shipping and maintaining a table of them.
 */
export function zoneCandidates(): string[] {
  const found: string[] = [];
  const add = (zone: string | null | undefined): void => {
    if (zone && !found.includes(zone)) found.push(zone);
  };

  add(process.env.TZ);
  try {
    add(Intl.DateTimeFormat().resolvedOptions().timeZone);
  } catch {
    /* no ICU data -> rely on the symlink */
  }
  try {
    add(zoneFromLocaltimeLink(readlinkSync("/etc/localtime")));
  } catch {
    /* not a symlink (or absent) -> whatever Intl gave us stands */
  }
  return found;
}

/**
 * First candidate zone that appears in the table, with its coordinates.
 *
 * Pure, and separate from the disk and environment reads so the alias handling
 * can be tested without depending on how the running machine's clock happens to
 * be configured. Returns null when none of the candidates is listed — which is
 * the correct answer for "UTC" or "GMT", where there is no city to point at.
 */
export function resolveZoneCoordinates(
  table: string,
  candidates: readonly string[],
): Coordinates | null {
  for (const zone of candidates) {
    const found = findZoneCoordinates(table, zone);
    if (found) {
      return { lat: coarsen(found.lat), lon: coarsen(found.lon), source: "timezone", label: zone };
    }
  }
  return null;
}

/**
 * Best-effort coordinates from the timezone alone. No permission, no network,
 * no bundled dataset — the tz database is public domain and already installed.
 *
 * Null is a legitimate result (a machine set to UTC has no meaningful city);
 * callers fall through to asking the user.
 */
export function locationFromTimezone(): Coordinates | null {
  const candidates = zoneCandidates();
  if (candidates.length === 0) return null;

  for (const path of ZONE_TAB_PATHS) {
    try {
      if (!existsSync(path)) continue;
      const resolved = resolveZoneCoordinates(readFileSync(path, "utf8"), candidates);
      if (resolved) return resolved;
    } catch {
      continue; // unreadable -> try the next path
    }
  }
  return null;
}

/** Parse a user-typed "22.57, 88.36" into coordinates. */
export function parseManualLocation(input: string): { lat: number; lon: number } | null {
  const match = /^\s*(-?\d+(?:\.\d+)?)\s*[, ]\s*(-?\d+(?:\.\d+)?)\s*$/.exec(input);
  if (!match) return null;
  const lat = Number(match[1]);
  const lon = Number(match[2]);
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) return null;
  if (Math.abs(lat) > 90 || Math.abs(lon) > 180) return null;
  return { lat: coarsen(lat), lon: coarsen(lon) };
}

/**
 * Ask the sidecar for a precise fix. Resolves null on any refusal, timeout, or
 * absence — every one of which is an ordinary outcome, not an error worth
 * bothering the user about. The sidecar rounds before replying, so a precise
 * coordinate never reaches this process either.
 */
export function requestDeviceLocation(): Promise<Coordinates | null> {
  if (!isAvailable()) return Promise.resolve(null);

  return new Promise((resolve) => {
    let settled = false;
    const done = (result: Coordinates | null) => {
      if (settled) return;
      settled = true;
      off();
      clearTimeout(timer);
      resolve(result);
    };

    const off = onLine((line) => {
      if (line.startsWith("loc ")) {
        const [, lat, lon] = line.split(" ");
        const parsed = { lat: Number(lat), lon: Number(lon) };
        if (!Number.isFinite(parsed.lat) || !Number.isFinite(parsed.lon)) return done(null);
        done({ ...parsed, source: "device", label: "Current location" });
      } else if (line.startsWith("loc-error")) {
        console.log(`[location] device fix unavailable (${line.slice(10) || "unknown"})`);
        done(null);
      }
    });

    // Longer than the sidecar's own 8s timeout, so its explanation wins.
    const timer = setTimeout(() => done(null), 11_000);
    if (!send("location")) done(null);
  });
}

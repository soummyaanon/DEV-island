import { app, net, powerMonitor } from "electron";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  deriveCondition,
  describeCondition,
  formatTemperature,
  isCondition,
  isPrecipitating,
  type Condition,
} from "./weather-conditions";
import {
  locationFromTimezone,
  parseManualLocation,
  requestDeviceLocation,
  type Coordinates,
} from "./location";

/**
 * Local weather for the island's idle state.
 *
 * This is the ONLY ongoing network request Agent Island makes besides the
 * update check, and it exists only while the user has weather switched on
 * (it ships off). Open-Meteo needs no API key and no account. What leaves the
 * machine is a latitude and longitude rounded to two decimals — nothing else,
 * no identifier, no session data. See the privacy section of README.md.
 */

const ENDPOINT = "https://api.open-meteo.com/v1/forecast";
const POLL_MS = 15 * 60 * 1000;
/** Backoff after a failure, doubling to a ceiling — the sky can wait. */
const RETRY_MIN_MS = 60 * 1000;
const RETRY_MAX_MS = 30 * 60 * 1000;

export interface WeatherState {
  condition: Condition;
  /** Formatted for display, e.g. "27°". */
  temperature: string;
  /** Spoken summary — the scene itself is decorative and aria-hidden. */
  summary: string;
  /** Where the coordinates came from, so Settings can be honest about it. */
  locationLabel: string;
  locationSource: Coordinates["source"];
  /** True when this is a cached reading we couldn't refresh. */
  stale: boolean;
}

type Listener = (state: WeatherState | null) => void;

let listeners: Listener[] = [];
let current: WeatherState | null = null;
let timer: ReturnType<typeof setTimeout> | null = null;
let retryMs = RETRY_MIN_MS;
let enabled = false;
let units: "auto" | "c" | "f" = "auto";
let manualLocation = "";
/** Set once a device fix arrives; it outranks the timezone guess from then on. */
let deviceLocation: Coordinates | null = null;
let deviceAsked = false;
/** Forced scene for development — see AGENT_ISLAND_WEATHER. */
let override: Condition | null = null;

export function onWeather(listener: Listener): () => void {
  listeners.push(listener);
  return () => {
    listeners = listeners.filter((l) => l !== listener);
  };
}

export function getWeather(): WeatherState | null {
  return current;
}

function publish(next: WeatherState | null): void {
  const changed = current?.condition !== next?.condition || current?.temperature !== next?.temperature;
  current = next;
  if (!changed) return;
  for (const listener of listeners) listener(next);
}

/* ---- Cache: a launch with no network still shows something ---- */

function cachePath(): string {
  return join(app.getPath("userData"), "weather-cache.json");
}

function readCache(): WeatherState | null {
  try {
    if (!existsSync(cachePath())) return null;
    const parsed = JSON.parse(readFileSync(cachePath(), "utf8")) as Partial<WeatherState>;
    if (!isCondition(parsed.condition)) return null;
    return {
      condition: parsed.condition,
      temperature: typeof parsed.temperature === "string" ? parsed.temperature : "",
      summary: typeof parsed.summary === "string" ? parsed.summary : "",
      locationLabel: typeof parsed.locationLabel === "string" ? parsed.locationLabel : "",
      locationSource: parsed.locationSource === "manual" || parsed.locationSource === "device"
        ? parsed.locationSource
        : "timezone",
      // Anything read back from disk is by definition not a fresh reading.
      stale: true,
    };
  } catch {
    return null; // corrupt cache -> behave as though there were none
  }
}

function writeCache(state: WeatherState): void {
  try {
    writeFileSync(cachePath(), `${JSON.stringify({ ...state, stale: false }, null, 2)}\n`);
  } catch {
    /* cache is a nicety, never worth surfacing */
  }
}

/* ---- Location ---- */

/**
 * Coordinates to ask about, resolved synchronously.
 *
 * Deliberately never awaits CoreLocation: the timezone guess is good enough to
 * render immediately, and a device fix — which may never come — only replaces it
 * once it arrives. A denied or broken location grant therefore costs the user
 * nothing, not even a delay.
 */
function resolveLocation(): Coordinates | null {
  const manual = manualLocation.trim() === "" ? null : parseManualLocation(manualLocation);
  if (manual) return { ...manual, source: "manual", label: manualLocation.trim() };
  if (deviceLocation) return deviceLocation;
  return locationFromTimezone();
}

/** Ask the sidecar for a precise fix, once per run, in the background. */
function upgradeLocationInBackground(): void {
  if (deviceAsked) return;
  deviceAsked = true;
  void requestDeviceLocation().then((fix) => {
    if (!fix) return; // denied, unavailable, timed out — the guess stands
    deviceLocation = fix;
    console.log("[weather] upgraded to a device location fix");
    void refresh();
  });
}

/* ---- Fetch ---- */

/**
 * Shape of the Open-Meteo reply. Every time is an epoch SECOND, because we ask
 * for `timeformat=unixtime` — the default ISO strings come back without a zone
 * suffix, so `Date.parse` would read them in the Mac's timezone even when the
 * location is somewhere else, quietly skewing every sunrise and rainbow window
 * by the offset between the two.
 */
interface OpenMeteoResponse {
  current?: { temperature_2m?: number; weather_code?: number; is_day?: number };
  daily?: { sunrise?: number[]; sunset?: number[] };
  hourly?: { time?: number[]; precipitation?: number[] };
}

function requestJson(url: string): Promise<OpenMeteoResponse> {
  return new Promise((resolve, reject) => {
    const request = net.request({ method: "GET", url });
    request.on("response", (response) => {
      if (response.statusCode < 200 || response.statusCode >= 300) {
        reject(new Error(`HTTP ${response.statusCode}`));
        response.on("data", () => {}); // drain so the socket can close
        return;
      }
      const chunks: Buffer[] = [];
      response.on("data", (chunk: Buffer) => chunks.push(chunk));
      response.on("end", () => {
        try {
          resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")) as OpenMeteoResponse);
        } catch (err) {
          reject(err instanceof Error ? err : new Error("unparseable response"));
        }
      });
      response.on("error", reject);
    });
    request.on("error", reject);
    request.end();
  });
}

/**
 * The most recent hour that saw measurable precipitation, as epoch ms.
 * Only looks backwards from `now` — a forecast of rain isn't a rainbow.
 *
 * `times` are epoch seconds (see OpenMeteoResponse).
 */
export function lastPrecipitationBefore(
  times: number[] | undefined,
  amounts: number[] | undefined,
  now: number,
): number | null {
  if (!times || !amounts) return null;
  let latest: number | null = null;
  for (let i = 0; i < times.length && i < amounts.length; i++) {
    const at = times[i] * 1000;
    if (!Number.isFinite(at) || at > now) continue;
    if ((amounts[i] ?? 0) > 0) latest = latest === null ? at : Math.max(latest, at);
  }
  return latest;
}

/**
 * The sunrise/sunset nearest to `now`, which may be tomorrow's once today's has
 * passed. `values` are epoch seconds; null when the API gave none (polar summer).
 */
export function nearestSolarTime(values: number[] | undefined, now: number): number | null {
  if (!values || values.length === 0) return null;
  let best: number | null = null;
  for (const value of values) {
    const at = value * 1000;
    if (!Number.isFinite(at)) continue;
    if (best === null || Math.abs(at - now) < Math.abs(best - now)) best = at;
  }
  return best;
}

async function refresh(): Promise<void> {
  if (!enabled) return;

  const location = resolveLocation();
  if (!location) {
    console.log("[weather] no location available — set one in Settings");
    publish(null);
    return;
  }

  const url =
    `${ENDPOINT}?latitude=${location.lat}&longitude=${location.lon}` +
    "&current=temperature_2m,weather_code,is_day" +
    "&daily=sunrise,sunset" +
    "&hourly=precipitation&past_hours=3&forecast_hours=1" +
    // Epoch seconds, so a location in another timezone can't skew our windows.
    "&timeformat=unixtime&timezone=auto";

  try {
    const data = await requestJson(url);
    const code = data.current?.weather_code;
    const temperature = data.current?.temperature_2m;
    if (typeof code !== "number" || typeof temperature !== "number") {
      throw new Error("response missing current conditions");
    }

    const now = Date.now();
    const condition = deriveCondition({
      code,
      isDay: data.current?.is_day !== 0,
      now,
      sunrise: nearestSolarTime(data.daily?.sunrise, now),
      sunset: nearestSolarTime(data.daily?.sunset, now),
      // If it's raining right now there's no rainbow, so don't even look.
      lastPrecipitationAt: isPrecipitating(code)
        ? null
        : lastPrecipitationBefore(data.hourly?.time, data.hourly?.precipitation, now),
    });

    const state: WeatherState = {
      condition,
      temperature: formatTemperature(temperature, units, app.getLocale()),
      summary: `${describeCondition(condition)}, ${formatTemperature(temperature, units, app.getLocale())}`,
      locationLabel: location.label,
      locationSource: location.source,
      stale: false,
    };
    publish(state);
    writeCache(state);
    retryMs = RETRY_MIN_MS;
    schedule(POLL_MS);
  } catch (err) {
    console.warn(`[weather] refresh failed: ${err instanceof Error ? err.message : String(err)}`);
    // Keep showing the last good reading, flagged stale.
    if (current && !current.stale) publish({ ...current, stale: true });
    schedule(retryMs);
    retryMs = Math.min(retryMs * 2, RETRY_MAX_MS);
  }
}

function schedule(delay: number): void {
  if (timer) clearTimeout(timer);
  if (!enabled) return;
  timer = setTimeout(() => void refresh(), delay);
}

/* ---- Lifecycle ---- */

/** A forced condition for development: AGENT_ISLAND_WEATHER=thunder. */
function readOverride(): Condition | null {
  const value = process.env.AGENT_ISLAND_WEATHER;
  if (!value) return null;
  if (!isCondition(value)) {
    console.warn(`[weather] ignoring AGENT_ISLAND_WEATHER=${value} (not a condition)`);
    return null;
  }
  console.log(`[weather] forced to "${value}" by AGENT_ISLAND_WEATHER`);
  return value;
}

export function startWeather(options: { enabled: boolean; units: "auto" | "c" | "f"; location: string }): void {
  enabled = options.enabled;
  units = options.units;
  manualLocation = options.location;
  override = readOverride();

  if (!enabled) {
    stopWeather();
    return;
  }

  // A forced condition skips the network entirely — that's the point of it.
  if (override) {
    publish({
      condition: override,
      temperature: formatTemperature(21, units, app.getLocale()),
      summary: `${describeCondition(override)}, forced`,
      locationLabel: "AGENT_ISLAND_WEATHER",
      locationSource: "manual",
      stale: false,
    });
    return;
  }

  if (!current) publish(readCache());
  void refresh();
  upgradeLocationInBackground();

  // Asleep for hours: the cached reading is worthless on wake.
  powerMonitor.on("resume", () => void refresh());
}

export function stopWeather(): void {
  enabled = false;
  if (timer) clearTimeout(timer);
  timer = null;
  publish(null);
}

/** Apply changed settings without a restart. */
export function updateWeatherSettings(options: {
  enabled: boolean;
  units: "auto" | "c" | "f";
  location: string;
}): void {
  const locationChanged = options.location.trim() !== manualLocation.trim();
  const wasEnabled = enabled;
  enabled = options.enabled;
  units = options.units;
  manualLocation = options.location;

  if (!enabled) {
    stopWeather();
    return;
  }
  if (!wasEnabled) {
    startWeather(options);
    return;
  }
  // Units alone don't need a round trip, but re-deriving is simplest and the
  // response is cached upstream anyway.
  if (locationChanged) retryMs = RETRY_MIN_MS;
  void refresh();
}

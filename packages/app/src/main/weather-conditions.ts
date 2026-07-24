/**
 * Turning a weather report into one of ten scenes.
 *
 * Kept separate from the fetching in `weather.ts` and entirely pure, because
 * this is the part with actual judgement in it — and the part you cannot
 * otherwise test without waiting for it to snow.
 */

export const CONDITIONS = [
  "clear-day",
  "clear-night",
  "cloudy",
  "fog",
  "rain",
  "snow",
  "thunder",
  "sunrise",
  "sunset",
  "rainbow",
] as const;

export type Condition = (typeof CONDITIONS)[number];

export function isCondition(value: unknown): value is Condition {
  return typeof value === "string" && (CONDITIONS as readonly string[]).includes(value);
}

/**
 * WMO 4677 weather codes, as Open-Meteo reports them in `weather_code`.
 * Grouped rather than enumerated one-by-one: the boundaries are what matter.
 */
export function conditionFromWmoCode(code: number, isDay: boolean): Condition {
  if (code >= 95) return "thunder"; // 95, 96, 99 — thunderstorm, with or without hail
  if (code >= 85) return "snow"; // 85, 86 — snow showers
  if (code >= 80) return "rain"; // 80-82 — rain showers
  if (code >= 71 && code <= 77) return "snow"; // snowfall and snow grains
  if (code >= 51 && code <= 67) return "rain"; // drizzle, rain, freezing rain
  if (code === 45 || code === 48) return "fog"; // fog and depositing rime fog
  if (code >= 2) return "cloudy"; // 2 partly cloudy, 3 overcast
  return isDay ? "clear-day" : "clear-night"; // 0 clear, 1 mainly clear
}

/** Codes that mean water is falling right now. */
export function isPrecipitating(code: number): boolean {
  const condition = conditionFromWmoCode(code, true);
  return condition === "rain" || condition === "snow" || condition === "thunder";
}

/** How close to sunrise/sunset counts as being "at" it. */
export const GOLDEN_WINDOW_MINUTES = 25;

/** How long after rain stops a rainbow may appear. */
export const RAINBOW_WINDOW_MINUTES = 30;

const MINUTE = 60_000;

export interface WeatherFacts {
  /** WMO code for the current conditions. */
  code: number;
  isDay: boolean;
  /** Epoch ms. */
  now: number;
  /** Epoch ms, or null when the API didn't say (polar summer, parse failure). */
  sunrise: number | null;
  sunset: number | null;
  /**
   * Epoch ms of the most recent hour with measurable precipitation, or null.
   * Drives the rainbow; without it there's no way to know rain just stopped.
   */
  lastPrecipitationAt: number | null;
}

/**
 * The scene to draw.
 *
 * Three of the ten conditions aren't in the weather code at all and have to be
 * derived, in this order of precedence:
 *
 *  - **thunder/rain/snow/fog win outright.** What's falling on you is the most
 *    important fact, and a sunset behind a thunderstorm is a thunderstorm.
 *  - **rainbow** only when rain has just stopped, in daylight. It's a 30-minute
 *    window and deliberately rare — that's what makes it worth having.
 *  - **sunrise/sunset** replace the plain clear/cloudy scenes near the golden
 *    window, because that's when the sky is actually doing something.
 */
export function deriveCondition(facts: WeatherFacts): Condition {
  const base = conditionFromWmoCode(facts.code, facts.isDay);

  // Active weather is never overridden by time of day.
  if (base === "thunder" || base === "rain" || base === "snow" || base === "fog") return base;

  // Rainbow: it stopped raining recently, the sun is up, and the sky is opening.
  if (facts.isDay && facts.lastPrecipitationAt !== null) {
    const since = facts.now - facts.lastPrecipitationAt;
    if (since >= 0 && since <= RAINBOW_WINDOW_MINUTES * MINUTE) return "rainbow";
  }

  // Golden hour, but only when there's sky to see it in.
  const window = GOLDEN_WINDOW_MINUTES * MINUTE;
  if (facts.sunrise !== null && Math.abs(facts.now - facts.sunrise) <= window) return "sunrise";
  if (facts.sunset !== null && Math.abs(facts.now - facts.sunset) <= window) return "sunset";

  return base;
}

/**
 * Short spoken/written summary. This is the accessible name for the whole
 * scene — the animation itself is decorative and hidden from assistive tech, so
 * this text is the only thing a VoiceOver user gets.
 */
const CONDITION_WORDS: Record<Condition, string> = {
  "clear-day": "Clear",
  "clear-night": "Clear night",
  cloudy: "Cloudy",
  fog: "Fog",
  rain: "Rain",
  snow: "Snow",
  thunder: "Thunderstorms",
  sunrise: "Sunrise",
  sunset: "Sunset",
  rainbow: "Clearing up",
};

export function describeCondition(condition: Condition): string {
  return CONDITION_WORDS[condition];
}

/** Celsius in, formatted string out. `auto` follows the locale's usual unit. */
export function formatTemperature(celsius: number, units: "auto" | "c" | "f", locale?: string): string {
  const useFahrenheit = units === "f" || (units === "auto" && prefersFahrenheit(locale));
  const value = useFahrenheit ? (celsius * 9) / 5 + 32 : celsius;
  return `${Math.round(value)}°`;
}

/**
 * The handful of places that still use Fahrenheit day to day. Derived from the
 * locale rather than the coordinates, because the user's own formatting
 * preference is a better signal than where they happen to be standing.
 */
const FAHRENHEIT_REGIONS = new Set(["US", "BS", "BZ", "KY", "LR", "PW", "FM", "MH"]);

export function prefersFahrenheit(locale?: string): boolean {
  const tag = locale ?? "en-US";
  // "en-US" -> "US"; also handles "en-Latn-US" and bare "US".
  const region = tag.split("-").find((part) => /^[A-Z]{2}$/.test(part));
  return region !== undefined && FAHRENHEIT_REGIONS.has(region);
}

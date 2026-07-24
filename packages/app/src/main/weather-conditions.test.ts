import { describe, expect, it } from "vitest";
import {
  conditionFromWmoCode,
  deriveCondition,
  describeCondition,
  CONDITIONS,
  formatTemperature,
  GOLDEN_WINDOW_MINUTES,
  isPrecipitating,
  prefersFahrenheit,
  RAINBOW_WINDOW_MINUTES,
  type WeatherFacts,
} from "./weather-conditions";

const MINUTE = 60_000;
const NOON = Date.parse("2026-07-25T12:00:00.000Z");

const facts = (over: Partial<WeatherFacts> = {}): WeatherFacts => ({
  code: 0,
  isDay: true,
  now: NOON,
  sunrise: null,
  sunset: null,
  lastPrecipitationAt: null,
  ...over,
});

describe("conditionFromWmoCode", () => {
  it("splits clear skies by day and night", () => {
    expect(conditionFromWmoCode(0, true)).toBe("clear-day");
    expect(conditionFromWmoCode(0, false)).toBe("clear-night");
    expect(conditionFromWmoCode(1, false)).toBe("clear-night");
  });

  it("maps each WMO band to its scene", () => {
    expect(conditionFromWmoCode(2, true)).toBe("cloudy");
    expect(conditionFromWmoCode(3, true)).toBe("cloudy");
    expect(conditionFromWmoCode(45, true)).toBe("fog");
    expect(conditionFromWmoCode(48, true)).toBe("fog");
    expect(conditionFromWmoCode(55, true)).toBe("rain"); // drizzle
    expect(conditionFromWmoCode(65, true)).toBe("rain");
    expect(conditionFromWmoCode(67, true)).toBe("rain"); // freezing rain
    expect(conditionFromWmoCode(73, true)).toBe("snow");
    expect(conditionFromWmoCode(77, true)).toBe("snow"); // snow grains
    expect(conditionFromWmoCode(81, true)).toBe("rain"); // showers
    expect(conditionFromWmoCode(86, true)).toBe("snow"); // snow showers
    expect(conditionFromWmoCode(95, true)).toBe("thunder");
    expect(conditionFromWmoCode(99, true)).toBe("thunder");
  });

  it("keeps 71-77 as snow rather than falling through to the rain band", () => {
    // The bands are ordered so this can't regress into `rain`.
    for (const code of [71, 73, 75, 77]) {
      expect(conditionFromWmoCode(code, true)).toBe("snow");
    }
  });

  it("treats an unknown high code as a thunderstorm, the safest guess", () => {
    expect(conditionFromWmoCode(120, true)).toBe("thunder");
  });
});

describe("isPrecipitating", () => {
  it("is true for anything falling and false otherwise", () => {
    expect(isPrecipitating(61)).toBe(true);
    expect(isPrecipitating(73)).toBe(true);
    expect(isPrecipitating(95)).toBe(true);
    expect(isPrecipitating(0)).toBe(false);
    expect(isPrecipitating(3)).toBe(false);
    expect(isPrecipitating(45)).toBe(false);
  });
});

describe("deriveCondition", () => {
  it("lets active weather beat the time of day", () => {
    // A sunset behind a thunderstorm is a thunderstorm.
    expect(deriveCondition(facts({ code: 95, sunset: NOON }))).toBe("thunder");
    expect(deriveCondition(facts({ code: 63, sunrise: NOON }))).toBe("rain");
    expect(deriveCondition(facts({ code: 45, sunset: NOON }))).toBe("fog");
  });

  it("shows sunrise and sunset inside the golden window", () => {
    expect(deriveCondition(facts({ sunrise: NOON }))).toBe("sunrise");
    expect(deriveCondition(facts({ sunset: NOON }))).toBe("sunset");
    const edge = (GOLDEN_WINDOW_MINUTES - 1) * MINUTE;
    expect(deriveCondition(facts({ sunset: NOON + edge }))).toBe("sunset");
    expect(deriveCondition(facts({ sunset: NOON - edge }))).toBe("sunset");
  });

  it("falls back to the plain scene outside the golden window", () => {
    const past = (GOLDEN_WINDOW_MINUTES + 1) * MINUTE;
    expect(deriveCondition(facts({ sunset: NOON + past }))).toBe("clear-day");
    expect(deriveCondition(facts({ code: 3, sunset: NOON + past }))).toBe("cloudy");
  });

  it("still works where the sun never rises or sets", () => {
    expect(deriveCondition(facts({ sunrise: null, sunset: null }))).toBe("clear-day");
  });

  it("shows a rainbow shortly after rain stops in daylight", () => {
    expect(deriveCondition(facts({ lastPrecipitationAt: NOON - 10 * MINUTE }))).toBe("rainbow");
  });

  it("stops showing the rainbow once the window closes", () => {
    const stale = (RAINBOW_WINDOW_MINUTES + 1) * MINUTE;
    expect(deriveCondition(facts({ lastPrecipitationAt: NOON - stale }))).toBe("clear-day");
  });

  it("never shows a rainbow at night", () => {
    expect(
      deriveCondition(facts({ isDay: false, lastPrecipitationAt: NOON - 5 * MINUTE })),
    ).toBe("clear-night");
  });

  it("never shows a rainbow while it is still raining", () => {
    expect(deriveCondition(facts({ code: 61, lastPrecipitationAt: NOON }))).toBe("rain");
  });

  it("prefers a rainbow over the golden window — it's rarer and more specific", () => {
    expect(
      deriveCondition(facts({ sunset: NOON, lastPrecipitationAt: NOON - 5 * MINUTE })),
    ).toBe("rainbow");
  });

  it("ignores a precipitation timestamp from the future", () => {
    // Clock skew between us and the API must not pin a permanent rainbow.
    expect(deriveCondition(facts({ lastPrecipitationAt: NOON + 10 * MINUTE }))).toBe("clear-day");
  });
});

describe("describeCondition", () => {
  it("gives every condition a spoken name — it's the scene's only accessible text", () => {
    for (const condition of CONDITIONS) {
      expect(describeCondition(condition).length).toBeGreaterThan(0);
    }
  });
});

describe("prefersFahrenheit", () => {
  it("is true for US-style locales", () => {
    expect(prefersFahrenheit("en-US")).toBe(true);
    expect(prefersFahrenheit("en-Latn-US")).toBe(true);
  });

  it("is false nearly everywhere else", () => {
    expect(prefersFahrenheit("en-GB")).toBe(false);
    expect(prefersFahrenheit("en-IN")).toBe(false);
    expect(prefersFahrenheit("de-DE")).toBe(false);
    expect(prefersFahrenheit("ja-JP")).toBe(false);
  });

  it("does not treat a bare language as Fahrenheit", () => {
    expect(prefersFahrenheit("en")).toBe(false);
  });
});

describe("formatTemperature", () => {
  it("rounds Celsius by default", () => {
    expect(formatTemperature(23.6, "c")).toBe("24°");
    expect(formatTemperature(-3.6, "c")).toBe("-4°");
  });

  it("shows a hair below freezing as 0°, not -0°", () => {
    // Math.round(-0.4) is -0, which stringifies to "0" — the reading we want.
    expect(formatTemperature(-0.4, "c")).toBe("0°");
  });

  it("converts when Fahrenheit is asked for", () => {
    expect(formatTemperature(0, "f")).toBe("32°");
    expect(formatTemperature(100, "f")).toBe("212°");
  });

  it("follows the locale on auto", () => {
    expect(formatTemperature(0, "auto", "en-US")).toBe("32°");
    expect(formatTemperature(0, "auto", "en-IN")).toBe("0°");
  });
});

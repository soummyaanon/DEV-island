import { describe, expect, it } from "vitest";
import { DEFAULT_SOUND_PREFS, resolveTheme } from "./sound-prefs";

describe("resolveTheme", () => {
  it("follows the base theme when no override exists", () => {
    expect(resolveTheme("success", { ...DEFAULT_SOUND_PREFS, theme: "arcade" })).toBe("arcade");
  });

  it("prefers a per-event override over the base theme", () => {
    const prefs = {
      ...DEFAULT_SOUND_PREFS,
      theme: "soft" as const,
      overrides: { approve: "anime" as const },
    };
    expect(resolveTheme("approve", prefs)).toBe("anime");
    expect(resolveTheme("success", prefs)).toBe("soft");
  });

  it("falls back to 8bit when stored values are invalid (old settings files)", () => {
    const prefs = {
      on: true,
      theme: "vaporwave" as never,
      overrides: { question: "screamo" as never },
    };
    expect(resolveTheme("question", prefs)).toBe("8bit");
  });
});

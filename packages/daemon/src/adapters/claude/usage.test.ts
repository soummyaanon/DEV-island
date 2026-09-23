import { describe, expect, it } from "vitest";
import { freshWindows, parseClaudeUsage } from "./usage";

const NOW = Date.parse("2026-09-23T12:00:00.000Z");
const later = Math.floor(NOW / 1000) + 3600;
const earlier = Math.floor(NOW / 1000) - 60;

describe("parseClaudeUsage", () => {
  it("reads the 5-hour and weekly windows from the status line JSON", () => {
    const usage = parseClaudeUsage(
      {
        model: { id: "claude-opus" },
        rate_limits: {
          five_hour: { used_percentage: 42.5, resets_at: later },
          seven_day: { used_percentage: 18, resets_at: later + 86400 },
        },
      },
      NOW,
    );
    expect(usage?.agent).toBe("claude-code");
    expect(usage?.windows).toEqual([
      { label: "5h", used_percent: 42.5, resets_at: later },
      { label: "weekly", used_percent: 18, resets_at: later + 86400 },
    ]);
  });

  it("drops a window that already reset, and is null with nothing usable", () => {
    const usage = parseClaudeUsage(
      { rate_limits: { five_hour: { used_percentage: 90, resets_at: earlier }, seven_day: { used_percentage: 5, resets_at: later } } },
      NOW,
    );
    expect(usage?.windows.map((w) => w.label)).toEqual(["weekly"]);
    expect(parseClaudeUsage({ model: {} }, NOW)).toBeNull();
    expect(parseClaudeUsage({ rate_limits: { five_hour: { used_percentage: "lots" } } }, NOW)).toBeNull();
    expect(parseClaudeUsage(null, NOW)).toBeNull();
  });
});

describe("freshWindows", () => {
  it("ages out windows past their reset", () => {
    const usage = parseClaudeUsage(
      { rate_limits: { five_hour: { used_percentage: 1, resets_at: later } } },
      NOW,
    )!;
    expect(freshWindows(usage, NOW)).not.toBeNull();
    expect(freshWindows(usage, (later + 1) * 1000)).toBeNull();
  });
});

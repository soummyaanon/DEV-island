import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { StatusFooter, formatResetIn } from "./StatusFooter";

describe("formatResetIn", () => {
  const now = Date.parse("2026-09-23T12:00:00.000Z");
  const sec = (mins: number) => Math.floor(now / 1000) + mins * 60;
  it("reads minutes, hours and days", () => {
    expect(formatResetIn(sec(12), now)).toBe("12m");
    expect(formatResetIn(sec(130), now)).toBe("2h 10m");
    expect(formatResetIn(sec(60 * 24 * 3 + 240), now)).toBe("3d 4h");
    expect(formatResetIn(sec(-5), now)).toBe("0m");
  });
});

describe("StatusFooter quotas", () => {
  it("shows the 5-hour window before the weekly one, each with its own ring", () => {
    const html = renderToStaticMarkup(
      <StatusFooter
        usage={[
          {
            agent: "claude-code",
            plan: null,
            credits: null,
            updated_at: "2026-09-23T12:00:00.000Z",
            windows: [
              { label: "weekly", used_percent: 18.4, resets_at: null },
              { label: "5h", used_percent: 42, resets_at: null },
            ],
          },
        ]}
        power={null}
        focus={null}
        totals={null}
        onClearFocus={() => {}}
      />,
    );
    expect(html).toContain("claude");
    expect(html.indexOf(">5h<")).toBeLessThan(html.indexOf(">wk<"));
    expect(html).toContain("42%");
    expect(html).toContain("18%");
    expect(html).toContain("claude 5-hour limit: 42% used");
  });
});

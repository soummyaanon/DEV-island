import type { AgentUsage } from "@agent-island/shared";

/**
 * One footer row: agent quotas (as before), then the ambient facts — battery,
 * Focus, what the agents are costing. Each item is optional; the row hides
 * when it would be empty.
 */

const AGENT_LABEL: Record<string, string> = {
  "claude-code": "claude",
  codex: "codex",
};

export interface FooterPower {
  percent: number;
  state: "charging" | "discharging" | "charged" | "ac";
  minutesRemaining: number | null;
  low: boolean;
}

export interface FooterFocus {
  active: boolean;
  name: string | null;
}

export interface FooterTotals {
  cpu: number;
  rssMb: number;
}

export function formatMemory(rssMb: number): string {
  return rssMb >= 1024 ? `${(rssMb / 1024).toFixed(1)} GB` : `${rssMb} MB`;
}

export function formatRemaining(minutes: number | null): string {
  if (minutes === null || minutes <= 0) return "";
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return h > 0 ? `${h}:${String(m).padStart(2, "0")}` : `${m}m`;
}

export function StatusFooter({
  usage,
  power,
  focus,
  totals,
  onClearFocus,
}: {
  usage: AgentUsage[];
  power: FooterPower | null;
  focus: FooterFocus | null;
  totals: FooterTotals | null;
  onClearFocus: () => void;
}) {
  const summaries = usage.flatMap((entry) => {
    const tightest = entry.windows.reduce(
      (current, window) => (!current || window.used_percent > current.used_percent ? window : current),
      entry.windows[0],
    );
    if (!tightest && !entry.credits) return [];
    const remaining = tightest ? Math.max(0, Math.round(100 - tightest.used_percent)) : null;
    return [{ agent: AGENT_LABEL[entry.agent] ?? entry.agent, remaining, credits: entry.credits }];
  });

  const showFocus = focus?.active === true;
  const showTotals = totals !== null && totals.cpu + totals.rssMb > 0;
  if (summaries.length === 0 && !power && !showFocus && !showTotals) return null;

  const powerGlyph = power
    ? power.state === "discharging"
      ? "▮"
      : power.state === "charged"
        ? "▮"
        : "⚡︎"
    : "";
  const powerDetail = power
    ? power.state === "discharging"
      ? formatRemaining(power.minutesRemaining)
      : power.state === "charging"
        ? `${formatRemaining(power.minutesRemaining)} to full`.trim()
        : power.state === "charged"
          ? "full"
          : "on power"
    : "";

  return (
    <div className="usage-compact">
      {summaries.map((summary) => (
        <span className="usage-item" key={summary.agent}>
          <b>{summary.agent}</b>
          {summary.remaining !== null && <span>{summary.remaining}% left</span>}
          {summary.credits && <span>{summary.credits} credits</span>}
        </span>
      ))}
      {power && (
        <span className={`usage-item power${power.low ? " low" : ""}`} title="Battery">
          <b>
            {powerGlyph} {power.percent}%
          </b>
          {powerDetail && <span>{powerDetail}</span>}
        </span>
      )}
      {showFocus && (
        <button
          type="button"
          className="usage-item focus-chip"
          title="Focus is on (from your Shortcuts automation). Click if it stayed on by mistake."
          onClick={(e) => {
            e.stopPropagation();
            onClearFocus();
          }}
        >
          <b>☾ {focus?.name ?? "Focus"}</b>
        </button>
      )}
      {showTotals && totals && (
        <span className="usage-item meter-total" title="What your agents are using right now">
          <b>{totals.cpu}% cpu</b>
          <span>{formatMemory(totals.rssMb)}</span>
        </span>
      )}
    </div>
  );
}

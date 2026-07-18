import type { AgentUsage } from "@agent-island/shared";

const AGENT_LABEL: Record<string, string> = {
  "claude-code": "claude",
  codex: "codex",
};

export function UsageFooter({ usage }: { usage: AgentUsage[] }) {
  const summaries = usage.flatMap((entry) => {
    const tightest = entry.windows.reduce(
      (current, window) => (!current || window.used_percent > current.used_percent ? window : current),
      entry.windows[0],
    );
    if (!tightest && !entry.credits) return [];

    const remaining = tightest ? Math.max(0, Math.round(100 - tightest.used_percent)) : null;
    return [
      {
        agent: AGENT_LABEL[entry.agent] ?? entry.agent,
        remaining,
        credits: entry.credits,
      },
    ];
  });

  if (summaries.length === 0) return null;

  return (
    <div className="usage-compact">
      {summaries.map((summary) => (
        <span className="usage-item" key={summary.agent}>
          <b>{summary.agent}</b>
          {summary.remaining !== null && <span>{summary.remaining}% left</span>}
          {summary.credits && <span>{summary.credits} credits</span>}
        </span>
      ))}
    </div>
  );
}

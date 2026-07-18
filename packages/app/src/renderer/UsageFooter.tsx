import type { AgentUsage } from "@agent-island/shared";

const AGENT_LABEL: Record<string, string> = { "claude-code": "claude", codex: "codex" };

function resetIn(resetsAt: number | null, now: number): string {
  if (!resetsAt) return "";
  const secs = resetsAt - Math.floor(now / 1000);
  if (secs <= 0) return "resetting";
  const d = Math.floor(secs / 86400);
  const h = Math.floor((secs % 86400) / 3600);
  const m = Math.floor((secs % 3600) / 60);
  if (d >= 1) return `resets ${d}d`;
  if (h >= 1) return `resets ${h}h`;
  return `resets ${m}m`;
}

function level(left: number): string {
  if (left > 50) return "ok";
  if (left > 20) return "warn";
  return "low";
}

export function UsageFooter({ usage, now }: { usage: AgentUsage[]; now: number }) {
  if (usage.length === 0) return null;
  return (
    <div className="usage">
      {usage.map((u) => (
        <div className="usage-agent" key={u.agent}>
          <div className="usage-head">
            <span className="usage-label">
              {AGENT_LABEL[u.agent] ?? u.agent}
              {u.plan ? ` · ${u.plan}` : ""}
            </span>
            {u.credits && <span className="usage-credits">{u.credits} credits</span>}
          </div>
          {u.windows.map((w, i) => {
            const left = Math.max(0, Math.min(100, 100 - w.used_percent));
            return (
              <div className="usage-window" key={`${u.agent}-${i}`}>
                <span className="usage-wlabel">{w.label}</span>
                <span className="usage-bar">
                  <span className={`usage-fill ${level(left)}`} style={{ width: `${left}%` }} />
                </span>
                <span className="usage-pct">{Math.round(left)}%</span>
                <span className="usage-reset">{resetIn(w.resets_at, now)}</span>
              </div>
            );
          })}
        </div>
      ))}
    </div>
  );
}

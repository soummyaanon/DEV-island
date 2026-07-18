import type { SessionSnapshot, SessionState } from "@agent-island/shared";

const STATE_LABEL: Record<SessionState, string> = {
  starting: "starting",
  working: "working",
  "waiting-for-approval": "approve?",
  idle: "idle",
  done: "done",
  failed: "failed",
};

const AGENT_LABEL: Record<string, string> = {
  "claude-code": "claude",
  codex: "codex",
};

function projectName(cwd: string): string {
  const parts = cwd.split("/").filter(Boolean);
  return parts[parts.length - 1] ?? cwd;
}

function elapsed(fromIso: string, now: number): string {
  const ms = Math.max(0, now - Date.parse(fromIso));
  const total = Math.floor(ms / 1000);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
}

export function StatusDot({ state }: { state: SessionState }) {
  return <span className={`dot state-${state}`} aria-hidden />;
}

export function SessionRow({
  session,
  now,
  index,
}: {
  session: SessionSnapshot;
  now: number;
  index: number;
}) {
  return (
    <li className={`row state-${session.state}`} style={{ animationDelay: `${index * 34}ms` }}>
      <StatusDot state={session.state} />
      <div className="row-main">
        <span className="project">{projectName(session.cwd)}</span>
        <span className="agent">{AGENT_LABEL[session.agent] ?? session.agent}</span>
      </div>
      <span className="status-label">{STATE_LABEL[session.state]}</span>
      <span className="elapsed">{elapsed(session.started_at, now)}</span>
    </li>
  );
}

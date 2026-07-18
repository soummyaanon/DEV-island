import type { SessionSnapshot, SessionState } from "@agent-island/shared";

const AGENT_LABEL: Record<string, string> = {
  "claude-code": "claude",
  codex: "codex",
};

const MODE_LABEL: Record<string, string> = {
  default: "default",
  plan: "plan",
  acceptEdits: "accept",
  auto: "auto",
  dontAsk: "dont ask",
  bypassPermissions: "bypass",
};

function projectName(cwd: string): string {
  const parts = cwd.split("/").filter(Boolean);
  return parts[parts.length - 1] ?? cwd;
}

function elapsed(fromIso: string, now: number): string {
  const total = Math.max(0, Math.floor((now - Date.parse(fromIso)) / 1000));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  if (hours > 0) return `${hours}h ${minutes}m`;
  if (minutes > 0) return `${minutes}m`;
  return `${total}s`;
}

function metaString(session: SessionSnapshot, key: string): string {
  const v = session.meta?.[key];
  return typeof v === "string" ? v : "";
}

export function StatusDot({ state }: { state: SessionState }) {
  return <span className={`dot state-${state}`} aria-hidden />;
}

export function SessionRow({
  session,
  now,
  onJump,
}: {
  session: SessionSnapshot;
  now: number;
  onJump: (session: SessionSnapshot) => void;
}) {
  const term = metaString(session, "term_program");
  const mode = metaString(session, "permission_mode");
  const agent = AGENT_LABEL[session.agent] ?? session.agent;

  return (
    <li
      className={`row state-${session.state}`}
      title={term ? `Jump to ${projectName(session.cwd)} in ${term}` : "Jump to terminal"}
      onClick={(e) => {
        e.stopPropagation();
        onJump(session);
      }}
    >
      <StatusDot state={session.state} />
      <div className="row-main">
        <div className="row-heading">
          <span className="project">{projectName(session.cwd)}</span>
          <span className="elapsed">{elapsed(session.started_at, now)}</span>
        </div>
        <div className="row-detail">
          <span className="activity">{session.title}</span>
          <span className="row-context">
            {agent}
            {mode ? ` · ${MODE_LABEL[mode] ?? mode}` : ""}
          </span>
        </div>
      </div>
    </li>
  );
}

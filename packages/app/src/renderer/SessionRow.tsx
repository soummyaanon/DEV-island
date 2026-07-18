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
  dontAsk: "dont-ask",
  bypassPermissions: "bypass",
};

function projectName(cwd: string): string {
  const parts = cwd.split("/").filter(Boolean);
  return parts[parts.length - 1] ?? cwd;
}

function elapsed(fromIso: string, now: number): string {
  const total = Math.max(0, Math.floor((now - Date.parse(fromIso)) / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
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
  index,
  onJump,
}: {
  session: SessionSnapshot;
  now: number;
  index: number;
  onJump: (session: SessionSnapshot) => void;
}) {
  const agent = AGENT_LABEL[session.agent] ?? session.agent;
  const mode = metaString(session, "permission_mode");
  const term = metaString(session, "term_program");

  return (
    <li
      className={`row state-${session.state}`}
      style={{ animationDelay: `${index * 34}ms` }}
      title={term ? `Jump to ${projectName(session.cwd)} in ${term}` : "Jump to terminal"}
      onClick={(e) => {
        e.stopPropagation();
        onJump(session);
      }}
    >
      <StatusDot state={session.state} />
      <div className="row-main">
        <div className="row-top">
          <span className="project">{projectName(session.cwd)}</span>
          <span className="chips">
            <span className="agent-chip">{agent}</span>
            {mode && <span className={`mode-chip mode-${mode}`}>{MODE_LABEL[mode] ?? mode}</span>}
          </span>
        </div>
        <span className="activity">{session.title}</span>
      </div>
      <span className="elapsed">{elapsed(session.started_at, now)}</span>
    </li>
  );
}

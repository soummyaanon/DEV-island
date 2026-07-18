import type { SessionSnapshot, SessionState } from "@agent-island/shared";

function projectName(cwd: string): string {
  const parts = cwd.split("/").filter(Boolean);
  return parts[parts.length - 1] ?? cwd;
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
  onJump,
}: {
  session: SessionSnapshot;
  onJump: (session: SessionSnapshot) => void;
}) {
  const term = metaString(session, "term_program");

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
        <span className="project">{projectName(session.cwd)}</span>
        <span className="activity">{session.title}</span>
      </div>
    </li>
  );
}

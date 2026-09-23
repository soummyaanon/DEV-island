import type { CSSProperties } from "react";
import type { SessionSnapshot } from "@agent-island/shared";
import { describeSession } from "./a11y";
import { AgentAvatar } from "./agent-avatar";

/**
 * The compact session: its robot with the project name underneath, nothing
 * else — no ring, no dot. The robot's own motion says what it's doing: it
 * hops while working, looks around while it waits, dozes when it's done. Hover for the whole
 * story (the title is the same sentence VoiceOver reads); click to jump.
 */

function projectName(cwd: string): string {
  return cwd.split("/").filter(Boolean).pop() ?? cwd;
}

function elapsed(fromIso: string, now: number): string {
  const total = Math.max(0, Math.floor((now - Date.parse(fromIso)) / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return `${m}m`;
  return `${total}s`;
}

export function SessionBubble({
  session,
  now,
  index = 0,
  paused = false,
  onJump,
}: {
  session: SessionSnapshot;
  now: number;
  index?: number;
  paused?: boolean;
  onJump: (session: SessionSnapshot) => void;
}) {
  const label = describeSession(session, elapsed(session.started_at, now));
  return (
    <li style={{ "--i": index } as CSSProperties}>
      <button
        type="button"
        className={`bubble state-${session.state}`}
        title={label}
        aria-label={label}
        onClick={(e) => {
          e.stopPropagation();
          window.agentIsland.haptic("tick");
          onJump(session);
        }}
      >
        <AgentAvatar session={session} now={now} size={32} paused={paused} interactive={false} badge={false} />
        <span className="bubble-name" aria-hidden>
          {projectName(session.cwd)}
        </span>
      </button>
    </li>
  );
}

import type { AgentKind, SessionState } from "@agent-island/shared";
import { CursorSprite } from "./CursorSprite";
import { OpenAiSprite } from "./OpenAiSprite";
import { ClaudeSprite } from "./ClaudeSprite";

/**
 * A session's status as a ring around its agent's logo — the same idiom as the
 * battery ring. Working spins (transform only); waiting glows amber; done,
 * failed, and idle are solid rings in their state colour. Decorative: the row's
 * spoken label carries the state.
 */
export function AgentRing({ agent, state, size = 18 }: { agent: AgentKind; state: SessionState; size?: number }) {
  const busy = state === "working" || state === "starting";
  const r = 6.6;
  const c = 2 * Math.PI * r;
  // A three-quarter arc while busy reads as activity; otherwise the full ring.
  const dash = busy ? `${(c * 0.72).toFixed(2)} ${(c * 0.28).toFixed(2)}` : `${c.toFixed(2)} 0`;
  const logo = Math.round(size * 0.5);
  return (
    <span className={`agent-ring state-${state}`} style={{ width: size, height: size }} aria-hidden>
      <svg width={size} height={size} viewBox="0 0 16 16" className={`ring-arc${busy ? " spinning" : ""}`}>
        <circle cx="8" cy="8" r={r} fill="none" stroke="currentColor" strokeOpacity="0.16" strokeWidth="1.6" />
        <circle
          cx="8"
          cy="8"
          r={r}
          fill="none"
          stroke="currentColor"
          strokeWidth="1.6"
          strokeLinecap="round"
          strokeDasharray={dash}
          transform="rotate(-90 8 8)"
        />
      </svg>
      <span className="agent-ring-logo">
        {agent === "claude-code" ? (
          <ClaudeSprite size={logo + 1} />
        ) : agent === "codex" ? (
          <OpenAiSprite size={logo - 1} />
        ) : (
          <CursorSprite size={logo} />
        )}
      </span>
    </span>
  );
}

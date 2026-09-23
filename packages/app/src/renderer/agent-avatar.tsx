import { BotAvatar, type BotAvatarState, type BotAvatarType } from "bot-avatars";
import { ThinkingOrb, type OrbSize, type OrbState } from "thinking-orbs";
import type { AgentKind, SessionSnapshot, SessionState } from "@agent-island/shared";

/**
 * Every session is a little character (bot-avatars) and every thought is an
 * orb (thinking-orbs). Both are 2D-canvas animations from Libraries.dev.
 *
 * Identity lives in the body: each agent kind has its own robot and colour, so
 * a Claude session is always the clay-orange mech, Codex the green droid, and
 * Cursor the blue hexagon, and two sessions of the same agent blink out of step
 * via a seed taken from the session key. What the agent is doing lives in the
 * motion: the avatar hops while it works and dozes once it has been quiet for
 * a while, and the orb picks one of its nine animations from the activity line.
 */

export const AGENT_LOOK: Record<AgentKind, { type: BotAvatarType; color: string }> = {
  "claude-code": { type: "mech", color: "#FF8C42" },
  codex: { type: "droid", color: "#2FCB7A" },
  cursor: { type: "hexagon", color: "#35B8FF" },
};

/** Island state colours (island.css) as hex, for canvas tints. */
export const STATE_TINT: Record<SessionState, string> = {
  starting: "#8fb8ff",
  working: "#5ba8ff",
  "waiting-for-approval": "#ffb020",
  idle: "#9a9a9a",
  done: "#4ecb8d",
  failed: "#ff5f56",
};

/** A quiet session falls asleep after this long. */
export const SLEEP_AFTER_MS = 10 * 60 * 1000;

/** Stable 0–1 offset per session, so a row of avatars doesn't blink in unison. */
export function sessionSeed(key: string): number {
  let h = 2166136261;
  for (let i = 0; i < key.length; i += 1) {
    h ^= key.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return (h >>> 0) / 4294967295;
}

export function avatarState(session: SessionSnapshot, now: number): BotAvatarState {
  if (session.state === "working" || session.state === "starting") return "working";
  if (session.state === "waiting-for-approval" || session.pending_question) return "default";
  const quietFor = now - Date.parse(session.updated_at);
  return quietFor > SLEEP_AFTER_MS ? "sleeping" : "default";
}

/** Activity line → which of the orb's nine animations fits it. First match wins. */
const ORB_RULES: Array<[RegExp, OrbState]> = [
  [/\b(search|grep|glob|find|looking|web|fetch|query)/i, "searching"],
  [/\b(edit|writ|patch|creat|updat|refactor|rename|apply)/i, "composing"],
  [/\b(think|plan|reason|consider|analy[sz])/i, "solving"],
  // Reads search too: "weaving" is a Pro state on Libraries.dev, so it's unused.
  [/\b(read|open|view|explor|scan|inspect|list)/i, "searching"],
  [/\b(connect|mcp|start|load|launch|install)/i, "connecting"],
  [/\b(run|bash|test|build|exec|compil|lint|deploy)/i, "working"],
  [/\b(ask|question|prompt|wait)/i, "listening"],
];

export function orbState(session: Pick<SessionSnapshot, "state" | "title" | "pending_question">): OrbState {
  if (session.state === "starting") return "connecting";
  if (session.state === "waiting-for-approval" || session.pending_question) return "listening";
  for (const [pattern, state] of ORB_RULES) if (pattern.test(session.title)) return state;
  return "breathing";
}

/** Busy enough to deserve a thinking orb instead of a static line. */
export function isThinking(state: SessionState): boolean {
  return state === "working" || state === "starting" || state === "waiting-for-approval";
}

/**
 * The session's character with a small state badge. Decorative: the row or
 * card that holds it carries the spoken label.
 */
export function AgentAvatar({
  session,
  now,
  size = 30,
  paused = false,
  interactive = true,
  badge = true,
}: {
  session: SessionSnapshot;
  now: number;
  size?: number;
  paused?: boolean;
  interactive?: boolean;
  /** The state dot; off where a ring around the avatar already says it. */
  badge?: boolean;
}) {
  const look = AGENT_LOOK[session.agent] ?? AGENT_LOOK["claude-code"];
  return (
    <span className={`agent-avatar state-${session.state}`} style={{ width: size, height: size }} aria-hidden>
      <BotAvatar
        type={look.type}
        color={look.color}
        state={avatarState(session, now)}
        size={size}
        seed={sessionSeed(session.key ?? session.session_id ?? "")}
        theme="dark"
        paused={paused}
        interactive={interactive}
        aria-hidden
      />
      {badge && <i className="agent-avatar-badge" />}
    </span>
  );
}

/** A thinking orb tinted for an agent's current state. */
export function AgentOrb({
  state,
  tint,
  size = 20,
  bold = false,
  paused = false,
}: {
  state: OrbState;
  tint?: string;
  size?: OrbSize;
  /** Heavier dots, for the wing, where the orb sits on pure black at a glance. */
  bold?: boolean;
  paused?: boolean;
}) {
  return (
    <span className="agent-orb" aria-hidden>
      <ThinkingOrb
        state={state}
        size={size}
        theme="dark"
        color={tint}
        dotSize={bold ? 1.45 : 1}
        paused={paused}
        aria-hidden
      />
    </span>
  );
}

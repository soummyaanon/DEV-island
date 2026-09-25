import type { SessionSnapshot } from "@agent-island/shared";
import type { OrbState } from "thinking-orbs";

/**
 * What the on-device model is told about your agents with each question: one
 * line per session, the same facts the rows show. Kept short on purpose — the
 * on-device context window is a few thousand tokens and this rides along with
 * every turn. No paths beyond the project folder name, no diffs, no commands.
 */

const AGENT_NAME: Record<string, string> = {
  "claude-code": "Claude Code",
  codex: "Codex",
  cursor: "Cursor",
};

const STATE_NAME: Record<string, string> = {
  starting: "starting",
  working: "working",
  "waiting-for-approval": "waiting for your approval",
  idle: "idle",
  done: "done",
  failed: "failed",
};

export const MAX_CONTEXT_SESSIONS = 8;

export function projectOf(cwd: string): string {
  return cwd.split("/").filter(Boolean).pop() ?? cwd;
}

function minutesAgo(iso: string, now: number): string {
  const m = Math.max(0, Math.round((now - Date.parse(iso)) / 60000));
  return m === 0 ? "just now" : `${m} min ago`;
}

export function assistantContext(sessions: SessionSnapshot[], now: number): string {
  // No sessions, no preamble: a general question goes to the model as asked.
  if (sessions.length === 0) return "";
  return sessions
    .slice(0, MAX_CONTEXT_SESSIONS)
    .map((s) => {
      const state = s.pending_question ? "asking you a question" : (STATE_NAME[s.state] ?? s.state);
      const title = s.title.replace(/\s+/g, " ").slice(0, 80);
      return `- ${projectOf(s.cwd)} (${AGENT_NAME[s.agent] ?? s.agent}): ${state}${
        title ? `, "${title}"` : ""
      }, updated ${minutesAgo(s.updated_at, now)}`;
    })
    .join("\n");
}

/** The session a tool call named — exact project name first, then a prefix. */
export function findSessionByProject(
  sessions: SessionSnapshot[],
  project: string,
): SessionSnapshot | null {
  const wanted = project.trim().toLowerCase();
  if (!wanted) return null;
  return (
    sessions.find((s) => projectOf(s.cwd).toLowerCase() === wanted) ??
    sessions.find((s) => projectOf(s.cwd).toLowerCase().startsWith(wanted)) ??
    null
  );
}

/** Why the Ask bar can't answer, in words for its tooltip. */
export function assistantUnavailableReason(support: string): string {
  switch (support) {
    case "not-enabled":
      return "Turn on Apple Intelligence in System Settings to ask questions here";
    case "model-not-ready":
      return "Apple Intelligence is still downloading its model";
    case "device-not-eligible":
      return "This Mac doesn't support Apple Intelligence";
    case "os":
      return "Needs macOS 26 or later";
    default:
      return "Apple Intelligence isn't available";
  }
}

/** Tools that look things up animate as a search; the rest as work. */
const LOOKUP_TOOLS = new Set(["searchWeb", "listShortcuts", "readClipboard", "runShortcut"]);

export interface AssistantPhase {
  /** A question is in flight and nothing has come back yet. */
  sent: boolean;
  /** …and it's been long enough to call it thinking rather than connecting. */
  settled: boolean;
  /** The tool the model is running right now, if any. */
  tool: string | null;
  /** Words are arriving. */
  streaming: boolean;
  /** Something is waiting for the user's Run/Send. */
  proposing: boolean;
  /** The user is typing. */
  typing: boolean;
}

/**
 * The orb IS the assistant's status. In order of a request: connecting the
 * moment you send, solving while it thinks, searching or working while a tool
 * runs, composing as the words arrive; shaping while a proposal waits for you,
 * listening while you type and at rest (ready for you). Weaving is a Pro
 * state on Libraries.dev and breathing ("Thinking…") reads as a stalled
 * spinner, so neither is used.
 */
export function assistantOrbState(p: AssistantPhase): OrbState {
  if (p.tool) return LOOKUP_TOOLS.has(p.tool) ? "searching" : "working";
  if (p.streaming) return "composing";
  if (p.sent) return p.settled ? "solving" : "connecting";
  if (p.proposing) return "shaping";
  return "listening";
}

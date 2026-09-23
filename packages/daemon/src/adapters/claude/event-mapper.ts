import type { EventInput } from "@agent-island/shared";
import type { ClaudeHookPayload } from "./hook-payload";

const AGENT = "claude-code" as const;

/** Maps our URL slug back to the canonical hook name when the body omits it. */
const SLUG_TO_EVENT: Record<string, string> = {
  "session-start": "SessionStart",
  "pre-tool": "PreToolUse",
  "post-tool": "PostToolUse",
  "permission-request": "PermissionRequest",
  notification: "Notification",
  stop: "Stop",
  "session-end": "SessionEnd",
};

/**
 * Notification types that mean "the human needs to act". Idle prompts
 * ("Claude is waiting for your input") are NOT attention: the turn is over and
 * no further hook will ever fire, so an attention state would pin the island
 * open forever. Current CLIs omit `notification_type` entirely — for those,
 * only a permission ask (matched on the message) blocks on the human.
 */
const ATTENTION_NOTIFICATIONS = new Set(["permission_prompt"]);
const PERMISSION_MESSAGE = /\bpermission\b/i;

function truncate(s: string, max: number): string {
  const clean = s.replace(/\s+/g, " ").trim();
  return clean.length > max ? `${clean.slice(0, max - 1)}…` : clean;
}

function basename(p: string): string {
  return p.split("/").filter(Boolean).pop() ?? p;
}

/** A human "what it's doing right now" line, derived from the tool + its input. */
function describeAction(tool: string | undefined, input: Record<string, unknown> | undefined): string {
  const t = tool ?? "tool";
  const str = (k: string): string | undefined =>
    typeof input?.[k] === "string" ? (input[k] as string) : undefined;

  switch (t) {
    case "Bash": {
      const cmd = str("command");
      return cmd ? `Running ${truncate(cmd, 44)}` : "Running command";
    }
    case "Read": {
      const f = str("file_path");
      return f ? `Reading ${basename(f)}` : "Reading";
    }
    case "Edit":
    case "MultiEdit":
    case "Write": {
      const f = str("file_path");
      return f ? `Editing ${basename(f)}` : "Editing";
    }
    case "Grep": {
      const p = str("pattern");
      return p ? `Searching for ${truncate(p, 22)}` : "Searching";
    }
    case "Glob":
      return "Finding files";
    case "Task":
      return "Delegating to a subagent";
    case "WebFetch":
    case "WebSearch":
      return "Searching the web";
    case "TodoWrite":
      return "Updating the plan";
    default:
      return t;
  }
}

/** Prefer the payload's own event name; fall back to the URL slug. */
export function resolveHookEventName(slug: string, payload: ClaudeHookPayload): string {
  const fromBody = payload.hook_event_name?.trim();
  if (fromBody) return fromBody;
  return SLUG_TO_EVENT[slug] ?? slug;
}

/**
 * Pure mapper: one Claude hook payload -> one canonical EventInput, or null if
 * the event isn't something we surface. `fallbackCwd` fills events (notably
 * Notification) that omit cwd, using the session's already-known directory so
 * we never overwrite it with a placeholder.
 */
export function mapClaudeHook(
  eventName: string,
  payload: ClaudeHookPayload,
  fallbackCwd: string,
): EventInput | null {
  const cwd = payload.cwd?.trim() ? payload.cwd : fallbackCwd;
  const base = { agent: AGENT, session_id: payload.session_id, cwd };

  switch (eventName) {
    case "SessionStart":
      return {
        ...base,
        type: "session_started",
        title: `session ${payload.source ?? "started"}`,
        detail: prune({
          source: payload.source,
          model: payload.model,
          session_title: payload.session_title,
          _meta: prune({
            model: payload.model,
            permission_mode: payload.permission_mode,
          }),
        }),
        requires_action: false,
      };

    case "PreToolUse":
      // AskUserQuestion means Claude is blocked on the human — attention state.
      if (payload.tool_name === "AskUserQuestion") {
        return {
          ...base,
          type: "notification",
          title: "Claude asks a question",
          detail: prune({ tool_name: payload.tool_name, tool_input: payload.tool_input }),
          requires_action: true,
        };
      }
      return {
        ...base,
        type: "tool_use",
        title: describeAction(payload.tool_name, payload.tool_input),
        detail: prune({ tool_name: payload.tool_name, tool_input: payload.tool_input }),
        requires_action: false,
      };

    case "PostToolUse":
      return {
        ...base,
        type: "task_progress",
        title: "working…",
        detail: prune({ tool_name: payload.tool_name, tool_response: payload.tool_response }),
        requires_action: false,
      };

    case "PermissionRequest":
      if (payload.tool_name === "AskUserQuestion") {
        return {
          ...base,
          type: "notification",
          title: "Claude asks a question",
          detail: prune({ tool_name: payload.tool_name, tool_input: payload.tool_input }),
          requires_action: true,
        };
      }
      return {
        ...base,
        type: "permission_request",
        title: `approve ${payload.tool_name ?? "tool"}?`,
        detail: prune({ tool_name: payload.tool_name, tool_input: payload.tool_input }),
        requires_action: true,
      };

    case "Notification": {
      const needsAction = payload.notification_type
        ? ATTENTION_NOTIFICATIONS.has(payload.notification_type)
        : PERMISSION_MESSAGE.test(payload.message ?? "");
      return {
        ...base,
        type: "notification",
        title: payload.message ?? "notification",
        detail: prune({ notification_type: payload.notification_type }),
        requires_action: needsAction,
      };
    }

    case "Stop":
      return {
        ...base,
        type: "session_ended",
        title: "finished responding",
        detail: prune({ stop_reason: payload.stop_reason }),
        requires_action: false,
      };

    default:
      return null;
  }
}

/** Drop undefined values so `detail` stays clean. */
function prune(obj: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(obj)) {
    if (value !== undefined) out[key] = value;
  }
  return out;
}

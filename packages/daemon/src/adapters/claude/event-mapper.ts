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
};

/** Notification types that mean "the human needs to act". */
const ATTENTION_NOTIFICATIONS = new Set(["permission_prompt", "idle_prompt"]);

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
        }),
        requires_action: false,
      };

    case "PreToolUse":
      return {
        ...base,
        type: "tool_use",
        title: payload.tool_name ?? "tool call",
        detail: prune({ tool_name: payload.tool_name, tool_input: payload.tool_input }),
        requires_action: false,
      };

    case "PostToolUse":
      return {
        ...base,
        type: "task_progress",
        title: `${payload.tool_name ?? "tool"} finished`,
        detail: prune({ tool_name: payload.tool_name, tool_response: payload.tool_response }),
        requires_action: false,
      };

    case "PermissionRequest":
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
        : true;
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

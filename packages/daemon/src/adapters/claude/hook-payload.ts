import { z } from "zod";

/**
 * Tolerant schema for Claude Code hook payloads (v2.1.x). Every field except
 * `session_id` is optional and unknown fields pass through untouched — the CLI
 * ships weekly and field names have shifted across releases, so we parse
 * defensively rather than reject payloads we don't fully recognize.
 *
 * Field names verified against https://code.claude.com/docs/en/hooks
 */
export const ClaudeHookPayloadSchema = z
  .object({
    session_id: z.string(),
    hook_event_name: z.string().optional(),
    cwd: z.string().optional(),
    transcript_path: z.string().optional(),
    permission_mode: z.string().optional(),

    // SessionStart
    source: z.string().optional(),
    model: z.string().optional(),
    session_title: z.string().optional(),

    // PreToolUse / PostToolUse / PermissionRequest
    tool_name: z.string().optional(),
    tool_input: z.record(z.unknown()).optional(),
    tool_response: z.record(z.unknown()).optional(),

    // Notification
    message: z.string().optional(),
    notification_type: z.string().optional(),

    // Stop
    last_assistant_message: z.string().optional(),
    stop_reason: z.string().optional(),
  })
  .passthrough();

export type ClaudeHookPayload = z.infer<typeof ClaudeHookPayloadSchema>;

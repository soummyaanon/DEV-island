import { z } from "zod";
import { AgentKindSchema, type AgentKind } from "./agent-kind";

/** The canonical event vocabulary. Every observation maps onto one of these. */
export const EventTypeSchema = z.enum([
  "session_started",
  "task_progress",
  "tool_use",
  "permission_request",
  "notification",
  "session_ended",
  "error",
]);

export type EventType = z.infer<typeof EventTypeSchema>;

/**
 * What an adapter (or `curl`) sends to `POST /events`. Deliberately small:
 * the daemon mints `id` + `timestamp` and applies defaults, so senders stay dumb.
 */
export const EventInputSchema = z.object({
  agent: AgentKindSchema,
  session_id: z.string().min(1),
  cwd: z.string().min(1),
  type: EventTypeSchema,
  title: z.string(),
  detail: z.record(z.unknown()).optional(),
  requires_action: z.boolean().optional(),
});

export type EventInput = z.infer<typeof EventInputSchema>;

/**
 * The canonical event after normalization — the single source of truth that
 * flows across the wire and into the registry.
 */
export const AgentEventSchema = z.object({
  id: z.string().uuid(),
  agent: AgentKindSchema,
  session_id: z.string().min(1),
  cwd: z.string().min(1),
  timestamp: z.string().datetime(),
  type: EventTypeSchema,
  title: z.string(),
  detail: z.record(z.unknown()),
  requires_action: z.boolean(),
});

export type AgentEvent = z.infer<typeof AgentEventSchema>;

/** Stable registry key for a session across both agents. */
export function sessionKey(agent: AgentKind, sessionId: string): string {
  return `${agent}:${sessionId}`;
}

import { z } from "zod";
import { AgentKindSchema } from "./agent-kind";
import { EventTypeSchema } from "./agent-event";
import { SessionStateSchema } from "./session-state";

/**
 * The current state of one session — exactly what the UI renders per row.
 * Rebuilt incrementally by the session registry as events arrive; never the
 * raw event firehose.
 */
export const SessionSnapshotSchema = z.object({
  key: z.string(),
  agent: AgentKindSchema,
  session_id: z.string(),
  cwd: z.string(),
  state: SessionStateSchema,
  /** Latest human-readable activity line. */
  title: z.string(),
  requires_action: z.boolean(),
  started_at: z.string().datetime(),
  updated_at: z.string().datetime(),
  last_event_type: EventTypeSchema,
  event_count: z.number().int().nonnegative(),
});

export type SessionSnapshot = z.infer<typeof SessionSnapshotSchema>;

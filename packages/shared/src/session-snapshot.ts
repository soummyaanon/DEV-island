import { z } from "zod";
import { AgentKindSchema } from "./agent-kind";
import { EventTypeSchema } from "./agent-event";
import { SessionStateSchema } from "./session-state";
import { PendingApprovalSchema } from "./pending-approval";
import { PendingQuestionSchema } from "./pending-question";

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
  /**
   * Adapter-supplied metadata that persists across events — e.g. which terminal
   * the session runs in, for jump-to-terminal. Accumulated from event
   * `detail._meta`.
   */
  meta: z.record(z.unknown()),
  /** Set while the daemon is holding a permission hook open for this session. */
  pending_approval: PendingApprovalSchema.nullable(),
  /** Set while Claude is waiting on an AskUserQuestion answer in the terminal. */
  pending_question: PendingQuestionSchema.nullable(),
});

export type SessionSnapshot = z.infer<typeof SessionSnapshotSchema>;

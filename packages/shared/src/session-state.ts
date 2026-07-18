import { z } from "zod";

/**
 * Derived lifecycle state of one session — what the UI renders as a status dot.
 * The session registry owns all transitions; adapters never set this directly.
 */
export const SessionStateSchema = z.enum([
  "starting",
  "working",
  "waiting-for-approval",
  "idle",
  "done",
  "failed",
]);

export type SessionState = z.infer<typeof SessionStateSchema>;

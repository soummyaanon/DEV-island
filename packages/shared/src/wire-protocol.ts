import { z } from "zod";
import { AgentEventSchema } from "./agent-event";
import { SessionSnapshotSchema } from "./session-snapshot";

/** Full snapshot of all sessions, sent once when a subscriber connects. */
export const SnapshotMessageSchema = z.object({
  type: z.literal("snapshot"),
  sessions: z.array(SessionSnapshotSchema),
});

/** One ingested event plus the session state it produced. */
export const EventMessageSchema = z.object({
  type: z.literal("event"),
  event: AgentEventSchema,
  session: SessionSnapshotSchema,
});

/** Keep-alive heartbeat so idle connections don't get culled by proxies/OS. */
export const PingMessageSchema = z.object({
  type: z.literal("ping"),
  t: z.string().datetime(),
});

/** Everything the daemon pushes over `GET /stream`. */
export const WireMessageSchema = z.discriminatedUnion("type", [
  SnapshotMessageSchema,
  EventMessageSchema,
  PingMessageSchema,
]);

export type SnapshotMessage = z.infer<typeof SnapshotMessageSchema>;
export type EventMessage = z.infer<typeof EventMessageSchema>;
export type PingMessage = z.infer<typeof PingMessageSchema>;
export type WireMessage = z.infer<typeof WireMessageSchema>;

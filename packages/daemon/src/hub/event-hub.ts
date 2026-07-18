import { randomUUID } from "node:crypto";
import type {
  AgentEvent,
  EventInput,
  SessionSnapshot,
  WireMessage,
} from "@agent-island/shared";
import { SessionRegistry } from "./session-registry";
import { EventLog } from "./event-log";

/** A live consumer of the stream (one WebSocket connection). */
export type Subscriber = (message: WireMessage) => void;

/**
 * The heart of the daemon: normalize raw input into canonical events, fold them
 * into session state, retain them in the ring buffer, and fan out to subscribers.
 */
export class EventHub {
  private readonly registry = new SessionRegistry();
  private readonly log: EventLog;
  private readonly subscribers = new Set<Subscriber>();

  constructor(ringBufferSize: number) {
    this.log = new EventLog(ringBufferSize);
  }

  /** Validate-then-ingest happens at the route edge; this trusts its input. */
  ingest(input: EventInput): { event: AgentEvent; session: SessionSnapshot } {
    const event: AgentEvent = {
      id: randomUUID(),
      agent: input.agent,
      session_id: input.session_id,
      cwd: input.cwd,
      timestamp: new Date().toISOString(),
      type: input.type,
      title: input.title,
      detail: input.detail ?? {},
      requires_action: input.requires_action ?? false,
    };

    const session = this.registry.apply(event);
    this.log.push(event);
    this.broadcast({ type: "event", event, session });
    return { event, session };
  }

  /** Register a subscriber; immediately sends the current snapshot. */
  subscribe(fn: Subscriber): () => void {
    this.subscribers.add(fn);
    fn({ type: "snapshot", sessions: this.registry.list() });
    return () => {
      this.subscribers.delete(fn);
    };
  }

  /** Push a message to every subscriber; a throwing subscriber is dropped. */
  broadcast(message: WireMessage): void {
    for (const fn of this.subscribers) {
      try {
        fn(message);
      } catch {
        this.subscribers.delete(fn);
      }
    }
  }

  sessions(): SessionSnapshot[] {
    return this.registry.list();
  }

  recentEvents(limit?: number): AgentEvent[] {
    return this.log.recent(limit);
  }

  subscriberCount(): number {
    return this.subscribers.size;
  }
}

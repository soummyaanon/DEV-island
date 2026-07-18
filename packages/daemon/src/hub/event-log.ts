import type { AgentEvent } from "@agent-island/shared";

/**
 * Bounded ring buffer of recent events, for `GET /events` and debugging.
 * Oldest events are dropped once capacity is exceeded.
 */
export class EventLog {
  private readonly buffer: AgentEvent[] = [];

  constructor(private readonly capacity: number) {}

  push(event: AgentEvent): void {
    this.buffer.push(event);
    if (this.buffer.length > this.capacity) {
      this.buffer.shift();
    }
  }

  /** Most recent events (oldest → newest), optionally limited. */
  recent(limit?: number): AgentEvent[] {
    if (limit === undefined || limit >= this.buffer.length) {
      return [...this.buffer];
    }
    return this.buffer.slice(this.buffer.length - Math.max(0, limit));
  }

  get size(): number {
    return this.buffer.length;
  }
}

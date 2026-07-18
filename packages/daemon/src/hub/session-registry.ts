import {
  sessionKey,
  type AgentEvent,
  type AgentKind,
  type EventType,
  type PendingApproval,
  type PendingQuestion,
  type SessionSnapshot,
  type SessionState,
} from "@agent-island/shared";

/**
 * Pure state transition. The registry is the ONLY place that decides a
 * session's state; adapters merely translate observations into event types.
 */
export function nextState(
  _current: SessionState | undefined,
  type: EventType,
  requiresAction: boolean,
): SessionState {
  switch (type) {
    case "session_started":
      return "starting";
    case "task_progress":
    case "tool_use":
      return "working";
    case "permission_request":
      return "waiting-for-approval";
    case "notification":
      return requiresAction ? "waiting-for-approval" : "idle";
    case "session_ended":
      return "done";
    case "error":
      return "failed";
    default: {
      // Exhaustiveness guard: adding an EventType without handling it here is a
      // compile error rather than a silent wrong state.
      const _exhaustive: never = type;
      return _exhaustive;
    }
  }
}

/** In-memory map of current session state, keyed by `${agent}:${session_id}`. */
export class SessionRegistry {
  private readonly sessions = new Map<string, SessionSnapshot>();

  /** Fold one event into the session's snapshot and return the new snapshot. */
  apply(event: AgentEvent): SessionSnapshot {
    const key = sessionKey(event.agent, event.session_id);
    const existing = this.sessions.get(key);
    const state = nextState(existing?.state, event.type, event.requires_action);

    // Persist adapter metadata (e.g. terminal info) across events. Adapters put
    // it in `detail._meta`; once captured it sticks even when later events omit it.
    const incomingMeta =
      event.detail._meta && typeof event.detail._meta === "object"
        ? (event.detail._meta as Record<string, unknown>)
        : {};
    const meta = { ...(existing?.meta ?? {}), ...incomingMeta };

    const snapshot: SessionSnapshot = {
      key,
      agent: event.agent,
      session_id: event.session_id,
      cwd: event.cwd,
      state,
      title: event.title,
      requires_action: event.requires_action,
      started_at: existing?.started_at ?? event.timestamp,
      updated_at: event.timestamp,
      last_event_type: event.type,
      event_count: (existing?.event_count ?? 0) + 1,
      meta,
      pending_approval: existing?.pending_approval ?? null,
      pending_question: existing?.pending_question ?? null,
    };

    this.sessions.set(key, snapshot);
    return snapshot;
  }

  /** Set or clear the pending question on a session. */
  setPendingQuestion(
    agent: AgentKind,
    sessionId: string,
    question: PendingQuestion | null,
    nowIso: string,
  ): SessionSnapshot | undefined {
    const key = sessionKey(agent, sessionId);
    const existing = this.sessions.get(key);
    if (!existing) return undefined;
    if (existing.pending_question === null && question === null) return existing;
    const updated: SessionSnapshot = {
      ...existing,
      pending_question: question,
      updated_at: nowIso,
    };
    this.sessions.set(key, updated);
    return updated;
  }

  /** Set or clear the pending approval on a session (used by the approval hold). */
  setPendingApproval(
    agent: AgentKind,
    sessionId: string,
    approval: PendingApproval | null,
    nowIso: string,
  ): SessionSnapshot | undefined {
    const key = sessionKey(agent, sessionId);
    const existing = this.sessions.get(key);
    if (!existing) return undefined;
    const updated: SessionSnapshot = {
      ...existing,
      pending_approval: approval,
      updated_at: nowIso,
    };
    this.sessions.set(key, updated);
    return updated;
  }

  list(): SessionSnapshot[] {
    return [...this.sessions.values()];
  }

  get(key: string): SessionSnapshot | undefined {
    return this.sessions.get(key);
  }

  get size(): number {
    return this.sessions.size;
  }
}

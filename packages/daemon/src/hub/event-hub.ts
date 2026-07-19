import { randomUUID } from "node:crypto";
import {
  sessionKey,
  type AgentEvent,
  type AgentKind,
  type AgentUsage,
  type ApprovalDecision,
  type EventInput,
  type PendingApproval,
  type PendingQuestion,
  type SessionSnapshot,
  type WireMessage,
} from "@agent-island/shared";
import { SessionRegistry } from "./session-registry";
import { EventLog } from "./event-log";
import { ApprovalRegistry, HoldRegistry, type ApprovalOutcome } from "./approval-registry";

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
  private readonly approvals = new ApprovalRegistry();
  /** Held AskUserQuestion hooks: resolves with one option index per question. */
  private readonly questions = new HoldRegistry<number[]>();
  private usage: AgentUsage[] = [];

  constructor(
    ringBufferSize: number,
    private readonly approvalHoldMs: number,
  ) {
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

  /** Register a subscriber; immediately sends the current snapshot + usage. */
  subscribe(fn: Subscriber): () => void {
    this.subscribers.add(fn);
    fn({ type: "snapshot", sessions: this.registry.list() });
    if (this.usage.length > 0) fn({ type: "usage", usage: this.usage });
    return () => {
      this.subscribers.delete(fn);
    };
  }

  /** Update account usage/quota and fan it out. */
  setUsage(usage: AgentUsage[]): void {
    this.usage = usage;
    this.broadcast({ type: "usage", usage });
  }

  getUsage(): AgentUsage[] {
    return this.usage;
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

  /** Look up one session's current snapshot (e.g. to enrich a partial event). */
  getSession(agent: AgentKind, sessionId: string): SessionSnapshot | undefined {
    return this.registry.get(sessionKey(agent, sessionId));
  }

  /**
   * Route a tool call to the notch for approval and hold until the user decides
   * (or the hold times out). Sets pending_approval on the session while waiting.
   */
  async requestApproval(
    agent: AgentKind,
    sessionId: string,
    toolName: string,
    toolInput: Record<string, unknown>,
    plan?: string,
  ): Promise<ApprovalOutcome> {
    const id = randomUUID();
    const approval: PendingApproval = {
      id,
      tool_name: toolName,
      tool_input: toolInput,
      ...(plan ? { plan } : {}),
      created_at: new Date().toISOString(),
    };

    if (this.registry.setPendingApproval(agent, sessionId, approval, approval.created_at)) {
      this.broadcastSnapshot();
    }

    const outcome = await this.approvals.await(id, this.approvalHoldMs);

    if (this.registry.setPendingApproval(agent, sessionId, null, new Date().toISOString())) {
      this.broadcastSnapshot();
    }
    return outcome;
  }

  /** Resolve a held approval from the UI. Returns false if unknown/expired. */
  resolveApproval(id: string, decision: ApprovalDecision): boolean {
    return this.approvals.resolve(id, decision);
  }

  /**
   * Hold an AskUserQuestion hook open so the user can answer from the notch.
   * Resolves with one chosen option index per question, or "timeout" — then
   * Claude's own terminal picker takes over and the card stays for jump.
   */
  async requestQuestionAnswer(
    agent: AgentKind,
    sessionId: string,
    question: PendingQuestion,
  ): Promise<number[] | "timeout"> {
    this.setPendingQuestion(agent, sessionId, question);
    const outcome = await this.questions.await(question.id, this.approvalHoldMs);
    if (outcome !== "timeout") this.setPendingQuestion(agent, sessionId, null);
    return outcome;
  }

  /** Resolve a held question from the UI with one option index per question. */
  answerQuestion(id: string, options: number[]): boolean {
    return this.questions.resolve(id, options);
  }

  /** Surface (or clear) an AskUserQuestion the agent is waiting on. */
  setPendingQuestion(agent: AgentKind, sessionId: string, question: PendingQuestion | null): void {
    const updated = this.registry.setPendingQuestion(
      agent,
      sessionId,
      question,
      new Date().toISOString(),
    );
    if (updated) this.broadcastSnapshot();
  }

  private broadcastSnapshot(): void {
    this.broadcast({ type: "snapshot", sessions: this.registry.list() });
  }

  recentEvents(limit?: number): AgentEvent[] {
    return this.log.recent(limit);
  }

  subscriberCount(): number {
    return this.subscribers.size;
  }
}

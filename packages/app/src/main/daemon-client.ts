import WebSocket from "ws";
import type {
  AgentUsage,
  ApprovalDecision,
  SessionSnapshot,
  WireMessage,
} from "@agent-island/shared";

export type SessionsListener = (sessions: SessionSnapshot[], connected: boolean) => void;
export type UsageListener = (usage: AgentUsage[]) => void;

const STATE_ORDER: Record<string, number> = {
  "waiting-for-approval": 0,
  working: 1,
  starting: 2,
  idle: 3,
  failed: 4,
  done: 5,
};

/**
 * Main-process client for the daemon's WebSocket stream. Holds the authoritative
 * session map, auto-reconnects, and notifies listeners on every change. The
 * `snapshot` message on connect means we never need a separate GET /sessions.
 */
export class DaemonClient {
  private readonly wsUrl: string;
  private readonly httpBase: string;
  private ws: WebSocket | null = null;
  private sessions = new Map<string, SessionSnapshot>();
  private usage: AgentUsage[] = [];
  private readonly listeners = new Set<SessionsListener>();
  private readonly usageListeners = new Set<UsageListener>();
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private connected = false;
  private stopped = false;

  constructor(host = "127.0.0.1", port = 7433) {
    this.wsUrl = `ws://${host}:${port}/stream`;
    this.httpBase = `http://${host}:${port}`;
  }

  /** Resolve a held approval by POSTing the decision to the daemon. */
  async resolveApproval(id: string, decision: ApprovalDecision): Promise<void> {
    try {
      await fetch(`${this.httpBase}/approvals/${id}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ decision }),
      });
    } catch (err) {
      console.error("[approve] failed to send decision:", err);
    }
  }

  /**
   * Answer a held AskUserQuestion with one 0-based option index per question.
   * Returns false when the hold is gone (expired or unknown) — the caller
   * falls back to jump-to-terminal.
   */
  async answerQuestion(id: string, options: number[]): Promise<boolean> {
    try {
      const res = await fetch(`${this.httpBase}/questions/${id}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ options }),
      });
      return res.ok;
    } catch (err) {
      console.error("[answer] failed to send options:", err);
      return false;
    }
  }

  start(): void {
    this.connect();
  }

  isConnected(): boolean {
    return this.connected;
  }

  stop(): void {
    this.stopped = true;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.ws?.close();
  }

  onSessions(fn: SessionsListener): () => void {
    this.listeners.add(fn);
    fn(this.list(), this.connected);
    return () => {
      this.listeners.delete(fn);
    };
  }

  onUsage(fn: UsageListener): () => void {
    this.usageListeners.add(fn);
    fn(this.usage);
    return () => {
      this.usageListeners.delete(fn);
    };
  }

  getUsage(): AgentUsage[] {
    return this.usage;
  }

  /** Attention first, then most-active, then most-recently updated. */
  list(): SessionSnapshot[] {
    return [...this.sessions.values()].sort((a, b) => {
      const byState = (STATE_ORDER[a.state] ?? 9) - (STATE_ORDER[b.state] ?? 9);
      if (byState !== 0) return byState;
      return b.updated_at.localeCompare(a.updated_at);
    });
  }

  private connect(): void {
    if (this.stopped) return;
    const ws = new WebSocket(this.wsUrl);
    this.ws = ws;

    ws.on("open", () => {
      this.connected = true;
      this.emit();
    });
    ws.on("message", (data) => this.handle(data.toString()));
    ws.on("close", () => {
      this.connected = false;
      this.emit();
      this.scheduleReconnect();
    });
    ws.on("error", () => {
      /* a 'close' always follows; reconnect is handled there */
    });
  }

  private handle(raw: string): void {
    let msg: WireMessage;
    try {
      msg = JSON.parse(raw) as WireMessage;
    } catch {
      return;
    }
    if (msg.type === "snapshot") {
      this.sessions = new Map(msg.sessions.map((s) => [s.key, s]));
      this.emit();
    } else if (msg.type === "event") {
      this.sessions.set(msg.session.key, msg.session);
      this.emit();
    } else if (msg.type === "usage") {
      this.usage = msg.usage;
      for (const fn of this.usageListeners) fn(this.usage);
    }
    // 'ping' is ignored
  }

  private scheduleReconnect(): void {
    if (this.stopped || this.reconnectTimer) return;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, 1500);
  }

  private emit(): void {
    // After stop() the app is quitting: windows may already be destroyed, so
    // listeners must never fire again (the ws 'close' event arrives late).
    if (this.stopped) return;
    const list = this.list();
    for (const fn of this.listeners) fn(list, this.connected);
  }
}

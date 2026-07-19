import type { ApprovalDecision } from "@agent-island/shared";

/** The outcome of a held approval: the user's choice, or a timeout fallback. */
export type ApprovalOutcome = ApprovalDecision | "timeout";

interface Pending<T> {
  resolve: (outcome: T | "timeout") => void;
  timer: ReturnType<typeof setTimeout>;
}

/**
 * Tracks in-flight holds. Each corresponds to one agent hook the daemon is
 * holding open; it resolves when the user decides in the notch, or after a
 * timeout (so a held hook never hangs the agent forever).
 */
export class HoldRegistry<T> {
  private readonly pending = new Map<string, Pending<T>>();

  /** Await a decision for `id`; resolves with the choice or "timeout". */
  await(id: string, timeoutMs: number): Promise<T | "timeout"> {
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        resolve("timeout");
      }, timeoutMs);
      this.pending.set(id, { resolve, timer });
    });
  }

  /** Resolve a held id from the UI. Returns false if unknown/expired. */
  resolve(id: string, decision: T): boolean {
    const p = this.pending.get(id);
    if (!p) return false;
    clearTimeout(p.timer);
    this.pending.delete(id);
    p.resolve(decision);
    return true;
  }

  has(id: string): boolean {
    return this.pending.has(id);
  }
}

/** Held permission approvals: resolves with allow/deny. */
export class ApprovalRegistry extends HoldRegistry<ApprovalDecision> {}

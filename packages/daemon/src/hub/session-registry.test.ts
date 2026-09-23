import { describe, expect, it } from "vitest";
import type { AgentEvent } from "@agent-island/shared";
import { SessionRegistry } from "./session-registry";

const NOW = Date.parse("2026-09-24T12:00:00.000Z");
const ago = (min: number) => new Date(NOW - min * 60_000).toISOString();

function event(over: Partial<AgentEvent> & { pid?: string }): AgentEvent {
  const { pid, ...rest } = over;
  return {
    id: "e",
    agent: "claude-code",
    session_id: "s1",
    cwd: "/Users/me/web",
    timestamp: ago(1),
    type: "tool_use",
    title: "Editing",
    detail: pid ? { _meta: { pid } } : {},
    requires_action: false,
    ...rest,
  };
}

describe("SessionRegistry.prune", () => {
  it("drops a Claude session whose process exited, keeps one that's alive", () => {
    const r = new SessionRegistry();
    r.apply(event({ session_id: "dead", pid: "111" }));
    r.apply(event({ session_id: "live", pid: "222" }));
    const removed = r.prune((pid) => pid === 222, NOW, 30 * 60_000);
    expect(removed).toEqual(["claude-code:dead"]);
    expect(r.list().map((s) => s.session_id)).toEqual(["live"]);
  });

  it("a live process keeps even a long-quiet session (you left claude open)", () => {
    const r = new SessionRegistry();
    r.apply(event({ pid: "222", type: "session_ended", timestamp: ago(600) }));
    expect(r.prune(() => true, NOW, 30 * 60_000)).toEqual([]);
  });

  it("without a process, drops finished sessions after the stale window but never working ones", () => {
    const r = new SessionRegistry();
    r.apply(event({ session_id: "old-done", type: "session_ended", timestamp: ago(45) }));
    r.apply(event({ session_id: "new-done", type: "session_ended", timestamp: ago(5) }));
    r.apply(event({ session_id: "old-working", type: "tool_use", timestamp: ago(45) }));
    expect(r.prune(() => false, NOW, 30 * 60_000)).toEqual(["claude-code:old-done"]);
  });

  it("never trusts a Cursor pid (its hook runner is short-lived)", () => {
    const r = new SessionRegistry();
    r.apply(event({ agent: "cursor", pid: "333", timestamp: ago(2) }));
    expect(r.prune(() => false, NOW, 30 * 60_000)).toEqual([]);
  });

  it("keeps a session that's holding an approval", () => {
    const r = new SessionRegistry();
    r.apply(event({ session_id: "held", pid: "111" }));
    r.setPendingApproval(
      "claude-code",
      "held",
      { id: "a", tool_name: "Bash", tool_input: {}, created_at: ago(0) } as never,
      ago(0),
    );
    expect(r.prune(() => false, NOW, 30 * 60_000)).toEqual([]);
  });

  it("remove() forgets a session", () => {
    const r = new SessionRegistry();
    r.apply(event({}));
    expect(r.remove("claude-code:s1")).toBe(true);
    expect(r.list()).toEqual([]);
  });
});

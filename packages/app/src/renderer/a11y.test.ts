import { describe, expect, it } from "vitest";
import type { SessionSnapshot } from "@agent-island/shared";
import { describeSession, summarizeTransitions } from "./a11y";

const counts = (over: Partial<Parameters<typeof summarizeTransitions>[0]> = {}) => ({
  done: 0,
  failed: 0,
  questions: 0,
  actions: 0,
  only: "",
  ...over,
});

describe("summarizeTransitions", () => {
  it("says nothing when nothing changed", () => {
    expect(summarizeTransitions(counts())).toBeNull();
  });

  it("names the project when a single session transitioned", () => {
    expect(summarizeTransitions(counts({ done: 1, only: "agent-island" }))).toEqual({
      message: "agent-island finished",
      urgency: "polite",
    });
  });

  it("counts instead of naming when several transitioned", () => {
    expect(summarizeTransitions(counts({ done: 3, only: "agent-island" }))).toEqual({
      message: "3 sessions finished",
      urgency: "polite",
    });
  });

  it("interrupts for a question — a blocked agent can't wait for a speech gap", () => {
    const result = summarizeTransitions(counts({ questions: 1, only: "api" }));
    expect(result?.urgency).toBe("assertive");
    expect(result?.message).toBe("api is asking a question");
  });

  it("stays polite for finished work even in bulk", () => {
    expect(summarizeTransitions(counts({ done: 2, failed: 1 }))?.urgency).toBe("polite");
  });

  it("leads with what blocks the user, not what finished", () => {
    const result = summarizeTransitions(counts({ done: 1, actions: 1, questions: 1 }));
    expect(result?.message.startsWith("1 session is asking a question")).toBe(true);
    expect(result?.urgency).toBe("assertive");
  });

  it("falls back to a count when the single session has no project name", () => {
    expect(summarizeTransitions(counts({ failed: 1, only: "" }))?.message).toBe("1 session failed");
  });
});

const session = (over: Partial<SessionSnapshot> = {}): SessionSnapshot =>
  ({
    key: "claude-code:s1",
    agent: "claude-code",
    session_id: "s1",
    cwd: "/Users/me/agent-island",
    state: "working",
    title: "Editing index.ts",
    requires_action: false,
    started_at: "2026-07-25T10:00:00.000Z",
    updated_at: "2026-07-25T10:00:01.000Z",
    last_event_type: "tool_use",
    event_count: 2,
    meta: {},
    pending_approval: null,
    pending_question: null,
    ...over,
  }) as SessionSnapshot;

describe("describeSession", () => {
  it("front-loads project and state, then detail", () => {
    expect(describeSession(session(), "5s")).toBe(
      "agent-island, working, Editing index.ts, 5s",
    );
  });

  it("translates the wire state into something speakable", () => {
    expect(describeSession(session({ state: "waiting-for-approval" }), "1m")).toContain(
      "waiting for you",
    );
  });

  it("omits an empty activity rather than leaving a double comma", () => {
    expect(describeSession(session({ title: "" }), "2m")).toBe("agent-island, working, 2m");
  });
});

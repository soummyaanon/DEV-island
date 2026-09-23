import { describe, expect, it } from "vitest";
import type { SessionSnapshot } from "@agent-island/shared";
import { SLEEP_AFTER_MS, avatarState, orbState, sessionSeed } from "./agent-avatar";

const NOW = Date.parse("2026-09-23T12:00:00.000Z");

const session = (over: Partial<SessionSnapshot> = {}): SessionSnapshot => ({
  key: "claude-code:s1",
  agent: "claude-code",
  session_id: "s1",
  cwd: "/Users/me/web",
  state: "working",
  title: "Editing index.ts",
  requires_action: false,
  started_at: "2026-09-23T11:00:00.000Z",
  updated_at: "2026-09-23T11:59:00.000Z",
  last_event_type: "tool_use",
  event_count: 3,
  meta: {},
  pending_approval: null,
  pending_question: null,
  ...over,
});

describe("avatarState", () => {
  it("hops while working or starting", () => {
    expect(avatarState(session({ state: "working" }), NOW)).toBe("working");
    expect(avatarState(session({ state: "starting" }), NOW)).toBe("working");
  });

  it("stays awake while it needs you, however long it's been", () => {
    const old = new Date(NOW - SLEEP_AFTER_MS * 3).toISOString();
    expect(avatarState(session({ state: "waiting-for-approval", updated_at: old }), NOW)).toBe("default");
  });

  it("falls asleep once a finished session has been quiet a while", () => {
    expect(avatarState(session({ state: "done" }), NOW)).toBe("default");
    const old = new Date(NOW - SLEEP_AFTER_MS - 1).toISOString();
    expect(avatarState(session({ state: "done", updated_at: old }), NOW)).toBe("sleeping");
    expect(avatarState(session({ state: "idle", updated_at: old }), NOW)).toBe("sleeping");
  });
});

describe("orbState", () => {
  it("reads the activity line", () => {
    expect(orbState(session({ title: "Searching for useEffect" }))).toBe("searching");
    expect(orbState(session({ title: "Grep TODO" }))).toBe("searching");
    expect(orbState(session({ title: "Editing index.ts" }))).toBe("composing");
    expect(orbState(session({ title: "Reading package.json" }))).toBe("searching");
    expect(orbState(session({ title: "Running pnpm test" }))).toBe("working");
    expect(orbState(session({ title: "Thinking" }))).toBe("solving");
  });

  it("lets the lifecycle win over the text", () => {
    expect(orbState(session({ state: "starting", title: "Editing" }))).toBe("connecting");
    expect(orbState(session({ state: "waiting-for-approval", title: "Run command" }))).toBe("listening");
  });

  it("breathes when nothing matches", () => {
    expect(orbState(session({ title: "…" }))).toBe("breathing");
  });
});

describe("sessionSeed", () => {
  it("is stable and in 0–1", () => {
    const a = sessionSeed("claude-code:s1");
    expect(a).toBe(sessionSeed("claude-code:s1"));
    expect(a).toBeGreaterThanOrEqual(0);
    expect(a).toBeLessThanOrEqual(1);
    expect(sessionSeed("claude-code:s2")).not.toBe(a);
  });
});

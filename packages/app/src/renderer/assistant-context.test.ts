import { describe, expect, it } from "vitest";
import type { SessionSnapshot } from "@agent-island/shared";
import { assistantContext, assistantOrbState, findSessionByProject } from "./assistant-context";

const NOW = Date.parse("2026-09-23T12:00:00.000Z");
const session = (cwd: string, over: Partial<SessionSnapshot> = {}): SessionSnapshot => ({
  key: `claude-code:${cwd}`,
  agent: "claude-code",
  session_id: cwd,
  cwd,
  state: "working",
  title: "Editing index.ts",
  requires_action: false,
  started_at: "2026-09-23T11:00:00.000Z",
  updated_at: "2026-09-23T11:58:00.000Z",
  last_event_type: "tool_use",
  event_count: 1,
  meta: {},
  pending_approval: null,
  pending_question: null,
  ...over,
});

describe("assistantContext", () => {
  it("adds nothing when no agents run, so general questions go through as asked", () => {
    expect(assistantContext([], NOW)).toBe("");
  });

  it("is one line per session with project, agent, state and activity", () => {
    expect(assistantContext([session("/Users/me/website")], NOW)).toBe(
      '- website (Claude Code): working, "Editing index.ts", updated 2 min ago',
    );
  });
});

describe("findSessionByProject", () => {
  const all = [session("/Users/me/website"), session("/Users/me/api")];
  it("matches the folder name exactly, then by prefix, ignoring case", () => {
    expect(findSessionByProject(all, "API")?.cwd).toBe("/Users/me/api");
    expect(findSessionByProject(all, "web")?.cwd).toBe("/Users/me/website");
    expect(findSessionByProject(all, "docs")).toBeNull();
    expect(findSessionByProject(all, " ")).toBeNull();
  });
});

describe("assistantOrbState", () => {
  const rest = { sent: false, settled: false, tool: null, streaming: false, proposing: false, typing: false };
  it("walks a request: connecting → solving → tool → composing", () => {
    expect(assistantOrbState({ ...rest, sent: true })).toBe("connecting");
    expect(assistantOrbState({ ...rest, sent: true, settled: true })).toBe("solving");
    expect(assistantOrbState({ ...rest, sent: true, tool: "searchWeb" })).toBe("searching");
    expect(assistantOrbState({ ...rest, sent: true, tool: "openApp" })).toBe("working");
    expect(assistantOrbState({ ...rest, streaming: true })).toBe("composing");
  });
  it("at rest: shaping for a pending proposal, listening while typing, else breathing", () => {
    expect(assistantOrbState({ ...rest, proposing: true, typing: true })).toBe("shaping");
    expect(assistantOrbState({ ...rest, typing: true })).toBe("listening");
    expect(assistantOrbState(rest)).toBe("breathing");
  });
});

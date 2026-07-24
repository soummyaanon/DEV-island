import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { SessionSnapshot } from "@agent-island/shared";
import { SessionRow } from "./SessionRow";

const session = (over: Partial<SessionSnapshot> = {}): SessionSnapshot => ({
  key: "claude-code:session-1",
  agent: "claude-code",
  session_id: "session-1",
  cwd: "/Users/me/project",
  state: "working",
  title: "Editing index.ts",
  requires_action: false,
  started_at: "2026-07-19T10:00:00.000Z",
  updated_at: "2026-07-19T10:00:01.000Z",
  last_event_type: "tool_use",
  event_count: 2,
  meta: {
    model: "claude-opus-4-6",
    permission_mode: "plan",
    app_bundle_id: "com.todesktop.230313mzl4w4u92",
  },
  pending_approval: null,
  pending_question: null,
  ...over,
});

describe("SessionRow", () => {
  it("shows the live model, host app, and permission mode", () => {
    const html = renderToStaticMarkup(
      <SessionRow
        session={session()}
        now={Date.parse("2026-07-19T10:00:05.000Z")}
        onJump={() => {}}
      />,
    );

    expect(html).toContain("claude-opus-4-6");
    expect(html).toContain("cursor");
    expect(html).toContain("plan");
  });

  it("is a real button — it used to be a clickable <li>, unreachable by keyboard", () => {
    const html = renderToStaticMarkup(
      <SessionRow
        session={session()}
        now={Date.parse("2026-07-19T10:00:05.000Z")}
        onJump={() => {}}
      />,
    );

    expect(html).toContain('<button type="button"');
    // The visual spans are hidden from the tree: the composed label reads far
    // better than four fragments announced in DOM order.
    expect(html).toContain('aria-hidden="true"');
  });

  it("carries a spoken label with project, state, activity, and elapsed", () => {
    const html = renderToStaticMarkup(
      <SessionRow
        session={session({ state: "waiting-for-approval" })}
        now={Date.parse("2026-07-19T10:00:05.000Z")}
        onJump={() => {}}
      />,
    );

    expect(html).toContain('aria-label="project, waiting for you, Editing index.ts, 5s"');
  });
});

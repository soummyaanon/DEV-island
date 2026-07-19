import { beforeEach, describe, expect, it, vi } from "vitest";
import type { SessionSnapshot } from "@agent-island/shared";

const execFile = vi.fn((_file, _args, callback) => callback?.(null));

vi.mock("node:child_process", () => ({ execFile }));
vi.mock("electron", () => ({
  systemPreferences: {
    isTrustedAccessibilityClient: () => true,
  },
}));

const session: SessionSnapshot = {
  key: "claude-code:session-1",
  agent: "claude-code",
  session_id: "session-1",
  cwd: "/Users/me/project",
  state: "waiting-for-approval",
  title: "Claude asks a question",
  requires_action: true,
  started_at: "2026-07-19T10:00:00.000Z",
  updated_at: "2026-07-19T10:00:01.000Z",
  last_event_type: "notification",
  event_count: 2,
  meta: { app_bundle_id: "com.todesktop.230313mzl4w4u92" },
  pending_approval: null,
  pending_question: {
    id: "question-1",
    question: "Deploy where?",
    options: ["Production", "Staging"],
    created_at: "2026-07-19T10:00:01.000Z",
  },
};

describe("answerInTerminal", () => {
  beforeEach(() => execFile.mockClear());

  it("navigates to the selected Claude option and confirms it with Enter", async () => {
    const { answerInTerminal } = await import("./jump-back");
    answerInTerminal(session, "2");

    const scripts = execFile.mock.calls.map((call) => String(call[1]?.[1] ?? ""));
    expect(scripts[0]).toContain('tell application id "com.todesktop.230313mzl4w4u92" to activate');
    expect(scripts[1]).toContain("key code 125");
    expect(scripts[1]).toContain("key code 36");
    expect(scripts[1]).not.toContain('keystroke "2"');
  });
});

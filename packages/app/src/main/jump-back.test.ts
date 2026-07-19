import { beforeEach, describe, expect, it, vi } from "vitest";
import type { SessionSnapshot } from "@agent-island/shared";

const execFile = vi.fn((_file, _args, callback) => callback?.(null));

vi.mock("node:child_process", () => ({ execFile }));
// Keep diagnostics out of the real ~/.agent-island/app.log during tests.
vi.mock("node:fs", () => ({ appendFile: vi.fn() }));
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
    questions: [{ question: "Deploy where?", options: ["Production", "Staging"] }],
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

describe("jumpToTerminal with TERM_PROGRAM=vscode and no bundle id", () => {
  // VS Code and Cursor's terminals are indistinguishable by TERM_PROGRAM; when
  // the session's own bundle id never reached the daemon, jump must pick the
  // editor that is actually running instead of blindly launching VS Code.
  const vscodeSession: SessionSnapshot = {
    ...session,
    meta: { term_program: "vscode" },
  };

  function mockRunningApps(running: Record<string, boolean>): void {
    execFile.mockReset();
    execFile.mockImplementation((file, args, callback) => {
      if (file === "lsappinfo") {
        const bundleId = String(args?.[1] ?? "").replace("bundleid=", "");
        callback?.(null, running[bundleId] ? `ASN:0x0-0x1-"app":` : "", "");
        return;
      }
      callback?.(null, "", "");
    });
  }

  function osascripts(): string[] {
    return execFile.mock.calls
      .filter((call) => call[0] === "osascript")
      .map((call) => String(call[1]?.[1] ?? ""));
  }

  it("activates Cursor when only Cursor is running", async () => {
    mockRunningApps({ "com.todesktop.230313mzl4w4u92": true });
    const { jumpToTerminal } = await import("./jump-back");
    jumpToTerminal(vscodeSession);

    await vi.waitFor(() => {
      expect(osascripts()[0]).toContain(
        'tell application id "com.todesktop.230313mzl4w4u92" to activate',
      );
    });
  });

  it("still prefers VS Code when it is running", async () => {
    mockRunningApps({ "com.microsoft.VSCode": true, "com.todesktop.230313mzl4w4u92": true });
    const { jumpToTerminal } = await import("./jump-back");
    jumpToTerminal(vscodeSession);

    await vi.waitFor(() => {
      expect(osascripts()[0]).toContain('tell application id "com.microsoft.VSCode" to activate');
    });
  });

  it("falls back to VS Code when neither is detectable", async () => {
    mockRunningApps({});
    const { jumpToTerminal } = await import("./jump-back");
    jumpToTerminal(vscodeSession);

    await vi.waitFor(() => {
      expect(osascripts()[0]).toContain('tell application id "com.microsoft.VSCode" to activate');
    });
  });
});

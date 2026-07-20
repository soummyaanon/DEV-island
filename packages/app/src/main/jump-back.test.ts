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
  shell: { openExternal: vi.fn() },
}));

const CURSOR = "com.todesktop.230313mzl4w4u92";
const VSCODE = "com.microsoft.VSCode";

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
  meta: { app_bundle_id: CURSOR },
  pending_approval: null,
  pending_question: {
    id: "question-1",
    questions: [{ question: "Deploy where?", options: ["Production", "Staging"] }],
    created_at: "2026-07-19T10:00:01.000Z",
  },
};

/** The `open -b <bundle> <folder>` invocations, as arg arrays. */
function openCalls(): unknown[][] {
  return execFile.mock.calls.filter((call) => call[0] === "open").map((call) => call[1]);
}
function osascripts(): string[] {
  return execFile.mock.calls
    .filter((call) => call[0] === "osascript")
    .map((call) => String(call[1]?.[1] ?? ""));
}

describe("answerInTerminal", () => {
  beforeEach(() => {
    execFile.mockReset();
    execFile.mockImplementation((_file, _args, callback) => callback?.(null, "", ""));
  });

  it("focuses the project's editor window, then navigates + confirms with Enter", async () => {
    const { answerInTerminal } = await import("./jump-back");
    answerInTerminal(session, "2");

    // Jump focuses the exact project window via `open -b` (no Accessibility needed).
    expect(openCalls()[0]).toEqual(["-b", CURSOR, "/Users/me/project"]);
    // Then arrow-key navigation + Enter — never a number key.
    const keys = osascripts()[0] ?? "";
    expect(keys).toContain("key code 125");
    expect(keys).toContain("key code 36");
    expect(keys).not.toContain('keystroke "2"');
  });
});

describe("jumpToTerminal focuses the specific project window", () => {
  beforeEach(() => {
    execFile.mockReset();
    execFile.mockImplementation((_file, _args, callback) => callback?.(null, "", ""));
  });

  // Two projects in the same editor can only be told apart by their folder;
  // `open -b <bundle> <cwd>` brings THIS project's window forward.
  it("opens the project folder in Cursor for a Cursor session", async () => {
    const cursorSession: SessionSnapshot = {
      ...session,
      agent: "cursor",
      cwd: "/Users/me/Apex-HealthIQ",
      meta: {},
    };
    const { jumpToTerminal } = await import("./jump-back");
    jumpToTerminal(cursorSession);
    expect(openCalls()[0]).toEqual(["-b", CURSOR, "/Users/me/Apex-HealthIQ"]);
  });

  it("opens the project folder for a Claude session hosted in Cursor", async () => {
    const hosted: SessionSnapshot = {
      ...session,
      cwd: "/Users/me/DEV island",
      meta: { app_bundle_id: CURSOR },
    };
    const { jumpToTerminal } = await import("./jump-back");
    jumpToTerminal(hosted);
    expect(openCalls()[0]).toEqual(["-b", CURSOR, "/Users/me/DEV island"]);
  });
});

describe("jumpToTerminal with TERM_PROGRAM=vscode and no bundle id", () => {
  // VS Code and Cursor's terminals are indistinguishable by TERM_PROGRAM; when
  // the session's own bundle id never reached the daemon, jump must open the
  // project in the editor that is actually running instead of blindly using VS Code.
  const vscodeSession: SessionSnapshot = {
    ...session,
    cwd: "/Users/me/project",
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

  it("opens the project in Cursor when only Cursor is running", async () => {
    mockRunningApps({ [CURSOR]: true });
    const { jumpToTerminal } = await import("./jump-back");
    jumpToTerminal(vscodeSession);
    await vi.waitFor(() => {
      expect(openCalls()[0]).toEqual(["-b", CURSOR, "/Users/me/project"]);
    });
  });

  it("prefers VS Code when it is running", async () => {
    mockRunningApps({ [VSCODE]: true, [CURSOR]: true });
    const { jumpToTerminal } = await import("./jump-back");
    jumpToTerminal(vscodeSession);
    await vi.waitFor(() => {
      expect(openCalls()[0]).toEqual(["-b", VSCODE, "/Users/me/project"]);
    });
  });

  it("falls back to VS Code when neither is detectable", async () => {
    mockRunningApps({});
    const { jumpToTerminal } = await import("./jump-back");
    jumpToTerminal(vscodeSession);
    await vi.waitFor(() => {
      expect(openCalls()[0]).toEqual(["-b", VSCODE, "/Users/me/project"]);
    });
  });
});

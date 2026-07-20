import { execFile } from "node:child_process";
import { appendFile } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { systemPreferences } from "electron";
import type { SessionSnapshot } from "@agent-island/shared";
import { requestAccessibility } from "./accessibility";

/** Open the Accessibility pane at most once per run so a blocked send guides,
 *  not spams. macOS only shows the grant dialog on the first request anyway. */
let accessibilityPromptShown = false;
function requestAccessibilityOnce(): void {
  if (accessibilityPromptShown) return;
  accessibilityPromptShown = true;
  requestAccessibility();
}

/**
 * Menu-bar apps have no visible console; mirror jump diagnostics to a file so
 * "clicked and nothing happened" is debuggable after the fact.
 */
function logJump(message: string): void {
  console.log(`[jump] ${message}`);
  appendFile(
    join(homedir(), ".agent-island", "app.log"),
    `${new Date().toISOString()} [jump] ${message}\n`,
    () => {},
  );
}

/** TERM_PROGRAM value -> macOS bundle id, for activate-app fallback. */
const BUNDLE_IDS: Record<string, string> = {
  "iTerm.app": "com.googlecode.iterm2",
  Apple_Terminal: "com.apple.Terminal",
  WarpTerminal: "dev.warp.Warp-Stable",
  ghostty: "com.mitchellh.ghostty",
  WezTerm: "com.github.wez.wezterm",
  vscode: "com.microsoft.VSCode",
  Cursor: "com.todesktop.230313mzl4w4u92",
};

const SAFE_ID = /^[\w:.-]+$/;
const SAFE_TERM = /^[\w.]+$/;

/** Editors that host multiple projects in separate windows — activating the app
 *  alone lands on whichever window is frontmost, so we must focus the project's
 *  own window instead. */
const EDITOR_BUNDLES = new Set([BUNDLE_IDS.vscode, BUNDLE_IDS.Cursor]);

function osascript(script: string): void {
  execFile("osascript", ["-e", script], (err) => {
    if (err) logJump(`osascript failed: ${err.message}`);
  });
}

/**
 * Focus a specific project's editor window. `open -b <bundle> <folder>` tells
 * VS Code / Cursor to bring the window already showing that folder to the front
 * (or open it if it isn't) — precise per project, and, crucially, it needs NO
 * Accessibility grant (the AX-based approach silently fell back to a plain
 * activate whenever the grant was missing, which is what made two projects in
 * the same editor jump to the same window). Falls back to activate on error.
 */
function raiseEditorWindow(bundleId: string, cwd: string): void {
  if (!cwd) {
    osascript(`tell application id "${bundleId}" to activate`);
    return;
  }
  logJump(`open ${bundleId} at "${cwd}"`);
  execFile("open", ["-b", bundleId, cwd], (err) => {
    if (err) {
      logJump(`open failed: ${err.message} — activating instead`);
      osascript(`tell application id "${bundleId}" to activate`);
    }
  });
}

function metaString(session: SessionSnapshot, key: string): string | undefined {
  const v = session.meta?.[key];
  return typeof v === "string" && v ? v : undefined;
}

/** Bring the session's terminal to front — precise tab for iTerm2, app for the rest. */
export function jumpToTerminal(session: SessionSnapshot): void {
  const term = metaString(session, "term_program") ?? "";
  const itermId = metaString(session, "iterm_session_id");
  const hostBundleId = metaString(session, "app_bundle_id");

  if (term === "iTerm.app" && itermId) {
    jumpITerm(itermId);
    return;
  }

  // The host app's own bundle id (from __CFBundleIdentifier) beats any
  // TERM_PROGRAM mapping: Claude in Cursor's terminal reports
  // TERM_PROGRAM=vscode, but this points at Cursor itself.
  if (hostBundleId && SAFE_ID.test(hostBundleId)) {
    // For a multi-window editor, raise this project's window, not just the app.
    if (EDITOR_BUNDLES.has(hostBundleId)) raiseEditorWindow(hostBundleId, session.cwd);
    else osascript(`tell application id "${hostBundleId}" to activate`);
    return;
  }

  // Cursor sessions come from the IDE's hooks (no terminal identity): jump means
  // bringing Cursor's window for THIS project — not just Cursor — to the front.
  if (!term && session.agent === "cursor") {
    raiseEditorWindow(BUNDLE_IDS.Cursor, session.cwd);
    return;
  }

  // VS Code and Cursor terminals are indistinguishable by TERM_PROGRAM; if the
  // session's bundle id never reached the daemon, raise this project's window in
  // whichever editor is actually running rather than blindly launching VS Code.
  if (term === "vscode") {
    jumpVSCodeFamily(session.cwd);
    return;
  }

  const bundle = BUNDLE_IDS[term];
  if (bundle) {
    osascript(`tell application id "${bundle}" to activate`);
  } else if (SAFE_TERM.test(term)) {
    osascript(`tell application "${term}" to activate`);
  } else {
    console.warn(`[jump] no known terminal for session ${session.key} (term="${term}")`);
  }
}

/**
 * Best-effort remote answer: Claude's question UI is navigated with arrow keys
 * and confirmed with Enter (it does not accept number keys). Bring the owning
 * terminal forward first, then use Accessibility-backed System Events.
 */
export function answerInTerminal(session: SessionSnapshot, digit: string): void {
  logJump(`answer ${digit} for ${session.key} (term=${metaString(session, "term_program") ?? ""})`);
  jumpToTerminal(session);

  // Without Accessibility, the jump still puts the user at the right prompt.
  if (!systemPreferences.isTrustedAccessibilityClient(false)) {
    logJump("Accessibility not granted — jumped without typing the answer");
    return;
  }
  if (/^[1-9]$/.test(digit)) {
    const downPresses = Number(digit) - 1;
    execFile(
      "osascript",
      [
        "-e",
        `
      delay 0.4
      tell application "System Events"
        repeat ${downPresses} times
          key code 125
        end repeat
        key code 36
      end tell`,
      ],
      (err) => {
        logJump(err ? `keystrokes failed: ${err.message}` : "keystrokes sent");
      },
    );
  }
}

/** Why a prompt did (or didn't) reach the terminal — so the notch can react. */
export type SendPromptResult = "sent" | "no-accessibility" | "empty";

/**
 * Type a free-form prompt into the session's terminal and press Enter. Brings
 * the owning terminal forward first, then uses Accessibility-backed System
 * Events — the same path as {@link answerInTerminal}. Single-line only; newlines
 * are flattened to spaces so a stray Enter never submits half a prompt.
 * Returns "no-accessibility" when the keystroke was dropped for lack of
 * permission, so the caller can surface a hint instead of failing silently.
 */
export function sendPromptToTerminal(session: SessionSnapshot, text: string): SendPromptResult {
  const prompt = text.replace(/\s*\n\s*/g, " ").trim();
  if (!prompt) return "empty";
  logJump(`send-prompt (${prompt.length} chars) for ${session.key}`);
  jumpToTerminal(session);

  if (!systemPreferences.isTrustedAccessibilityClient(false)) {
    logJump("Accessibility not granted — jumped without typing the prompt");
    requestAccessibilityOnce();
    return "no-accessibility";
  }

  // AppleScript string literal: escape backslashes first, then double quotes.
  const escaped = prompt.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
  execFile(
    "osascript",
    [
      "-e",
      `
      delay 0.4
      tell application "System Events"
        keystroke "${escaped}"
        key code 36
      end tell`,
    ],
    (err) => {
      logJump(err ? `send-prompt failed: ${err.message}` : "prompt sent");
    },
  );
  return "sent";
}

/** True if an app with this bundle id is currently running (lsappinfo ships with macOS). */
function isAppRunning(bundleId: string): Promise<boolean> {
  return new Promise((resolve) => {
    execFile("lsappinfo", ["find", `bundleid=${bundleId}`], (err, stdout) => {
      resolve(!err && typeof stdout === "string" && stdout.trim().length > 0);
    });
  });
}

function jumpVSCodeFamily(cwd: string): void {
  void Promise.all([isAppRunning(BUNDLE_IDS.vscode), isAppRunning(BUNDLE_IDS.Cursor)]).then(
    ([codeRunning, cursorRunning]) => {
      const bundle = !codeRunning && cursorRunning ? BUNDLE_IDS.Cursor : BUNDLE_IDS.vscode;
      raiseEditorWindow(bundle, cwd);
    },
  );
}

/** ITERM_SESSION_ID is "wNtNpN:GUID"; the AppleScript session id is the GUID. */
function jumpITerm(itermSessionId: string): void {
  if (!SAFE_ID.test(itermSessionId)) return;
  const guid = itermSessionId.includes(":")
    ? (itermSessionId.split(":").pop() ?? itermSessionId)
    : itermSessionId;

  osascript(`
    tell application "iTerm2"
      repeat with w in windows
        repeat with t in tabs of w
          repeat with s in sessions of t
            if (id of s) is "${guid}" then
              tell w to select
              tell t to select
              activate
              return
            end if
          end repeat
        end repeat
      end repeat
      activate
    end tell`);
}

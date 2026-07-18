import { execFile } from "node:child_process";
import type { SessionSnapshot } from "@agent-island/shared";

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

function osascript(script: string): void {
  execFile("osascript", ["-e", script], (err) => {
    if (err) console.error("[jump] osascript failed:", err.message);
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

  if (term === "iTerm.app" && itermId) {
    jumpITerm(itermId);
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

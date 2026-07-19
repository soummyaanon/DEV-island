import { execFile } from "node:child_process";
import { systemPreferences } from "electron";
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

  // Cursor sessions come from the IDE's hooks (no terminal identity): jump
  // means bringing Cursor itself to the front.
  if (!term && session.agent === "cursor") {
    osascript(`tell application id "${BUNDLE_IDS.Cursor}" to activate`);
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
 * Best-effort remote answer: type one digit into the session's terminal so the
 * agent's numbered prompt (AskUserQuestion / request_user_input) is selected
 * without leaving the notch. Only iTerm2 exposes safe per-session typing
 * (`write text`, no Accessibility permission needed); everywhere else we just
 * jump so the user can answer by hand. Always brings the terminal forward —
 * the user should see what got selected.
 */
export function answerInTerminal(session: SessionSnapshot, digit: string): void {
  const term = metaString(session, "term_program");
  const itermId = metaString(session, "iterm_session_id");

  if (/^[1-9]$/.test(digit) && term === "iTerm.app" && itermId && SAFE_ID.test(itermId)) {
    const guid = itermId.includes(":") ? (itermId.split(":").pop() ?? itermId) : itermId;
    osascript(`
      tell application "iTerm2"
        repeat with w in windows
          repeat with t in tabs of w
            repeat with s in sessions of t
              if (id of s) is "${guid}" then
                tell s to write text "${digit}" newline NO
                return
              end if
            end repeat
          end repeat
        end repeat
      end tell`);
    jumpToTerminal(session);
    return;
  }

  jumpToTerminal(session);

  // Any other terminal: with the Accessibility permission we can press the key
  // in the (now-frontmost) terminal via System Events. Without it, the jump
  // above already put the user where they can answer by hand.
  if (/^[1-9]$/.test(digit) && systemPreferences.isTrustedAccessibilityClient(false)) {
    osascript(`
      delay 0.4
      tell application "System Events" to keystroke "${digit}"`);
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

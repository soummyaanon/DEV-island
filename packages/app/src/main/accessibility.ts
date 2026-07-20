import { execFile } from "node:child_process";
import { app, shell, systemPreferences } from "electron";

/** The packaged app's bundle id (electron-builder appId). */
const BUNDLE_ID = "com.agentisland.app";

const ACCESSIBILITY_PANE =
  "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility";

/**
 * Ask macOS for the Accessibility grant, repairing the stale-entry trap first.
 *
 * Ad-hoc builds get a NEW code signature on every update, and macOS keys the
 * grant to the signature: after an update the System Settings toggle still
 * shows ON but no longer applies — keystrokes silently drop, and re-flipping
 * the toggle doesn't help. When we're untrusted, drop our TCC row entirely
 * (best-effort) so the isTrustedAccessibilityClient(true) prompt re-registers
 * the CURRENT binary; ticking it in the pane then grants for real.
 */
export function requestAccessibility(): void {
  if (systemPreferences.isTrustedAccessibilityClient(false)) {
    void shell.openExternal(ACCESSIBILITY_PANE); // already granted — just show the pane
    return;
  }

  const prompt = () => {
    systemPreferences.isTrustedAccessibilityClient(true);
    void shell.openExternal(ACCESSIBILITY_PANE);
  };

  // Dev runs are "Electron", not us: our bundle id has no row to reset, and
  // resetting Electron's would clobber unrelated dev tools' grants.
  if (!app.isPackaged) {
    prompt();
    return;
  }

  execFile("tccutil", ["reset", "Accessibility", BUNDLE_ID], (err) => {
    if (err) console.warn(`[accessibility] tccutil reset failed: ${err.message}`);
    prompt();
  });
}

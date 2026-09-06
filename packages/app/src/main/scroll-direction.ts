import { execFile } from "node:child_process";

/**
 * macOS "Natural scrolling" (System Settings → Trackpad → Scroll & Zoom).
 *
 * Web wheel events carry no hint of it, yet it inverts what a two-finger swipe
 * looks like to the renderer. Read the global default once so the island's
 * gestures can be defined in terms of finger motion. Missing key (never
 * toggled) means the default, which is ON.
 */
export function parseSwipeScrollDirection(stdout: string | null | undefined): boolean {
  const value = (stdout ?? "").trim();
  if (value === "0") return false;
  return true;
}

export function readNaturalScroll(): Promise<boolean> {
  return new Promise((resolve) => {
    execFile(
      "defaults",
      ["read", "-g", "com.apple.swipescrolldirection"],
      { timeout: 2000 },
      (err, stdout) => resolve(parseSwipeScrollDirection(err ? "" : stdout)),
    );
  });
}

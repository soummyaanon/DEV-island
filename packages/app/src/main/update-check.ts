import { app, Notification, net, shell } from "electron";
import { chmodSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { join } from "node:path";

/**
 * Update NOTIFIER — not an auto-updater. Without an Apple Developer ID the
 * app can't replace itself (Squirrel requires a valid signature), but it can
 * tell the user a new version exists and open the download page.
 *
 * One anonymous HTTPS request to the public GitHub Releases API, on launch and
 * every six hours. Nothing is sent beyond the request itself. Opt out with
 * AGENT_ISLAND_NO_UPDATE_CHECK=1.
 */

// Releases are published to a separate PUBLIC repo (downloads only, no source),
// so this anonymous check works — the source repo is private and its releases
// API 404s without auth.
const RELEASES_API =
  "https://api.github.com/repos/soummyaanon/DEV-island-releases/releases/latest";
// Stable one-click download of the newest DMG — GitHub 302s straight to the
// asset, so this never redirects the user to the release page. The packaging
// script always names the asset "Agent-Island.dmg", so this URL is permanent.
const DIRECT_DOWNLOAD =
  "https://github.com/soummyaanon/DEV-island-releases/releases/latest/download/Agent-Island.dmg";
const CHECK_EVERY_MS = 60 * 60 * 1000; // hourly (was 6h); Settings can also check on demand

export interface UpdateInfo {
  version: string;
}

let timer: ReturnType<typeof setInterval> | null = null;
let kickoff: ReturnType<typeof setTimeout> | null = null;
let pendingUrl: string | null = null;
let pendingUpdate: UpdateInfo | null = null;

/** "v0.2.0" beats "0.1.0"? Plain numeric semver compare, tolerant of a v prefix. */
export function isNewerVersion(current: string, latest: string): boolean {
  const parse = (v: string): number[] =>
    v
      .replace(/^v/i, "")
      .split(".")
      .map((part) => Number.parseInt(part, 10) || 0);
  const [cur, next] = [parse(current), parse(latest)];
  for (let i = 0; i < 3; i++) {
    if ((next[i] ?? 0) > (cur[i] ?? 0)) return true;
    if ((next[i] ?? 0) < (cur[i] ?? 0)) return false;
  }
  return false;
}

function notifiedPath(): string {
  return join(app.getPath("userData"), "last-notified-version");
}

function alreadyNotified(version: string): boolean {
  try {
    return existsSync(notifiedPath()) && readFileSync(notifiedPath(), "utf8").trim() === version;
  } catch {
    return false;
  }
}

function rememberNotified(version: string): void {
  try {
    writeFileSync(notifiedPath(), version);
  } catch {
    /* re-notifying next launch is harmless */
  }
}

async function checkOnce(onUpdate: (info: UpdateInfo) => void): Promise<void> {
  try {
    const res = await net.fetch(RELEASES_API, {
      headers: { accept: "application/vnd.github+json" },
    });
    if (!res.ok) return; // 404 until the first release exists; rate limits; offline
    const release = (await res.json()) as { tag_name?: string; html_url?: string };
    const latest = typeof release.tag_name === "string" ? release.tag_name : "";
    if (!latest || !isNewerVersion(app.getVersion(), latest)) return;

    // Point the notifier at the direct DMG download, not the release page.
    pendingUrl = DIRECT_DOWNLOAD;
    const version = latest.replace(/^v/i, "");
    pendingUpdate = { version };
    onUpdate({ version });

    if (!alreadyNotified(latest)) {
      rememberNotified(latest);
      const note = new Notification({
        title: "Agent Island update",
        body: `Version ${version} is available — click to download.`,
      });
      note.on("click", () => void openUpdatePage());
      note.show();
    }
  } catch {
    /* never let an update check disturb the app */
  }
}

/** Start the direct DMG download (falls back to the releases page). */
export function openUpdatePage(): void {
  void shell.openExternal(pendingUrl ?? DIRECT_DOWNLOAD);
}

/** The newest version seen by the last check, or null when up to date. */
export function getPendingUpdate(): UpdateInfo | null {
  return pendingUpdate;
}

/** Run a check right now (Settings "Check for updates" / on-open). */
export async function checkNow(onUpdate: (info: UpdateInfo) => void): Promise<void> {
  await checkOnce(onUpdate);
}

/**
 * One-click install WITHOUT an Apple Developer ID: download the newest DMG
 * ourselves, then hand a detached script the job of swapping the app bundle in
 * place and relaunching — Squirrel/electron-updater can't self-update an
 * ad-hoc-signed app, but a plain bundle swap can. Returns false if we're not a
 * packaged app or the download fails; the script stages the copy and only
 * swaps on success, so a failure leaves the current app intact.
 */
export async function downloadAndInstall(): Promise<boolean> {
  if (!app.isPackaged) return false; // dev build is the Electron binary, not a real .app
  try {
    const res = await net.fetch(DIRECT_DOWNLOAD, { redirect: "follow" });
    if (!res.ok) return false;
    const buf = Buffer.from(await res.arrayBuffer());
    const tmp = app.getPath("temp");
    const dmg = join(tmp, "Agent-Island-update.dmg");
    writeFileSync(dmg, buf);
    // /Applications/Agent Island.app  (strip /Contents/MacOS/<exe>)
    const appBundle = app.getPath("exe").replace(/\/Contents\/MacOS\/[^/]*$/, "");
    const scriptPath = join(tmp, "agent-island-update.sh");
    writeFileSync(scriptPath, updaterScript(dmg, appBundle), { mode: 0o755 });
    chmodSync(scriptPath, 0o755);
    const child = spawn("/bin/zsh", [scriptPath], { detached: true, stdio: "ignore" });
    child.unref();
    // Let the child start waiting, then quit so it can replace the bundle.
    setTimeout(() => app.quit(), 400);
    return true;
  } catch (err) {
    console.error("[update] install failed:", err);
    return false;
  }
}

/** Single-quote a path for zsh. */
function shq(s: string): string {
  return `'${s.replace(/'/g, "'\\''")}'`;
}

/** The detached updater: wait for us to quit, swap the bundle, relaunch. */
function updaterScript(dmg: string, appBundle: string): string {
  return `#!/bin/zsh
APP=${shq(appBundle)}
DMG=${shq(dmg)}
# Wait (up to ~15s) for the running app to exit so the bundle is unlocked.
for i in {1..30}; do
  pgrep -f "$APP/Contents/MacOS/" >/dev/null || break
  sleep 0.5
done
MNT=$(hdiutil attach "$DMG" -nobrowse -noautoopen | awk -F'\\t' '/\\/Volumes\\//{print $3}' | tail -1)
NEW="$MNT/Agent Island.app"
if [ -d "$NEW" ]; then
  rm -rf "$APP.new"
  # Stage first; swap only if the copy succeeds so a failure leaves the app intact.
  if ditto "$NEW" "$APP.new"; then
    rm -rf "$APP"
    mv "$APP.new" "$APP"
    xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
  fi
fi
hdiutil detach "$MNT" -quiet 2>/dev/null || hdiutil detach "$MNT" -force -quiet 2>/dev/null || true
rm -f "$DMG"
open "$APP"
`;
}

export function startUpdateCheck(onUpdate: (info: UpdateInfo) => void): void {
  if (process.env.AGENT_ISLAND_NO_UPDATE_CHECK === "1") return;
  stopUpdateCheck(); // idempotent: settings can toggle this repeatedly
  // Give launch (daemon spawn, onboarding) a brief moment first.
  kickoff = setTimeout(() => void checkOnce(onUpdate), 5_000);
  timer = setInterval(() => void checkOnce(onUpdate), CHECK_EVERY_MS);
}

export function stopUpdateCheck(): void {
  if (timer) clearInterval(timer);
  if (kickoff) clearTimeout(kickoff);
  timer = null;
  kickoff = null;
}

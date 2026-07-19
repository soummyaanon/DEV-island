import { app, Notification, net, shell } from "electron";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
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

const RELEASES_API = "https://api.github.com/repos/soummyaanon/DEV-island/releases/latest";
const RELEASES_PAGE = "https://github.com/soummyaanon/DEV-island/releases/latest";
const CHECK_EVERY_MS = 6 * 60 * 60 * 1000;

export interface UpdateInfo {
  version: string;
}

let timer: ReturnType<typeof setInterval> | null = null;
let pendingUrl: string | null = null;

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

    pendingUrl = typeof release.html_url === "string" ? release.html_url : RELEASES_PAGE;
    const version = latest.replace(/^v/i, "");
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

/** Open the pending release page (or the releases list as a fallback). */
export function openUpdatePage(): void {
  void shell.openExternal(pendingUrl ?? RELEASES_PAGE);
}

export function startUpdateCheck(onUpdate: (info: UpdateInfo) => void): void {
  if (process.env.AGENT_ISLAND_NO_UPDATE_CHECK === "1") return;
  // Give launch (daemon spawn, onboarding) a quiet moment first.
  setTimeout(() => void checkOnce(onUpdate), 15_000);
  timer = setInterval(() => void checkOnce(onUpdate), CHECK_EVERY_MS);
}

export function stopUpdateCheck(): void {
  if (timer) clearInterval(timer);
  timer = null;
}

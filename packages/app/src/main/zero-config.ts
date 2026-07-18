import { Notification } from "electron";
import { randomBytes } from "node:crypto";
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

/**
 * Zero Config: on launch, make sure Claude Code is wired to the daemon —
 * generate the shared token if needed and safe-merge our HTTP hooks into
 * ~/.claude/settings.json. Everything stays local; no accounts, no keys.
 *
 * Safety contract (same as installers/merge-claude-settings.mjs, which this
 * ports): never touch keys other than `hooks`, never remove the user's own
 * hooks, idempotent re-runs, timestamped backup before any write, and abort —
 * never clobber — if the existing settings don't parse.
 */

const OUR_MARKER = "/events/claude/";
const HOOK_EVENTS: Array<{ event: string; slug: string; matcher: boolean; timeout: number }> = [
  { event: "SessionStart", slug: "session-start", matcher: false, timeout: 5 },
  { event: "PreToolUse", slug: "pre-tool", matcher: true, timeout: 5 },
  { event: "PostToolUse", slug: "post-tool", matcher: true, timeout: 5 },
  // Held open for notch approvals — needs the long timeout.
  { event: "PermissionRequest", slug: "permission-request", matcher: true, timeout: 120 },
  { event: "Notification", slug: "notification", matcher: false, timeout: 5 },
  { event: "Stop", slug: "stop", matcher: false, timeout: 5 },
];

type Json = Record<string, unknown>;

export type ZeroConfigResult = "installed" | "updated" | "unchanged" | "error";

function agentIslandHome(): string {
  return process.env.AGENT_ISLAND_HOME ?? join(homedir(), ".agent-island");
}

function claudeSettingsPath(): string {
  return process.env.AGENT_ISLAND_CLAUDE_SETTINGS ?? join(homedir(), ".claude", "settings.json");
}

/** Read the shared token, creating a fresh random one (0600) on first run. */
function ensureToken(): string {
  const tokenPath = join(agentIslandHome(), "token");
  if (existsSync(tokenPath)) {
    const existing = readFileSync(tokenPath, "utf8").trim();
    if (existing) return existing;
  }
  const token = randomBytes(32).toString("hex");
  mkdirSync(dirname(tokenPath), { recursive: true });
  writeFileSync(tokenPath, `${token}\n`, { mode: 0o600 });
  return token;
}

function buildHandler(slug: string, timeout: number, token: string): Json {
  return {
    type: "http",
    url: `http://localhost:7433/events/claude/${slug}`,
    headers: {
      "X-Agent-Island-Token": token,
      "X-Term-Program": "$TERM_PROGRAM",
      "X-Iterm-Session-Id": "$ITERM_SESSION_ID",
      "X-Term-Session-Id": "$TERM_SESSION_ID",
    },
    allowedEnvVars: ["TERM_PROGRAM", "ITERM_SESSION_ID", "TERM_SESSION_ID"],
    timeout,
  };
}

function isOurHandler(handler: unknown): boolean {
  const h = handler as Json | null;
  return (
    !!h && h.type === "http" && typeof h.url === "string" && h.url.includes(OUR_MARKER)
  );
}

/** Strip our handlers from a list of matcher-groups, dropping emptied groups. */
function stripOurHandlers(groups: unknown): Json[] {
  return (Array.isArray(groups) ? groups : [])
    .map((group) => ({
      ...(group as Json),
      hooks: (Array.isArray((group as Json).hooks) ? ((group as Json).hooks as unknown[]) : []).filter(
        (h) => !isOurHandler(h),
      ),
    }))
    .filter((group) => (group.hooks as unknown[]).length > 0);
}

function canonical(value: unknown): string {
  const sort = (v: unknown): unknown => {
    if (Array.isArray(v)) return v.map(sort);
    if (v && typeof v === "object") {
      return Object.fromEntries(
        Object.keys(v as Json)
          .sort()
          .map((k) => [k, sort((v as Json)[k])]),
      );
    }
    return v;
  };
  return JSON.stringify(sort(value));
}

export function setupZeroConfig(): ZeroConfigResult {
  const settingsPath = claudeSettingsPath();
  try {
    const token = ensureToken();

    let settings: Json = {};
    const existed = existsSync(settingsPath);
    if (existed) {
      try {
        settings = JSON.parse(readFileSync(settingsPath, "utf8")) as Json;
      } catch (err) {
        // Unparseable settings: NEVER overwrite something we can't read.
        console.error(`[zero-config] ${settingsPath} did not parse; leaving untouched:`, err);
        return "error";
      }
    }

    const before = canonical(settings);
    const hooks = (settings.hooks && typeof settings.hooks === "object" ? settings.hooks : {}) as Json;

    for (const { event, slug, matcher, timeout } of HOOK_EVENTS) {
      const preserved = stripOurHandlers(hooks[event]);
      const group: Json = { hooks: [buildHandler(slug, timeout, token)] };
      if (matcher) group.matcher = "*";
      hooks[event] = [...preserved, group];
    }
    settings.hooks = hooks;

    if (canonical(settings) === before) {
      console.log("[zero-config] Claude hooks already up to date");
      return "unchanged";
    }

    if (existed) {
      const stamp = new Date().toISOString().replace(/[:.]/g, "-");
      copyFileSync(settingsPath, `${settingsPath}.agent-island-bak.${stamp}`);
    } else {
      mkdirSync(dirname(settingsPath), { recursive: true });
    }
    writeFileSync(settingsPath, `${JSON.stringify(settings, null, 2)}\n`);

    const result: ZeroConfigResult = existed ? "updated" : "installed";
    console.log(`[zero-config] Claude hooks ${result} in ${settingsPath}`);
    new Notification({
      title: "Agent Island",
      body: "Claude Code connected. Restart running claude sessions to see them here.",
    }).show();
    return result;
  } catch (err) {
    // Zero Config must never break the app.
    console.error("[zero-config] failed:", err);
    return "error";
  }
}

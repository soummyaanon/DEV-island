import { Notification } from "electron";
import { randomBytes } from "node:crypto";
import {
  chmodSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
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
const CLAUDE_BRIDGE = "claude-hook.sh";
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
      // The host app's bundle id (__CFBundleIdentifier) CANNOT go here:
      // Claude's header interpolation only matches UPPERCASE env var names, so
      // "$__CFBundleIdentifier" would arrive as the literal garbage
      // "undleIdentifier". The zsh SessionStart bridge forwards it instead,
      // and the daemon keeps it for the session's lifetime.
    },
    allowedEnvVars: ["TERM_PROGRAM", "ITERM_SESSION_ID", "TERM_SESSION_ID"],
    timeout,
  };
}

function claudeBridgePath(): string {
  return join(agentIslandHome(), "bin", CLAUDE_BRIDGE);
}

/** SessionStart does not support HTTP handlers, so forward its stdin with curl. */
function claudeBridgeScript(): string {
  return `#!/bin/zsh
# Agent Island Claude bridge (auto-generated; safe to delete).
EVENT="\${1:-session-start}"
TOKEN="$(cat "$HOME/.agent-island/token" 2>/dev/null)"
/usr/bin/curl -s -m 4 -X POST "http://127.0.0.1:7433/events/claude/\${EVENT}" \\
  -H "content-type: application/json" \\
  -H "x-agent-island-token: \${TOKEN}" \\
  -H "X-Term-Program: \${TERM_PROGRAM:-}" \\
  -H "X-Iterm-Session-Id: \${ITERM_SESSION_ID:-}" \\
  -H "X-Term-Session-Id: \${TERM_SESSION_ID:-}" \\
  -H "X-App-Bundle-Id: \${__CFBundleIdentifier:-}" \\
  -H "X-Agent-Pid: \${PPID:-}" \\
  --data-binary @- >/dev/null 2>&1
exit 0
`;
}

function isOurHandler(handler: unknown): boolean {
  const h = handler as Json | null;
  return (
    !!h &&
    ((h.type === "http" && typeof h.url === "string" && h.url.includes(OUR_MARKER)) ||
      (h.type === "command" && h.command === claudeBridgePath()))
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
      let handler: Json;
      if (event === "SessionStart") {
        const bridgePath = claudeBridgePath();
        mkdirSync(dirname(bridgePath), { recursive: true });
        writeFileSync(bridgePath, claudeBridgeScript(), { mode: 0o755 });
        chmodSync(bridgePath, 0o755);
        handler = { type: "command", command: bridgePath, args: [slug], timeout };
      } else {
        handler = buildHandler(slug, timeout, token);
      }
      const group: Json = { hooks: [handler] };
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

/**
 * Disconnect Claude Code: strip exactly our handlers from every hook event,
 * leaving the user's own hooks untouched. Same backup/abort contract as install.
 */
export function removeClaudeHooks(): ZeroConfigResult {
  const settingsPath = claudeSettingsPath();
  try {
    if (!existsSync(settingsPath)) return "unchanged";
    let settings: Json;
    try {
      settings = JSON.parse(readFileSync(settingsPath, "utf8")) as Json;
    } catch (err) {
      console.error(`[zero-config] ${settingsPath} did not parse; leaving untouched:`, err);
      return "error";
    }
    const before = canonical(settings);
    const hooks = (settings.hooks && typeof settings.hooks === "object" ? settings.hooks : {}) as Json;
    for (const { event } of HOOK_EVENTS) {
      const preserved = stripOurHandlers(hooks[event]);
      if (preserved.length > 0) hooks[event] = preserved;
      else delete hooks[event];
    }
    if (Object.keys(hooks).length > 0) settings.hooks = hooks;
    else delete settings.hooks;

    if (canonical(settings) === before) return "unchanged";
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    copyFileSync(settingsPath, `${settingsPath}.agent-island-bak.${stamp}`);
    writeFileSync(settingsPath, `${JSON.stringify(settings, null, 2)}\n`);
    console.log(`[zero-config] Claude hooks removed from ${settingsPath}`);
    return "updated";
  } catch (err) {
    console.error("[zero-config] claude removal failed:", err);
    return "error";
  }
}

/* ------------------------------------------------------------------------- */
/* Cursor: hooks.json + a fire-and-forget bridge script                        */
/* ------------------------------------------------------------------------- */

const CURSOR_MARKER = ".agent-island/bin/cursor-hook";
/**
 * Observing hooks only — the bridge exits 0 immediately so Cursor never waits.
 * Includes lifecycle (sessionStart/End), generic tool hooks (pre/postToolUse),
 * and the specialized shell/file/MCP hooks for denser activity titles.
 */
const CURSOR_EVENTS = [
  "sessionStart",
  "sessionEnd",
  "beforeSubmitPrompt",
  "preToolUse",
  "postToolUse",
  "postToolUseFailure",
  "beforeShellExecution",
  "afterShellExecution",
  "beforeReadFile",
  "afterFileEdit",
  "beforeMCPExecution",
  "afterMCPExecution",
  "afterAgentThought",
  "afterAgentResponse",
  "subagentStart",
  "subagentStop",
  "preCompact",
  "stop",
];

function cursorHooksPath(): string {
  return process.env.AGENT_ISLAND_CURSOR_HOOKS ?? join(homedir(), ".cursor", "hooks.json");
}

/** The bridge: forward stdin JSON to the daemon in the background, exit 0 now. */
function bridgeScript(): string {
  return `#!/bin/zsh
# Agent Island Cursor bridge (auto-generated; safe to delete).
# Forwards the hook JSON from stdin to the local daemon, fire-and-forget:
# Cursor never waits on us and never fails because of us.
EVENT="\${1:-unknown}"
IN="$(cat)"
TOKEN="$(cat "$HOME/.agent-island/token" 2>/dev/null)"
( printf '%s' "$IN" | /usr/bin/curl -s -m 2 -X POST "http://127.0.0.1:7433/events/cursor/\${EVENT}" \\
    -H "content-type: application/json" -H "x-agent-island-token: \${TOKEN}" \\
    -H "X-Agent-Pid: \${PPID:-}" \\
    --data-binary @- >/dev/null 2>&1 & )
exit 0
`;
}

/**
 * Wire Cursor to the daemon: install the bridge script and safe-merge one
 * entry per hook event into ~/.cursor/hooks.json. Same contract as the Claude
 * merge — other tools' hooks are preserved verbatim, re-runs are idempotent,
 * a timestamped backup precedes any write, and unparseable config aborts.
 */
export function setupCursorZeroConfig(): ZeroConfigResult {
  const hooksPath = cursorHooksPath();
  try {
    ensureToken();

    const binPath = join(agentIslandHome(), "bin", "cursor-hook.sh");
    const script = bridgeScript();
    if (!existsSync(binPath) || readFileSync(binPath, "utf8") !== script) {
      mkdirSync(dirname(binPath), { recursive: true });
      writeFileSync(binPath, script, { mode: 0o755 });
    }

    let config: Json = {};
    const existed = existsSync(hooksPath);
    if (existed) {
      try {
        config = JSON.parse(readFileSync(hooksPath, "utf8")) as Json;
      } catch (err) {
        console.error(`[zero-config] ${hooksPath} did not parse; leaving untouched:`, err);
        return "error";
      }
    }

    const before = canonical(config);
    if (typeof config.version !== "number") config.version = 1;
    const hooks = (config.hooks && typeof config.hooks === "object" ? config.hooks : {}) as Json;

    for (const event of CURSOR_EVENTS) {
      const entries = (Array.isArray(hooks[event]) ? (hooks[event] as unknown[]) : []).filter(
        (entry) => {
          const cmd = (entry as Json | null)?.command;
          return !(typeof cmd === "string" && cmd.includes(CURSOR_MARKER));
        },
      );
      entries.push({ command: `${binPath} ${event}` });
      hooks[event] = entries;
    }
    config.hooks = hooks;

    if (canonical(config) === before) return "unchanged";

    if (existed) {
      const stamp = new Date().toISOString().replace(/[:.]/g, "-");
      copyFileSync(hooksPath, `${hooksPath}.agent-island-bak.${stamp}`);
    } else {
      mkdirSync(dirname(hooksPath), { recursive: true });
    }
    writeFileSync(hooksPath, `${JSON.stringify(config, null, 2)}\n`);

    const result: ZeroConfigResult = existed ? "updated" : "installed";
    console.log(`[zero-config] Cursor hooks ${result} in ${hooksPath}`);
    return result;
  } catch (err) {
    console.error("[zero-config] cursor failed:", err);
    return "error";
  }
}

/** Disconnect Cursor: drop exactly our bridge entries; other tools' hooks stay. */
export function removeCursorHooks(): ZeroConfigResult {
  const hooksPath = cursorHooksPath();
  try {
    if (!existsSync(hooksPath)) return "unchanged";
    let config: Json;
    try {
      config = JSON.parse(readFileSync(hooksPath, "utf8")) as Json;
    } catch (err) {
      console.error(`[zero-config] ${hooksPath} did not parse; leaving untouched:`, err);
      return "error";
    }
    const before = canonical(config);
    const hooks = (config.hooks && typeof config.hooks === "object" ? config.hooks : {}) as Json;
    for (const event of Object.keys(hooks)) {
      const entries = (Array.isArray(hooks[event]) ? (hooks[event] as unknown[]) : []).filter(
        (entry) => {
          const cmd = (entry as Json | null)?.command;
          return !(typeof cmd === "string" && cmd.includes(CURSOR_MARKER));
        },
      );
      if (entries.length > 0) hooks[event] = entries;
      else delete hooks[event];
    }
    if (Object.keys(hooks).length > 0) config.hooks = hooks;
    else delete config.hooks;

    if (canonical(config) === before) return "unchanged";
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    copyFileSync(hooksPath, `${hooksPath}.agent-island-bak.${stamp}`);
    writeFileSync(hooksPath, `${JSON.stringify(config, null, 2)}\n`);
    console.log(`[zero-config] Cursor hooks removed from ${hooksPath}`);
    return "updated";
  } catch (err) {
    console.error("[zero-config] cursor removal failed:", err);
    return "error";
  }
}

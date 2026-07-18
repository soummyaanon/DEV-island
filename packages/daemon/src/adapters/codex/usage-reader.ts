import { readdir, readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import type { AgentUsage, UsageWindow } from "@agent-island/shared";

async function collectRollouts(dir: string, out: string[]): Promise<void> {
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    const p = join(dir, entry.name);
    if (entry.isDirectory()) {
      await collectRollouts(p, out);
    } else if (entry.isFile() && entry.name.startsWith("rollout-") && entry.name.endsWith(".jsonl")) {
      out.push(p);
    }
  }
}

/** Most-recently-modified rollout file under $CODEX_HOME/sessions (the active one). */
async function newestRollout(sessionsDir: string): Promise<string | null> {
  const files: string[] = [];
  await collectRollouts(sessionsDir, files);
  if (files.length === 0) return null;

  let bestPath: string | null = null;
  let bestMtime = -1;
  for (const f of files) {
    try {
      const s = await stat(f);
      if (s.mtimeMs > bestMtime) {
        bestMtime = s.mtimeMs;
        bestPath = f;
      }
    } catch {
      /* ignore unreadable file */
    }
  }
  return bestPath;
}

function labelForWindow(minutes: unknown): string {
  if (typeof minutes !== "number" || minutes <= 0) return "window";
  if (minutes <= 360) return "5h";
  if (minutes <= 1440) return "daily";
  if (minutes <= 20160) return "weekly";
  return "monthly";
}

interface RawWindow {
  used_percent?: unknown;
  window_minutes?: unknown;
  resets_at?: unknown;
}

function toWindow(w: RawWindow | null | undefined): UsageWindow | null {
  if (!w || typeof w.used_percent !== "number") return null;
  return {
    label: labelForWindow(w.window_minutes),
    used_percent: w.used_percent,
    resets_at: typeof w.resets_at === "number" ? w.resets_at : null,
  };
}

/**
 * Read Codex's account quota from the newest rollout log's last `token_count`
 * event. Fully local — no network, no auth. Returns null if nothing is found.
 */
export async function readCodexUsage(codexHome: string): Promise<AgentUsage | null> {
  const file = await newestRollout(join(codexHome, "sessions"));
  if (!file) return null;

  let content: string;
  try {
    content = await readFile(file, "utf8");
  } catch {
    return null;
  }

  const lines = content.split("\n");
  let rl: Record<string, unknown> | null = null;
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i];
    if (!line || !line.includes("rate_limits")) continue;
    try {
      const parsed = JSON.parse(line) as { payload?: Record<string, unknown> } & Record<string, unknown>;
      const payload = (parsed.payload ?? parsed) as Record<string, unknown>;
      if (payload.type === "token_count" && payload.rate_limits) {
        rl = payload.rate_limits as Record<string, unknown>;
        break;
      }
    } catch {
      /* skip malformed line */
    }
  }
  if (!rl) return null;

  const windows = [toWindow(rl.primary as RawWindow), toWindow(rl.secondary as RawWindow)].filter(
    (w): w is UsageWindow => w !== null,
  );

  const credits = rl.credits as { balance?: unknown } | undefined;
  const balance = credits?.balance;

  return {
    agent: "codex",
    plan: typeof rl.plan_type === "string" ? rl.plan_type : null,
    windows,
    credits: balance == null ? null : String(balance),
    updated_at: new Date().toISOString(),
  };
}

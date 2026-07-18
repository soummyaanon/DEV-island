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
async function newestRollout(sessionsDir: string): Promise<{ path: string; mtimeMs: number } | null> {
  const files: string[] = [];
  await collectRollouts(sessionsDir, files);
  if (files.length === 0) return null;

  let best: { path: string; mtimeMs: number } | null = null;
  for (const f of files) {
    try {
      const s = await stat(f);
      if (!best || s.mtimeMs > best.mtimeMs) best = { path: f, mtimeMs: s.mtimeMs };
    } catch {
      /* ignore unreadable file */
    }
  }
  return best;
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
 * event. Fully local — no network, no auth. Returns null when nothing is found,
 * or when Codex hasn't been used within `activeMs` (so we only surface usage
 * while it's actually in use rather than showing stale quota indefinitely).
 */
export async function readCodexUsage(codexHome: string, activeMs: number): Promise<AgentUsage | null> {
  const newest = await newestRollout(join(codexHome, "sessions"));
  if (!newest) return null;
  if (Date.now() - newest.mtimeMs > activeMs) return null; // not in use recently
  const file = newest.path;

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

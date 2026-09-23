import type { AgentUsage, UsageWindow } from "@agent-island/shared";

/**
 * Claude Code's subscription limits, from the JSON it pipes to its status line
 * command on every refresh (`rate_limits.five_hour` / `.seven_day`). Local:
 * Claude Code already has these from its own API responses, so reading them
 * here needs no token and no request of ours.
 */

const WINDOWS: Array<[key: string, label: string]> = [
  ["five_hour", "5h"],
  ["seven_day", "weekly"],
  ["spend_limit", "spend"],
];

function toWindow(raw: unknown, label: string, nowSec: number): UsageWindow | null {
  if (!raw || typeof raw !== "object") return null;
  const w = raw as { used_percentage?: unknown; resets_at?: unknown };
  if (typeof w.used_percentage !== "number" || !Number.isFinite(w.used_percentage)) return null;
  const resets = typeof w.resets_at === "number" ? w.resets_at : null;
  // A window whose reset has passed is stale: its percentage no longer applies.
  if (resets !== null && resets <= nowSec) return null;
  return { label, used_percent: Math.max(0, w.used_percentage), resets_at: resets };
}

export function parseClaudeUsage(body: unknown, now = Date.now()): AgentUsage | null {
  if (!body || typeof body !== "object") return null;
  const limits = (body as { rate_limits?: unknown }).rate_limits;
  if (!limits || typeof limits !== "object") return null;
  const nowSec = Math.floor(now / 1000);
  const windows = WINDOWS.map(([key, label]) =>
    toWindow((limits as Record<string, unknown>)[key], label, nowSec),
  ).filter((w): w is UsageWindow => w !== null);
  if (windows.length === 0) return null;
  return { agent: "claude-code", plan: null, windows, credits: null, updated_at: new Date(now).toISOString() };
}

/** Drop windows whose reset time has passed since they were reported. */
export function freshWindows(usage: AgentUsage, now = Date.now()): AgentUsage | null {
  const nowSec = Math.floor(now / 1000);
  const windows = usage.windows.filter((w) => w.resets_at === null || w.resets_at > nowSec);
  return windows.length > 0 ? { ...usage, windows } : null;
}

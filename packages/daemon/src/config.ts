import { homedir } from "node:os";
import { join } from "node:path";

/** Resolved runtime configuration for agentislandd. */
export interface DaemonConfig {
  /** Bind address — 127.0.0.1 only, never exposed off-host. */
  host: string;
  port: number;
  /** Path to the shared auth token file. */
  tokenPath: string;
  /** When true, requests without a valid token are rejected (401). */
  strictAuth: boolean;
  /** Max events retained in the debug ring buffer. */
  ringBufferSize: number;
  /** WebSocket keep-alive interval in milliseconds. */
  heartbeatMs: number;
  /** How long to hold a permission hook waiting for a notch decision. */
  approvalHoldMs: number;
  /** Codex home dir (for reading rollout usage). */
  codexHome: string;
  /** How often to refresh account usage/quota. */
  usagePollMs: number;
  /** Only show Codex usage if its rollout was written within this window ("in use"). */
  codexActiveMs: number;
  /** How often the Codex rollout tailer polls attached files for appends. */
  codexPollMs: number;
  /** How often the Codex rollout tailer rescans for new session files. */
  codexScanMs: number;
}

function intFromEnv(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw.trim() === "") return fallback;
  const parsed = Number(raw);
  return Number.isFinite(parsed) ? parsed : fallback;
}

export function loadConfig(): DaemonConfig {
  const home = process.env.AGENT_ISLAND_HOME ?? join(homedir(), ".agent-island");
  const strictAuth =
    process.env.AGENT_ISLAND_STRICT === "1" || process.env.NODE_ENV === "production";

  return {
    host: process.env.AGENT_ISLAND_HOST ?? "127.0.0.1",
    port: intFromEnv("AGENT_ISLAND_PORT", 7433),
    tokenPath: join(home, "token"),
    strictAuth,
    ringBufferSize: intFromEnv("AGENT_ISLAND_RING_SIZE", 500),
    heartbeatMs: intFromEnv("AGENT_ISLAND_HEARTBEAT_MS", 30_000),
    approvalHoldMs: intFromEnv("AGENT_ISLAND_APPROVAL_HOLD_MS", 110_000),
    codexHome: process.env.CODEX_HOME ?? join(homedir(), ".codex"),
    usagePollMs: intFromEnv("AGENT_ISLAND_USAGE_POLL_MS", 45_000),
    codexActiveMs: intFromEnv("AGENT_ISLAND_CODEX_ACTIVE_MS", 600_000), // 10 min
    codexPollMs: intFromEnv("AGENT_ISLAND_CODEX_POLL_MS", 1_500),
    codexScanMs: intFromEnv("AGENT_ISLAND_CODEX_SCAN_MS", 10_000),
  };
}

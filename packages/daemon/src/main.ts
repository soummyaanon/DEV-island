// agentislandd — local event hub for Agent Island.
// Receives canonical events over HTTP, folds them into per-session state, and
// streams them to the UI over WebSocket. Binds to 127.0.0.1 only.
import { loadConfig } from "./config";
import { ensureToken } from "./auth-token";
import { EventHub } from "./hub/event-hub";
import { buildServer } from "./server/http-server";
import { readCodexUsage } from "./adapters/codex/usage-reader";
import { freshWindows } from "./adapters/claude/usage";
import { CodexRolloutReader } from "./adapters/codex/rollout-reader";

/** How often ended sessions are swept out. */
const PRUNE_EVERY_MS = 5_000;
/** A finished session with no live process to vouch for it leaves after this. */
const STALE_SESSION_MS = 30 * 60_000;

async function main(): Promise<void> {
  const config = loadConfig();
  const token = ensureToken(config.tokenPath);
  const hub = new EventHub(config.ringBufferSize, config.approvalHoldMs);
  const app = await buildServer(config, hub, token);

  const heartbeat = setInterval(() => {
    hub.broadcast({ type: "ping", t: new Date().toISOString() });
  }, config.heartbeatMs);

  // Poll Codex account usage from local rollout logs (no network).
  const refreshUsage = async (): Promise<void> => {
    try {
      const usage = await readCodexUsage(config.codexHome, config.codexActiveMs);
      hub.setAgentUsage("codex", usage);
      // Claude's reading is pushed; here it only ages out past its reset.
      const claude = hub.getUsage().find((u) => u.agent === "claude-code");
      if (claude) hub.setAgentUsage("claude-code", freshWindows(claude));
    } catch (err) {
      app.log.warn(`usage refresh failed: ${String(err)}`);
    }
  };
  void refreshUsage();
  const usageTimer = setInterval(() => void refreshUsage(), config.usagePollMs);

  // Closed sessions leave the island. A killed terminal fires no hook, so the
  // agent's process is checked directly (signal 0 = "does it exist").
  const isAlive = (pid: number): boolean => {
    try {
      process.kill(pid, 0);
      return true;
    } catch (err) {
      // EPERM: it exists, it's just not ours to signal.
      return (err as NodeJS.ErrnoException).code === "EPERM";
    }
  };
  const pruneTimer = setInterval(() => {
    const gone = hub.pruneSessions(isAlive, STALE_SESSION_MS);
    if (gone.length > 0) app.log.info(`pruned ended sessions: ${gone.join(", ")}`);
  }, PRUNE_EVERY_MS);

  // Tail Codex rollout logs into the hub (read-only; Codex is never touched).
  // A failed reader is a logged degradation, never a failed daemon.
  const codexReader = new CodexRolloutReader(
    config.codexHome,
    {
      ingest: (input) => hub.ingest(input),
      setPendingQuestion: (sessionId, question) =>
        hub.setPendingQuestion("codex", sessionId, question),
    },
    {
      pollMs: config.codexPollMs,
      scanMs: config.codexScanMs,
      activeMs: config.codexActiveMs,
      log: (message) => app.log.warn(message),
    },
  );
  try {
    await codexReader.start();
  } catch (err) {
    app.log.warn(`codex rollout reader failed to start: ${String(err)}`);
  }

  await app.listen({ host: config.host, port: config.port });
  app.log.info(
    `agentislandd ready — auth ${config.strictAuth ? "STRICT" : "lenient (dev)"}, token at ${config.tokenPath}`,
  );

  let shuttingDown = false;
  const shutdown = async (signal: string): Promise<void> => {
    if (shuttingDown) return;
    shuttingDown = true;
    app.log.info(`received ${signal}, shutting down`);
    clearInterval(heartbeat);
    clearInterval(usageTimer);
    clearInterval(pruneTimer);
    codexReader.stop();
    await app.close();
    process.exit(0);
  };

  process.on("SIGINT", () => void shutdown("SIGINT"));
  process.on("SIGTERM", () => void shutdown("SIGTERM"));
}

main().catch((err) => {
  console.error("agentislandd failed to start:", err);
  process.exit(1);
});

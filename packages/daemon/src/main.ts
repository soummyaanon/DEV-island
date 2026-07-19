// agentislandd — local event hub for Agent Island.
// Receives canonical events over HTTP, folds them into per-session state, and
// streams them to the UI over WebSocket. Binds to 127.0.0.1 only.
import { loadConfig } from "./config";
import { ensureToken } from "./auth-token";
import { EventHub } from "./hub/event-hub";
import { buildServer } from "./server/http-server";
import { readCodexUsage } from "./adapters/codex/usage-reader";
import { CodexRolloutReader } from "./adapters/codex/rollout-reader";

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
      hub.setUsage(usage ? [usage] : []);
    } catch (err) {
      app.log.warn(`usage refresh failed: ${String(err)}`);
    }
  };
  void refreshUsage();
  const usageTimer = setInterval(() => void refreshUsage(), config.usagePollMs);

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

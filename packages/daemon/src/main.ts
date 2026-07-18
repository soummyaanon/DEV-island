// agentislandd — local event hub for Agent Island.
// Receives canonical events over HTTP, folds them into per-session state, and
// streams them to the UI over WebSocket. Binds to 127.0.0.1 only.
import { loadConfig } from "./config";
import { ensureToken } from "./auth-token";
import { EventHub } from "./hub/event-hub";
import { buildServer } from "./server/http-server";

async function main(): Promise<void> {
  const config = loadConfig();
  const token = ensureToken(config.tokenPath);
  const hub = new EventHub(config.ringBufferSize);
  const app = await buildServer(config, hub, token);

  const heartbeat = setInterval(() => {
    hub.broadcast({ type: "ping", t: new Date().toISOString() });
  }, config.heartbeatMs);

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

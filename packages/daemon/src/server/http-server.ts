import Fastify, { type FastifyInstance } from "fastify";
import websocket from "@fastify/websocket";
import type { DaemonConfig } from "../config";
import type { EventHub } from "../hub/event-hub";
import { registerIngestRoutes } from "./routes-ingest";
import { registerClaudeRoutes } from "./routes-claude";
import { registerCursorRoutes } from "./routes-cursor";
import { registerApprovalRoutes } from "./routes-approvals";
import { registerUiRoutes } from "./routes-ui";
import { registerStreamRoute } from "./ws-stream";

/** Build (but do not start) the Fastify server with all routes wired. */
export async function buildServer(
  config: DaemonConfig,
  hub: EventHub,
  token: string,
): Promise<FastifyInstance> {
  const app = Fastify({ logger: true });

  // WebSocket support must be registered before the /stream route.
  await app.register(websocket);

  registerUiRoutes(app, hub);
  registerIngestRoutes(app, hub, config, token);
  registerClaudeRoutes(app, hub, config, token);
  registerCursorRoutes(app, hub, config, token);
  registerApprovalRoutes(app, hub);
  registerStreamRoute(app, hub);

  return app;
}

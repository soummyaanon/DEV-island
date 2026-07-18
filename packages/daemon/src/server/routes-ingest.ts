import type { FastifyInstance } from "fastify";
import { EventInputSchema } from "@agent-island/shared";
import type { DaemonConfig } from "../config";
import type { EventHub } from "../hub/event-hub";
import { extractToken, verifyToken } from "../auth-token";

/**
 * `POST /events` — the single generic ingest endpoint. Accepts a canonical
 * EventInput; the daemon mints id + timestamp. Agent-specific routes and
 * mappers (Claude hooks, Codex notify) are added with their adapters later.
 */
export function registerIngestRoutes(
  app: FastifyInstance,
  hub: EventHub,
  config: DaemonConfig,
  token: string,
): void {
  app.post("/events", (request, reply) => {
    const provided = extractToken(request.headers);
    if (!verifyToken(provided, token)) {
      if (config.strictAuth) {
        return reply.code(401).send({ error: "invalid or missing token" });
      }
      request.log.warn("POST /events accepted without a valid token (dev/lenient mode)");
    }

    const parsed = EventInputSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: "invalid event", issues: parsed.error.issues });
    }

    const { event, session } = hub.ingest(parsed.data);
    return reply.code(202).send({ ok: true, event, session });
  });
}

import type { FastifyInstance } from "fastify";
import { EventInputSchema } from "@agent-island/shared";
import type { EventHub } from "../hub/event-hub";
import { makeAuthGuard } from "./auth-guard";
import type { DaemonConfig } from "../config";

/**
 * `POST /events` — the generic ingest endpoint. Accepts a canonical EventInput;
 * the daemon mints id + timestamp. Agent-specific routes (Claude hooks, Codex
 * notify) live alongside this and reuse the same auth guard.
 */
export function registerIngestRoutes(
  app: FastifyInstance,
  hub: EventHub,
  config: DaemonConfig,
  token: string,
): void {
  const authGuard = makeAuthGuard(config, token);

  app.post("/events", { preHandler: authGuard }, (request, reply) => {
    const parsed = EventInputSchema.safeParse(request.body);
    if (!parsed.success) {
      return reply.code(400).send({ error: "invalid event", issues: parsed.error.issues });
    }

    const { event, session } = hub.ingest(parsed.data);
    return reply.code(202).send({ ok: true, event, session });
  });
}

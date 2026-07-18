import type { FastifyInstance } from "fastify";
import type { EventHub } from "../hub/event-hub";

/** Read-only endpoints the UI (and curl) use. Localhost-only; no auth in M1. */
export function registerUiRoutes(app: FastifyInstance, hub: EventHub): void {
  app.get("/health", () => ({
    status: "ok",
    sessions: hub.sessions().length,
    subscribers: hub.subscriberCount(),
    uptime_s: Math.round(process.uptime()),
  }));

  app.get("/sessions", () => ({ sessions: hub.sessions() }));

  app.get<{ Querystring: { limit?: string } }>("/events", (request) => {
    const raw = request.query.limit;
    const parsed = raw === undefined ? undefined : Number(raw);
    const limit =
      parsed !== undefined && Number.isFinite(parsed) ? Math.max(0, Math.trunc(parsed)) : undefined;
    return { events: hub.recentEvents(limit) };
  });
}

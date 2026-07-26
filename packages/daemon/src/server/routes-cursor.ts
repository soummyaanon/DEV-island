import type { FastifyInstance } from "fastify";
import type { EventHub } from "../hub/event-hub";
import type { DaemonConfig } from "../config";
import { makeAuthGuard } from "./auth-guard";
import {
  mapCursorHook,
  resolveCursorEventName,
  type CursorHookPayload,
} from "../adapters/cursor/event-mapper";

/**
 * `POST /events/cursor/:hookEvent` — receives Cursor hook payloads forwarded by
 * the bridge script (~/.agent-island/bin/cursor-hook.sh, fire-and-forget).
 *
 * ALWAYS replies 204 with an empty body: the bridge never reads the response,
 * and a monitoring endpoint must never emit anything a gating hook could
 * interpret as a decision. Unparseable or unmapped payloads are a logged
 * no-op — a confused daemon must not disturb the user's Cursor session.
 */
export function registerCursorRoutes(
  app: FastifyInstance,
  hub: EventHub,
  config: DaemonConfig,
  token: string,
): void {
  const authGuard = makeAuthGuard(config, token);

  app.post<{ Params: { hookEvent: string } }>(
    "/events/cursor/:hookEvent",
    { preHandler: authGuard },
    async (request, reply) => {
      const payload =
        request.body && typeof request.body === "object"
          ? (request.body as CursorHookPayload)
          : ({} as CursorHookPayload);

      const eventName = resolveCursorEventName(request.params.hookEvent, payload);
      // Cursor uses conversation_id on most hooks; sessionStart/End send session_id.
      const sessionId =
        (typeof payload.conversation_id === "string" && payload.conversation_id) ||
        (typeof payload.session_id === "string" && payload.session_id) ||
        (typeof payload.generation_id === "string" && payload.generation_id) ||
        undefined;
      const fallbackCwd =
        (sessionId && hub.getSession("cursor", sessionId)?.cwd) || "(unknown)";

      const mapped = mapCursorHook(eventName, payload, fallbackCwd);
      if (!mapped) {
        request.log.info(`ignoring unmapped cursor hook: ${eventName}`);
        return reply.code(204).send();
      }

      hub.ingest(mapped);
      return reply.code(204).send();
    },
  );
}

import type { FastifyInstance } from "fastify";
import type { EventHub } from "../hub/event-hub";
import type { DaemonConfig } from "../config";
import { makeAuthGuard } from "./auth-guard";
import { ClaudeHookPayloadSchema } from "../adapters/claude/hook-payload";
import { mapClaudeHook, resolveHookEventName } from "../adapters/claude/event-mapper";

/**
 * `POST /events/claude/:hookEvent` — receives raw Claude Code hook payloads.
 * Claude's HTTP hooks POST their JSON here; we map them onto canonical events.
 *
 * ALWAYS replies 204 with an EMPTY body. Claude parses any 2xx JSON response as
 * a decision object that can alter the live session, so a monitoring endpoint
 * must never send one. Unparseable or unmapped events are a logged no-op, never
 * an error — a dead/confused daemon must not disrupt the user's Claude session.
 */
export function registerClaudeRoutes(
  app: FastifyInstance,
  hub: EventHub,
  config: DaemonConfig,
  token: string,
): void {
  const authGuard = makeAuthGuard(config, token);

  app.post<{ Params: { hookEvent: string } }>(
    "/events/claude/:hookEvent",
    { preHandler: authGuard },
    (request, reply) => {
      const parsed = ClaudeHookPayloadSchema.safeParse(request.body);
      if (!parsed.success) {
        request.log.warn({ issues: parsed.error.issues }, "unparseable claude hook payload");
        return reply.code(204).send();
      }

      const payload = parsed.data;
      const eventName = resolveHookEventName(request.params.hookEvent, payload);
      const fallbackCwd = hub.getSession("claude-code", payload.session_id)?.cwd ?? "(unknown)";

      const mapped = mapClaudeHook(eventName, payload, fallbackCwd);
      if (!mapped) {
        request.log.info(`ignoring unmapped claude hook: ${eventName}`);
        return reply.code(204).send();
      }

      hub.ingest(mapped);
      return reply.code(204).send();
    },
  );
}

import type { FastifyInstance } from "fastify";
import type { IncomingHttpHeaders } from "node:http";
import type { EventHub } from "../hub/event-hub";
import type { DaemonConfig } from "../config";
import { makeAuthGuard } from "./auth-guard";
import { ClaudeHookPayloadSchema } from "../adapters/claude/hook-payload";
import { mapClaudeHook, resolveHookEventName } from "../adapters/claude/event-mapper";

function header(headers: IncomingHttpHeaders, name: string): string | undefined {
  const raw = headers[name];
  const value = Array.isArray(raw) ? raw[0] : raw;
  const trimmed = value?.trim();
  // Drop empty or uninterpolated ("$VAR" when the env var was unset) values.
  if (!trimmed || trimmed.startsWith("$")) return undefined;
  return trimmed;
}

/** Terminal identity forwarded by the hook (via allowedEnvVars), for jump-to-terminal. */
function terminalMeta(headers: IncomingHttpHeaders): Record<string, string> {
  const meta: Record<string, string> = {};
  const term = header(headers, "x-term-program");
  const iterm = header(headers, "x-iterm-session-id");
  const termSession = header(headers, "x-term-session-id");
  if (term) meta.term_program = term;
  if (iterm) meta.iterm_session_id = iterm;
  if (termSession) meta.term_session_id = termSession;
  return meta;
}

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

      const meta = terminalMeta(request.headers);
      if (Object.keys(meta).length > 0) {
        mapped.detail = { ...(mapped.detail ?? {}), _meta: meta };
      }

      hub.ingest(mapped);
      return reply.code(204).send();
    },
  );
}

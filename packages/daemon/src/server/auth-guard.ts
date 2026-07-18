import type { FastifyReply, FastifyRequest } from "fastify";
import type { DaemonConfig } from "../config";
import { extractToken, verifyToken } from "../auth-token";

/**
 * Build a Fastify preHandler that enforces the shared token on write routes.
 * Strict mode rejects (401) missing/invalid tokens; dev mode warns and allows
 * so `curl` stays a one-liner. Shared by every event-ingest endpoint.
 */
export function makeAuthGuard(config: DaemonConfig, token: string) {
  return async function authGuard(request: FastifyRequest, reply: FastifyReply): Promise<void> {
    const provided = extractToken(request.headers);
    if (verifyToken(provided, token)) return;

    if (config.strictAuth) {
      await reply.code(401).send({ error: "invalid or missing token" });
      return;
    }
    request.log.warn(`${request.method} ${request.url} accepted without a valid token (dev/lenient mode)`);
  };
}

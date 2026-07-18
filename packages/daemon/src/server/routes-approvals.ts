import type { FastifyInstance } from "fastify";
import { ApprovalDecisionSchema } from "@agent-island/shared";
import type { EventHub } from "../hub/event-hub";

/**
 * `POST /approvals/:id` — the notch resolves a held approval here. The id is a
 * UUID only ever sent to WS subscribers, so it acts as an unguessable capability
 * on the localhost boundary (token auth is a later hardening).
 */
export function registerApprovalRoutes(app: FastifyInstance, hub: EventHub): void {
  app.post<{ Params: { id: string }; Body: { decision?: unknown } }>(
    "/approvals/:id",
    (request, reply) => {
      const parsed = ApprovalDecisionSchema.safeParse(request.body?.decision);
      if (!parsed.success) {
        return reply.code(400).send({ error: "decision must be 'allow' or 'deny'" });
      }
      const resolved = hub.resolveApproval(request.params.id, parsed.data);
      return reply.code(resolved ? 200 : 404).send({ ok: resolved });
    },
  );
}

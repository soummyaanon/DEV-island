import type { FastifyInstance } from "fastify";
import type { EventHub } from "../hub/event-hub";

/**
 * `POST /questions/:id` — the notch answers a held AskUserQuestion here with
 * one 0-based option index per question. Same unguessable-UUID capability
 * model as /approvals.
 */
export function registerQuestionRoutes(app: FastifyInstance, hub: EventHub): void {
  app.post<{ Params: { id: string }; Body: { options?: unknown } }>(
    "/questions/:id",
    (request, reply) => {
      const options = request.body?.options;
      const valid =
        Array.isArray(options) &&
        options.length > 0 &&
        options.every((o) => typeof o === "number" && Number.isInteger(o) && o >= 0);
      if (!valid) {
        return reply
          .code(400)
          .send({ error: "options must be a non-empty array of non-negative integers" });
      }
      const resolved = hub.answerQuestion(request.params.id, options as number[]);
      return reply.code(resolved ? 200 : 404).send({ ok: resolved });
    },
  );
}

import type { FastifyInstance } from "fastify";
import type { EventHub } from "../hub/event-hub";

const isIndex = (o: unknown): o is number => typeof o === "number" && Number.isInteger(o) && o >= 0;

/**
 * The body's answer as chosen indices per question. `selections` (one array
 * per question — several entries for a multi-select) is the current shape;
 * `options` (one index per question) is still accepted from older apps.
 */
export function parseSelections(body: { options?: unknown; selections?: unknown } | undefined): number[][] | null {
  const selections = body?.selections;
  if (Array.isArray(selections)) {
    const ok =
      selections.length > 0 &&
      selections.every((s) => Array.isArray(s) && s.length > 0 && s.every(isIndex));
    return ok ? (selections as number[][]) : null;
  }
  const options = body?.options;
  if (Array.isArray(options) && options.length > 0 && options.every(isIndex)) {
    return (options as number[]).map((o) => [o]);
  }
  return null;
}

/**
 * `POST /questions/:id` — the notch answers a held AskUserQuestion here with
 * the chosen 0-based option indices per question. Same unguessable-UUID
 * capability model as /approvals.
 */
export function registerQuestionRoutes(app: FastifyInstance, hub: EventHub): void {
  app.post<{ Params: { id: string }; Body: { options?: unknown; selections?: unknown } }>(
    "/questions/:id",
    (request, reply) => {
      const selections = parseSelections(request.body);
      if (!selections) {
        return reply.code(400).send({
          error: "selections must be a non-empty array of non-empty arrays of non-negative integers",
        });
      }
      const resolved = hub.answerQuestion(request.params.id, selections);
      return reply.code(resolved ? 200 : 404).send({ ok: resolved });
    },
  );
}

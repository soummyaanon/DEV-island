import type { FastifyInstance } from "fastify";
import { randomUUID } from "node:crypto";
import type { IncomingHttpHeaders } from "node:http";
import type { PendingQuestion } from "@agent-island/shared";
import type { EventHub } from "../hub/event-hub";
import type { DaemonConfig } from "../config";
import { makeAuthGuard } from "./auth-guard";
import { ClaudeHookPayloadSchema } from "../adapters/claude/hook-payload";
import { mapClaudeHook, resolveHookEventName } from "../adapters/claude/event-mapper";
import { parseClaudeUsage } from "../adapters/claude/usage";

function header(headers: IncomingHttpHeaders, name: string): string | undefined {
  const raw = headers[name];
  const value = Array.isArray(raw) ? raw[0] : raw;
  const trimmed = value?.trim();
  // Drop empty or uninterpolated ("$VAR" when the env var was unset) values.
  if (!trimmed || trimmed.startsWith("$")) return undefined;
  return trimmed;
}

/** Parse the AskUserQuestion tool input into a PendingQuestion (defensively). */
function extractQuestion(input: Record<string, unknown> | undefined): PendingQuestion | null {
  const raw = Array.isArray(input?.questions)
    ? (input.questions as Array<Record<string, unknown>>)
    : [];
  const questions = raw
    .filter((q): q is Record<string, unknown> => typeof q?.question === "string")
    .map((q) => ({
      question: q.question as string,
      options: Array.isArray(q.options)
        ? (q.options as Array<Record<string, unknown>>)
            .map((o) => {
              if (typeof o?.label !== "string") return null;
              return typeof o.description === "string" && o.description.trim()
                ? `${o.label} — ${o.description}`
                : o.label;
            })
            .filter((label): label is string => label !== null)
        : [],
    }));
  if (questions.length === 0) return null;
  return { id: randomUUID(), questions, created_at: new Date().toISOString() };
}

/**
 * The questions the notch can answer remotely: every entry single-select with
 * at least one labelled option. Returns question texts + raw option labels
 * (the hook answer needs the label verbatim, not the display string), or null
 * when the tool call is not remotely answerable.
 */
function answerableQuestions(
  input: Record<string, unknown> | undefined,
): Array<{ question: string; labels: string[] }> | null {
  const raw = Array.isArray(input?.questions)
    ? (input.questions as Array<Record<string, unknown>>)
    : [];
  if (raw.length === 0) return null;
  const out: Array<{ question: string; labels: string[] }> = [];
  for (const q of raw) {
    if (typeof q?.question !== "string" || q.multiSelect === true) return null;
    const labels = Array.isArray(q.options)
      ? (q.options as Array<Record<string, unknown>>)
          .map((o) => (typeof o?.label === "string" ? o.label : null))
          .filter((label): label is string => label !== null)
      : [];
    if (labels.length === 0) return null;
    out.push({ question: q.question, labels });
  }
  return out;
}

/** ExitPlanMode carries the plan text in tool_input.plan; surface it for review. */
function extractPlan(input: Record<string, unknown> | undefined): string | undefined {
  const plan = input?.plan;
  return typeof plan === "string" && plan.trim() ? plan : undefined;
}

/**
 * A plausible macOS bundle id: reverse-DNS with at least one dot. Claude's
 * header interpolation only knows UPPERCASE env var names, so a deployed
 * "$__CFBundleIdentifier" template arrives as the literal tail
 * "undleIdentifier" — shaped like a word, never like a bundle id.
 */
const BUNDLE_ID = /^[\w-]+(\.[\w-]+)+$/;
/** A PID, as the bridge script sends `$PPID` — the agent process itself. */
const PID = /^\d{1,7}$/;

/** Terminal identity forwarded by the hook (via allowedEnvVars), for jump-to-terminal. */
function terminalMeta(headers: IncomingHttpHeaders): Record<string, string> {
  const meta: Record<string, string> = {};
  const term = header(headers, "x-term-program");
  const iterm = header(headers, "x-iterm-session-id");
  const termSession = header(headers, "x-term-session-id");
  const bundleId = header(headers, "x-app-bundle-id");
  const pid = header(headers, "x-agent-pid");
  if (term) meta.term_program = term;
  if (pid && PID.test(pid)) meta.pid = pid;
  if (iterm) meta.iterm_session_id = iterm;
  if (termSession) meta.term_session_id = termSession;
  if (bundleId && BUNDLE_ID.test(bundleId)) meta.app_bundle_id = bundleId;
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

  // Claude Code's status line JSON, forwarded by our status line script: the
  // subscription's 5-hour and weekly limits. Same empty-204 contract as hooks.
  app.post("/usage/claude", { preHandler: authGuard }, async (request, reply) => {
    const usage = parseClaudeUsage(request.body);
    if (usage) hub.setAgentUsage("claude-code", usage);
    return reply.code(204).send();
  });

  app.post<{ Params: { hookEvent: string } }>(
    "/events/claude/:hookEvent",
    { preHandler: authGuard },
    async (request, reply) => {
      const parsed = ClaudeHookPayloadSchema.safeParse(request.body);
      if (!parsed.success) {
        request.log.warn({ issues: parsed.error.issues }, "unparseable claude hook payload");
        return reply.code(204).send();
      }

      const payload = parsed.data;
      const eventName = resolveHookEventName(request.params.hookEvent, payload);
      // The session closed (exit, /clear, logout): it leaves the island now.
      if (eventName === "SessionEnd") {
        hub.endSession("claude-code", payload.session_id);
        return reply.code(204).send();
      }
      const fallbackCwd = hub.getSession("claude-code", payload.session_id)?.cwd ?? "(unknown)";

      const mapped = mapClaudeHook(eventName, payload, fallbackCwd);
      if (!mapped) {
        request.log.info(`ignoring unmapped claude hook: ${eventName}`);
        return reply.code(204).send();
      }

      const meta = terminalMeta(request.headers);
      if (payload.permission_mode) meta.permission_mode = payload.permission_mode;
      if (Object.keys(meta).length > 0) {
        const mappedMeta =
          mapped.detail?._meta && typeof mapped.detail._meta === "object"
            ? (mapped.detail._meta as Record<string, unknown>)
            : {};
        mapped.detail = { ...(mapped.detail ?? {}), _meta: { ...mappedMeta, ...meta } };
      }

      hub.ingest(mapped);

      // "Claude asks": surface AskUserQuestion in the notch while Claude waits;
      // any subsequent activity means it was answered (or abandoned) — clear it.
      const isQuestion =
        payload.tool_name === "AskUserQuestion" &&
        (eventName === "PermissionRequest" || eventName === "PreToolUse");
      if (isQuestion) {
        const question = extractQuestion(payload.tool_input);
        const answerable = answerableQuestions(payload.tool_input);

        // Hold the PermissionRequest open so clicks on the notch answer the
        // questions through the hook response — no terminal focus, no synthetic
        // keystrokes. Timeout → Claude's own picker takes over and the card
        // stays for jump-to-terminal.
        if (
          question &&
          answerable &&
          eventName === "PermissionRequest" &&
          hub.subscriberCount() > 0
        ) {
          const outcome = await hub.requestQuestionAnswer(
            "claude-code",
            payload.session_id,
            question,
          );
          const labels =
            outcome === "timeout" || outcome.length !== answerable.length
              ? null
              : answerable.map((q, i) => q.labels[outcome[i]]);
          if (labels && labels.every((label) => label !== undefined)) {
            const answers = Object.fromEntries(
              answerable.map((q, i) => [q.question, labels[i] as string]),
            );
            return reply.code(200).send({
              hookSpecificOutput: {
                hookEventName: "PermissionRequest",
                decision: {
                  behavior: "allow",
                  updatedInput: { ...(payload.tool_input ?? {}), answers },
                },
              },
            });
          }
          return reply.code(204).send();
        }

        hub.setPendingQuestion("claude-code", payload.session_id, question);
      } else if (eventName !== "Notification") {
        // Notification hooks ("waiting for your input", idle) fire WHILE the
        // question is still open — only real activity means it was answered.
        hub.setPendingQuestion("claude-code", payload.session_id, null);
      }

      // Interactive approval: hold the PermissionRequest open so the user can
      // decide from the notch. Only when a UI is connected — otherwise fall back
      // to Claude's own prompt immediately, so the session never hangs.
      if (eventName === "PermissionRequest" && !isQuestion && hub.subscriberCount() > 0) {
        const outcome = await hub.requestApproval(
          "claude-code",
          payload.session_id,
          payload.tool_name ?? "tool",
          payload.tool_input ?? {},
          extractPlan(payload.tool_input),
        );
        if (outcome === "allow" || outcome === "deny") {
          return reply.code(200).send({
            hookSpecificOutput: {
              hookEventName: "PermissionRequest",
              decision: { behavior: outcome },
            },
          });
        }
        // timeout → let Claude's normal permission flow take over
        return reply.code(204).send();
      }

      return reply.code(204).send();
    },
  );
}

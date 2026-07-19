import { randomUUID } from "node:crypto";
import type { EventInput, PendingQuestion } from "@agent-island/shared";

const AGENT = "codex" as const;

/**
 * One line of a Codex rollout log (`$CODEX_HOME/sessions/…/rollout-*.jsonl`).
 * Codex ships fast and the payload vocabulary grows, so everything is optional
 * and unknown entries map to null rather than errors.
 */
export interface CodexRolloutEntry {
  timestamp?: string;
  type?: string;
  payload?: Record<string, unknown>;
}

/**
 * Identity accumulated while reading one rollout file: `session_meta` names the
 * session, `turn_context` can move cwd/model per turn. The reader owns one
 * context per file and threads it through every `mapCodexEntry` call.
 */
export interface CodexSessionContext {
  sessionId: string | null;
  cwd: string | null;
  /** Persisted onto sessions via `detail._meta` (model, permission_mode). */
  meta: Record<string, string>;
}

export function createCodexContext(fallbackSessionId?: string): CodexSessionContext {
  return { sessionId: fallbackSessionId ?? null, cwd: null, meta: {} };
}

/** Parse one JSONL line defensively; anything but a JSON object is null. */
export function parseRolloutLine(line: string): CodexRolloutEntry | null {
  const trimmed = line.trim();
  if (!trimmed) return null;
  try {
    const parsed: unknown = JSON.parse(trimmed);
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return null;
    return parsed as CodexRolloutEntry;
  } catch {
    return null;
  }
}

function str(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value : undefined;
}

function truncate(s: string, max: number): string {
  const clean = s.replace(/\s+/g, " ").trim();
  return clean.length > max ? `${clean.slice(0, max - 1)}…` : clean;
}

function basename(p: string): string {
  return p.split("/").filter(Boolean).pop() ?? p;
}

/** Drop undefined values so `detail` stays clean. */
function prune(obj: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(obj)) {
    if (value !== undefined) out[key] = value;
  }
  return out;
}

/** `exec_command_end.parsed_cmd[0]` -> a human activity line. */
function describeParsedCmd(parsedCmd: unknown): string {
  const first = Array.isArray(parsedCmd) ? (parsedCmd[0] as Record<string, unknown>) : undefined;
  const name = str(first?.name);
  switch (str(first?.type)) {
    case "read":
      return name ? `Reading ${name}` : "Reading";
    case "list_files":
      return "Finding files";
    case "search":
      return name ? `Searching ${name}` : "Searching";
    default:
      return "working…";
  }
}

/** First file an apply_patch input touches, e.g. "*** Update File: a/b.ts". */
function firstPatchedFile(input: unknown): string | undefined {
  const match = typeof input === "string" ? input.match(/\*\*\* (?:Update|Add|Delete) File: (.+)/) : null;
  return match ? basename(match[1].trim()) : undefined;
}

function parseArguments(raw: unknown): Record<string, unknown> {
  if (typeof raw !== "string") return {};
  try {
    const parsed: unknown = JSON.parse(raw);
    return typeof parsed === "object" && parsed !== null ? (parsed as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

/**
 * Extract the question Codex is waiting on from a `request_user_input`
 * function call — same card the Claude AskUserQuestion flow feeds.
 */
export function extractCodexQuestion(entry: CodexRolloutEntry): PendingQuestion | null {
  const payload = entry.payload ?? {};
  if (entry.type !== "response_item" || payload.type !== "function_call") return null;
  if (payload.name !== "request_user_input") return null;
  const args = parseArguments(payload.arguments);
  const questions = Array.isArray(args.questions)
    ? (args.questions as Array<Record<string, unknown>>)
    : [];
  const first = questions[0];
  if (!first || typeof first.question !== "string") return null;
  const options = Array.isArray(first.options)
    ? (first.options as Array<Record<string, unknown>>)
        .map((o) => (typeof o?.label === "string" ? o.label : null))
        .filter((label): label is string => label !== null)
    : [];
  return {
    id: randomUUID(),
    question: first.question,
    options,
    created_at: new Date().toISOString(),
  };
}

/** A `response_item` tool call -> canonical tool activity (Claude-style titles). */
function mapToolCall(
  payload: Record<string, unknown>,
): { type: EventInput["type"]; title: string; requiresAction?: boolean } | null {
  const name = str(payload.name) ?? "tool";
  if (payload.type === "function_call") {
    switch (name) {
      case "exec_command": {
        const cmd = str(parseArguments(payload.arguments).cmd);
        return { type: "tool_use", title: cmd ? `Running ${truncate(cmd, 44)}` : "Running command" };
      }
      case "update_plan":
        return { type: "tool_use", title: "Updating the plan" };
      case "request_user_input":
        return { type: "notification", title: "Codex asks a question", requiresAction: true };
      case "write_stdin":
        return null; // keystrokes into an already-announced running command
      default:
        return { type: "tool_use", title: name };
    }
  }
  // custom_tool_call
  switch (name) {
    case "apply_patch": {
      const file = firstPatchedFile(payload.input);
      return { type: "tool_use", title: file ? `Editing ${file}` : "Applying a patch" };
    }
    case "exec": {
      // The JS-harness variant wraps the real command:
      // `const r = await tools.exec_command({"cmd":"...", ...})`
      const input = str(payload.input);
      const wrapped = input?.match(/"cmd"\s*:\s*("(?:[^"\\]|\\.)*")/);
      let cmd = input;
      if (wrapped) {
        try {
          cmd = JSON.parse(wrapped[1]) as string;
        } catch {
          /* fall back to the raw input */
        }
      }
      return { type: "tool_use", title: cmd ? `Running ${truncate(cmd, 44)}` : "Running command" };
    }
    default:
      return { type: "tool_use", title: name };
  }
}

/**
 * Pure mapper: one rollout entry -> one canonical EventInput, or null for the
 * (many) entry kinds we don't surface. Also folds `session_meta` /
 * `turn_context` into `ctx` — identity first, so even the session_meta event
 * itself is emitted with the right id/cwd.
 */
export function mapCodexEntry(
  entry: CodexRolloutEntry,
  ctx: CodexSessionContext,
): EventInput | null {
  const payload = entry.payload ?? {};

  if (entry.type === "session_meta") {
    ctx.sessionId = str(payload.session_id) ?? str(payload.id) ?? ctx.sessionId;
    ctx.cwd = str(payload.cwd) ?? ctx.cwd;
    return finish(ctx, {
      type: "session_started",
      title: "session started",
      detail: prune({
        source: str(payload.source) ?? str(payload.originator),
        cli_version: str(payload.cli_version),
      }),
    });
  }

  if (entry.type === "turn_context") {
    ctx.cwd = str(payload.cwd) ?? ctx.cwd;
    const model = str(payload.model);
    const approval = str(payload.approval_policy);
    if (model) ctx.meta.model = model;
    if (approval) ctx.meta.permission_mode = approval;
    return null;
  }

  if (entry.type === "event_msg") {
    switch (payload.type) {
      case "task_started":
        return finish(ctx, { type: "task_progress", title: "working…" });
      case "task_complete": {
        const message = str(payload.last_agent_message);
        return finish(ctx, {
          type: "session_ended",
          title: message ? truncate(message, 64) : "finished responding",
          detail: prune({ last_agent_message: message ? truncate(message, 240) : undefined }),
        });
      }
      case "turn_aborted":
        return finish(ctx, {
          type: "notification",
          title: "turn interrupted",
          detail: prune({ reason: str(payload.reason) }),
        });
      case "error":
      case "stream_error":
        return finish(ctx, {
          type: "error",
          title: truncate(str(payload.message) ?? "error", 64),
        });
      case "exec_command_end":
        return finish(ctx, {
          type: "task_progress",
          title: describeParsedCmd(payload.parsed_cmd),
          detail: prune({
            exit_code: typeof payload.exit_code === "number" ? payload.exit_code : undefined,
          }),
        });
      case "patch_apply_end": {
        const changes =
          typeof payload.changes === "object" && payload.changes !== null
            ? Object.keys(payload.changes)
            : [];
        const title =
          payload.success === false
            ? "patch failed"
            : `Edited ${changes.length} file${changes.length === 1 ? "" : "s"}`;
        return finish(ctx, {
          type: "task_progress",
          title,
          detail: prune({ files: changes.length > 0 ? changes.slice(0, 5).map(basename) : undefined }),
        });
      }
      case "mcp_tool_call_end": {
        const invocation = (payload.invocation ?? {}) as Record<string, unknown>;
        const server = str(invocation.server);
        const tool = str(invocation.tool);
        return finish(ctx, {
          type: "task_progress",
          title: server && tool ? truncate(`${server}.${tool}`, 44) : "working…",
        });
      }
      case "web_search_end":
        return finish(ctx, {
          type: "task_progress",
          title: "Searching the web",
          detail: prune({ query: str(payload.query) ? truncate(payload.query as string, 80) : undefined }),
        });
      default:
        return null; // token_count, agent/user messages, settings, …
    }
  }

  if (entry.type === "response_item") {
    if (payload.type !== "function_call" && payload.type !== "custom_tool_call") return null;
    const mapped = mapToolCall(payload);
    if (!mapped) return null;
    return finish(ctx, {
      type: mapped.type,
      title: mapped.title,
      detail: prune({ tool_name: str(payload.name) }),
      requires_action: mapped.requiresAction,
    });
  }

  return null; // world_state and anything newer
}

/** Stamp identity + accumulated meta onto a mapped event; null without a session id. */
function finish(
  ctx: CodexSessionContext,
  event: { type: EventInput["type"]; title: string; detail?: Record<string, unknown>; requires_action?: boolean },
): EventInput | null {
  if (!ctx.sessionId) return null;
  const detail = { ...(event.detail ?? {}) };
  if (Object.keys(ctx.meta).length > 0) detail._meta = { ...ctx.meta };
  return {
    agent: AGENT,
    session_id: ctx.sessionId,
    cwd: ctx.cwd ?? "(unknown)",
    type: event.type,
    title: event.title,
    detail,
    requires_action: event.requires_action ?? false,
  };
}

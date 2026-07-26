import type { EventInput } from "@agent-island/shared";

const AGENT = "cursor" as const;

/** Cursor's desktop bundle — so session rows can show the host without guessing. */
const CURSOR_BUNDLE_ID = "com.todesktop.230313mzl4w4u92";

/**
 * Tolerant view of a Cursor hook payload (~/.cursor/hooks.json commands get
 * this JSON on stdin; our bridge script forwards it verbatim). Cursor ships
 * fast, so every field is optional and unknown events map to null.
 */
export interface CursorHookPayload {
  conversation_id?: unknown;
  generation_id?: unknown;
  session_id?: unknown;
  hook_event_name?: unknown;
  workspace_roots?: unknown;
  cwd?: unknown;
  command?: unknown;
  file_path?: unknown;
  server_name?: unknown;
  tool_name?: unknown;
  tool_input?: unknown;
  tool_output?: unknown;
  tool_use_id?: unknown;
  server?: unknown;
  tool?: unknown;
  text?: unknown;
  prompt?: unknown;
  status?: unknown;
  reason?: unknown;
  model?: unknown;
  model_id?: unknown;
  composer_mode?: unknown;
  is_background_agent?: unknown;
  task?: unknown;
  description?: unknown;
  summary?: unknown;
  subagent_type?: unknown;
  error_message?: unknown;
  failure_type?: unknown;
  is_interrupt?: unknown;
  agent_message?: unknown;
  trigger?: unknown;
  context_usage_percent?: unknown;
  final_status?: unknown;
  [key: string]: unknown;
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

function prune(obj: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(obj)) {
    if (value !== undefined) out[key] = value;
  }
  return out;
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  if (value && typeof value === "object" && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }
  if (typeof value === "string" && value.trim()) {
    try {
      const parsed: unknown = JSON.parse(value);
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        return parsed as Record<string, unknown>;
      }
    } catch {
      /* tool_input sometimes arrives as a non-JSON string — ignore */
    }
  }
  return undefined;
}

/** A human "what it's doing right now" line from tool name + input. */
function describeAction(tool: string | undefined, input: Record<string, unknown> | undefined): string {
  const t = tool ?? "tool";
  const field = (k: string): string | undefined =>
    typeof input?.[k] === "string" ? (input[k] as string) : undefined;

  switch (t) {
    case "Shell": {
      const cmd = field("command");
      return cmd ? `Running ${truncate(cmd, 44)}` : "Running command";
    }
    case "Read": {
      const f = field("file_path") ?? field("path");
      return f ? `Reading ${basename(f)}` : "Reading";
    }
    case "Edit":
    case "Write":
    case "Delete": {
      const f = field("file_path") ?? field("path");
      if (t === "Delete") return f ? `Deleting ${basename(f)}` : "Deleting";
      return f ? `Editing ${basename(f)}` : "Editing";
    }
    case "Grep": {
      const p = field("pattern");
      return p ? `Searching for ${truncate(p, 22)}` : "Searching";
    }
    case "Glob":
      return "Finding files";
    case "Task": {
      const desc = field("description") ?? field("prompt");
      return desc ? `Delegating: ${truncate(desc, 36)}` : "Delegating to a subagent";
    }
    case "WebFetch":
    case "WebSearch":
      return "Searching the web";
    case "TodoWrite":
      return "Updating the plan";
    default:
      if (t.startsWith("MCP:") || t.includes(".")) return truncate(t.replace(/^MCP:/, ""), 44);
      return truncate(t, 44);
  }
}

function sessionKey(payload: CursorHookPayload): string | undefined {
  return str(payload.conversation_id) ?? str(payload.session_id) ?? str(payload.generation_id);
}

function resolveCwd(payload: CursorHookPayload, fallbackCwd: string): string {
  const fromField = str(payload.cwd);
  if (fromField) return fromField;
  const roots = Array.isArray(payload.workspace_roots) ? payload.workspace_roots : [];
  return str(roots[0]) ?? fallbackCwd;
}

function metaFrom(payload: CursorHookPayload, extra: Record<string, unknown> = {}): Record<string, unknown> {
  const composerMode = str(payload.composer_mode);
  return prune({
    model: str(payload.model) ?? str(payload.model_id),
    app_bundle_id: CURSOR_BUNDLE_ID,
    // SessionRow already renders permission_mode — reuse it for Cursor's composer mode.
    permission_mode: composerMode,
    composer_mode: composerMode,
    is_background_agent:
      typeof payload.is_background_agent === "boolean" ? payload.is_background_agent : undefined,
    ...extra,
  });
}

/** Prefer the payload's own event name; fall back to the URL slug. */
export function resolveCursorEventName(slug: string, payload: CursorHookPayload): string {
  return str(payload.hook_event_name) ?? slug;
}

/**
 * Pure mapper: one Cursor hook payload -> one canonical EventInput, or null.
 * Sessions key on conversation_id / session_id; cwd prefers payload.cwd, then
 * workspace_roots, then the session's already-known directory.
 */
export function mapCursorHook(
  eventName: string,
  payload: CursorHookPayload,
  fallbackCwd: string,
): EventInput | null {
  const sessionId = sessionKey(payload);
  if (!sessionId) return null;

  const cwd = resolveCwd(payload, fallbackCwd);
  const base = { agent: AGENT, session_id: sessionId, cwd };
  const done = (
    type: EventInput["type"],
    title: string,
    detail: Record<string, unknown> = {},
    requires_action = false,
  ): EventInput => ({
    ...base,
    type,
    title,
    detail: prune({ ...detail, _meta: metaFrom(payload) }),
    requires_action,
  });

  switch (eventName) {
    case "sessionStart": {
      const mode = str(payload.composer_mode);
      return done(
        "session_started",
        mode ? `session ${mode}` : "session started",
        prune({
          composer_mode: mode,
          is_background_agent:
            typeof payload.is_background_agent === "boolean"
              ? payload.is_background_agent
              : undefined,
        }),
      );
    }

    case "beforeSubmitPrompt": {
      const prompt = str(payload.prompt);
      return done(
        "task_progress",
        prompt ? truncate(prompt, 48) : "working…",
        prune({ prompt: prompt ? truncate(prompt, 120) : undefined }),
      );
    }

    case "preToolUse": {
      const tool = str(payload.tool_name);
      const input = asRecord(payload.tool_input);
      const agentMsg = str(payload.agent_message);
      return done(
        "tool_use",
        agentMsg ? truncate(agentMsg, 48) : describeAction(tool, input),
        prune({ tool_name: tool, tool_input: input, tool_use_id: str(payload.tool_use_id) }),
      );
    }

    case "postToolUse":
      return done("task_progress", "working…", {
        tool_name: str(payload.tool_name),
        tool_use_id: str(payload.tool_use_id),
      });

    case "postToolUseFailure": {
      if (payload.is_interrupt === true) {
        return done("task_progress", "interrupted", {
          tool_name: str(payload.tool_name),
          failure_type: str(payload.failure_type),
        });
      }
      const err = str(payload.error_message);
      return done("error", err ? truncate(err, 48) : "tool failed", {
        tool_name: str(payload.tool_name),
        failure_type: str(payload.failure_type),
        error_message: err ? truncate(err, 200) : undefined,
      });
    }

    case "beforeShellExecution": {
      const cmd = str(payload.command);
      return done("tool_use", cmd ? `Running ${truncate(cmd, 44)}` : "Running command", {
        cmd: cmd ? truncate(cmd, 200) : undefined,
      });
    }

    case "afterShellExecution":
    case "afterMCPExecution":
      return done("task_progress", "working…");

    case "beforeReadFile": {
      const file = str(payload.file_path);
      return done("tool_use", file ? `Reading ${basename(file)}` : "Reading");
    }

    case "afterFileEdit": {
      const file = str(payload.file_path);
      return done("tool_use", file ? `Editing ${basename(file)}` : "Editing", {
        file: file ? basename(file) : undefined,
      });
    }

    case "beforeMCPExecution": {
      const server = str(payload.server_name) ?? str(payload.server);
      const tool = str(payload.tool_name) ?? str(payload.tool);
      const input = asRecord(payload.tool_input);
      return done(
        "tool_use",
        server && tool
          ? truncate(`${server}.${tool}`, 44)
          : tool
            ? truncate(tool, 44)
            : "Calling a tool",
        prune({ server, tool_name: tool, tool_input: input }),
      );
    }

    case "afterAgentThought":
      return done("task_progress", "thinking…", {
        duration_ms: typeof payload.duration_ms === "number" ? payload.duration_ms : undefined,
      });

    case "afterAgentResponse":
      return done("task_progress", "working…");

    case "subagentStart": {
      const task = str(payload.task) ?? str(payload.description);
      const kind = str(payload.subagent_type);
      return done(
        "tool_use",
        task ? `Delegating: ${truncate(task, 36)}` : "Delegating to a subagent",
        prune({ subagent_type: kind, task: task ? truncate(task, 120) : undefined }),
      );
    }

    case "subagentStop": {
      const status = str(payload.status) ?? "completed";
      const summary = str(payload.summary) ?? str(payload.description) ?? str(payload.task);
      if (status === "error") {
        return done("error", summary ? truncate(summary, 48) : "subagent failed", {
          status,
          subagent_type: str(payload.subagent_type),
        });
      }
      return done(
        "task_progress",
        status === "aborted"
          ? "subagent aborted"
          : summary
            ? truncate(summary, 48)
            : "working…",
        prune({ status, subagent_type: str(payload.subagent_type) }),
      );
    }

    case "preCompact": {
      const pct =
        typeof payload.context_usage_percent === "number"
          ? Math.round(payload.context_usage_percent)
          : undefined;
      return done(
        "task_progress",
        pct !== undefined ? `compacting context (${pct}%)` : "compacting context…",
        prune({
          trigger: str(payload.trigger),
          context_usage_percent: pct,
        }),
      );
    }

    case "stop": {
      const status = str(payload.status) ?? "completed";
      if (status === "error") {
        return done("error", "agent error", { status });
      }
      return done(
        "session_ended",
        status === "aborted" ? "aborted" : "finished responding",
        { status },
      );
    }

    case "sessionEnd": {
      const reason = str(payload.reason) ?? str(payload.final_status) ?? "completed";
      if (reason === "error") {
        const err = str(payload.error_message);
        return done("error", err ? truncate(err, 48) : "session error", {
          reason,
          error_message: err ? truncate(err, 200) : undefined,
        });
      }
      return done(
        "session_ended",
        reason === "aborted" || reason === "user_close" || reason === "window_close"
          ? "session closed"
          : "finished responding",
        prune({ reason }),
      );
    }

    default:
      return null;
  }
}

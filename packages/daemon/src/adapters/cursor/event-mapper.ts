import type { EventInput } from "@agent-island/shared";

const AGENT = "cursor" as const;

/**
 * Tolerant view of a Cursor hook payload (~/.cursor/hooks.json commands get
 * this JSON on stdin; our bridge script forwards it verbatim). Cursor ships
 * fast, so every field is optional and unknown events map to null.
 */
export interface CursorHookPayload {
  conversation_id?: unknown;
  generation_id?: unknown;
  hook_event_name?: unknown;
  workspace_roots?: unknown;
  command?: unknown;
  file_path?: unknown;
  server_name?: unknown;
  tool_name?: unknown;
  server?: unknown;
  tool?: unknown;
  text?: unknown;
  prompt?: unknown;
  status?: unknown;
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

/** Prefer the payload's own event name; fall back to the URL slug. */
export function resolveCursorEventName(slug: string, payload: CursorHookPayload): string {
  return str(payload.hook_event_name) ?? slug;
}

/**
 * Pure mapper: one Cursor hook payload -> one canonical EventInput, or null.
 * Sessions key on conversation_id; cwd comes from workspace_roots (falling
 * back to the session's already-known directory).
 */
export function mapCursorHook(
  eventName: string,
  payload: CursorHookPayload,
  fallbackCwd: string,
): EventInput | null {
  const sessionId = str(payload.conversation_id) ?? str(payload.generation_id);
  if (!sessionId) return null;

  const roots = Array.isArray(payload.workspace_roots) ? payload.workspace_roots : [];
  const cwd = str(roots[0]) ?? fallbackCwd;
  const base = { agent: AGENT, session_id: sessionId, cwd };
  const done = (
    type: EventInput["type"],
    title: string,
    detail: Record<string, unknown> = {},
  ): EventInput => ({ ...base, type, title, detail: prune(detail), requires_action: false });

  switch (eventName) {
    case "beforeSubmitPrompt":
      return done("task_progress", "working…", {
        prompt: str(payload.prompt) ? truncate(payload.prompt as string, 120) : undefined,
      });
    case "beforeShellExecution": {
      const cmd = str(payload.command);
      return done("tool_use", cmd ? `Running ${truncate(cmd, 44)}` : "Running command", {
        cmd: cmd ? truncate(cmd, 200) : undefined,
      });
    }
    case "afterShellExecution":
    case "afterMCPExecution":
    case "subagentStop":
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
      return done("tool_use", server && tool ? truncate(`${server}.${tool}`, 44) : "Calling a tool");
    }
    case "afterAgentThought":
      return done("task_progress", "thinking…");
    case "afterAgentResponse":
      return done("task_progress", "working…");
    case "subagentStart":
      return done("tool_use", "Delegating to a subagent");
    case "stop":
      return done("session_ended", "finished responding", { status: str(payload.status) });
    default:
      return null;
  }
}

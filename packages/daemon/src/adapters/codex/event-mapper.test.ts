import { describe, expect, it } from "vitest";
import {
  createCodexContext,
  extractCodexQuestion,
  mapCodexEntry,
  parseRolloutLine,
  type CodexRolloutEntry,
} from "./event-mapper";

/** Shorthand: build an entry the way rollout files store them. */
function entry(type: string, payload: Record<string, unknown>): CodexRolloutEntry {
  return { timestamp: "2026-07-19T06:27:24.046Z", type, payload };
}

const SESSION_META = entry("session_meta", {
  session_id: "019f790e-889e-7370-a86b-b7e9b65e13e8",
  cwd: "/Users/me/proj",
  originator: "codex-tui",
  cli_version: "0.144.6",
  source: "cli",
});

describe("parseRolloutLine", () => {
  it("parses a JSONL line", () => {
    const parsed = parseRolloutLine('{"type":"event_msg","payload":{"type":"task_started"}}');
    expect(parsed).toEqual({ type: "event_msg", payload: { type: "task_started" } });
  });

  it("returns null for malformed JSON, blanks, and non-objects", () => {
    expect(parseRolloutLine("{oops")).toBeNull();
    expect(parseRolloutLine("")).toBeNull();
    expect(parseRolloutLine("   ")).toBeNull();
    expect(parseRolloutLine('"just a string"')).toBeNull();
    expect(parseRolloutLine("42")).toBeNull();
  });
});

describe("mapCodexEntry — session identity", () => {
  it("maps session_meta to session_started and learns id + cwd", () => {
    const ctx = createCodexContext();
    const mapped = mapCodexEntry(SESSION_META, ctx);
    expect(mapped).toMatchObject({
      agent: "codex",
      session_id: "019f790e-889e-7370-a86b-b7e9b65e13e8",
      cwd: "/Users/me/proj",
      type: "session_started",
      title: "session started",
      requires_action: false,
    });
    expect(ctx.sessionId).toBe("019f790e-889e-7370-a86b-b7e9b65e13e8");
    expect(ctx.cwd).toBe("/Users/me/proj");
  });

  it("falls back to the id field when session_id is absent", () => {
    const ctx = createCodexContext();
    mapCodexEntry(entry("session_meta", { id: "abc", cwd: "/x" }), ctx);
    expect(ctx.sessionId).toBe("abc");
  });

  it("uses the filename-derived fallback session id until session_meta arrives", () => {
    const ctx = createCodexContext("file-uuid");
    const mapped = mapCodexEntry(entry("event_msg", { type: "task_started" }), ctx);
    expect(mapped?.session_id).toBe("file-uuid");
    expect(mapped?.cwd).toBe("(unknown)");
  });

  it("emits nothing at all when there is no session id from any source", () => {
    const ctx = createCodexContext();
    expect(mapCodexEntry(entry("event_msg", { type: "task_started" }), ctx)).toBeNull();
  });

  it("turn_context updates cwd and surfaces model/approval_policy as _meta", () => {
    const ctx = createCodexContext();
    mapCodexEntry(SESSION_META, ctx);
    const nothing = mapCodexEntry(
      entry("turn_context", {
        cwd: "/Users/me/other",
        model: "gpt-5.4",
        approval_policy: "on-request",
      }),
      ctx,
    );
    expect(nothing).toBeNull();
    const next = mapCodexEntry(entry("event_msg", { type: "task_started" }), ctx);
    expect(next?.cwd).toBe("/Users/me/other");
    expect(next?.detail?._meta).toMatchObject({
      model: "gpt-5.4",
      permission_mode: "on-request",
    });
  });
});

describe("mapCodexEntry — lifecycle", () => {
  function ctxWithSession() {
    const ctx = createCodexContext();
    mapCodexEntry(SESSION_META, ctx);
    return ctx;
  }

  it("task_started means working", () => {
    const mapped = mapCodexEntry(entry("event_msg", { type: "task_started" }), ctxWithSession());
    expect(mapped).toMatchObject({ type: "task_progress", title: "working…" });
  });

  it("task_complete becomes session_ended titled from last_agent_message, truncated", () => {
    const long = "Implemented the whole feature. ".repeat(10);
    const mapped = mapCodexEntry(
      entry("event_msg", { type: "task_complete", last_agent_message: long }),
      ctxWithSession(),
    );
    expect(mapped?.type).toBe("session_ended");
    expect(mapped?.title.length).toBeLessThanOrEqual(64);
    expect(mapped?.title.endsWith("…")).toBe(true);
  });

  it("task_complete without a message falls back to a stock title", () => {
    const mapped = mapCodexEntry(entry("event_msg", { type: "task_complete" }), ctxWithSession());
    expect(mapped?.title).toBe("finished responding");
  });

  it("turn_aborted maps to a non-attention notification (idle)", () => {
    const mapped = mapCodexEntry(
      entry("event_msg", { type: "turn_aborted", reason: "interrupted" }),
      ctxWithSession(),
    );
    expect(mapped).toMatchObject({
      type: "notification",
      title: "turn interrupted",
      requires_action: false,
    });
  });

  it("error events map to error", () => {
    const mapped = mapCodexEntry(
      entry("event_msg", { type: "error", message: "stream disconnected" }),
      ctxWithSession(),
    );
    expect(mapped).toMatchObject({ type: "error", title: "stream disconnected" });
  });
});

describe("mapCodexEntry — tool activity titles", () => {
  function ctxWithSession() {
    const ctx = createCodexContext();
    mapCodexEntry(SESSION_META, ctx);
    return ctx;
  }

  it("exec_command function_call reads the cmd out of the arguments JSON", () => {
    const mapped = mapCodexEntry(
      entry("response_item", {
        type: "function_call",
        name: "exec_command",
        arguments: '{"cmd":"pnpm test --run","workdir":"/Users/me/proj"}',
      }),
      ctxWithSession(),
    );
    expect(mapped).toMatchObject({ type: "tool_use", title: "Running pnpm test --run" });
  });

  it("apply_patch custom_tool_call names the first touched file", () => {
    const mapped = mapCodexEntry(
      entry("response_item", {
        type: "custom_tool_call",
        name: "apply_patch",
        input: "*** Begin Patch\n*** Update File: src/deep/dir/thing.ts\n+x\n*** End Patch",
      }),
      ctxWithSession(),
    );
    expect(mapped).toMatchObject({ type: "tool_use", title: "Editing thing.ts" });
  });

  it("custom exec unwraps the cmd from the JS-harness wrapper", () => {
    const mapped = mapCodexEntry(
      entry("response_item", {
        type: "custom_tool_call",
        name: "exec",
        input:
          'const r = await tools.exec_command({"cmd":"rg -n \\"crab|codex\\" .","workdir":"/x","yield_time_ms":1000})',
      }),
      ctxWithSession(),
    );
    expect(mapped).toMatchObject({ type: "tool_use", title: 'Running rg -n "crab|codex" .' });
  });

  it("update_plan reads as planning", () => {
    const mapped = mapCodexEntry(
      entry("response_item", { type: "function_call", name: "update_plan", arguments: "{}" }),
      ctxWithSession(),
    );
    expect(mapped).toMatchObject({ type: "tool_use", title: "Updating the plan" });
  });

  it("request_user_input is an attention notification", () => {
    const mapped = mapCodexEntry(
      entry("response_item", {
        type: "function_call",
        name: "request_user_input",
        arguments: '{"questions":[{"question":"Which one?","options":[{"label":"A"}]}]}',
      }),
      ctxWithSession(),
    );
    expect(mapped).toMatchObject({
      type: "notification",
      title: "Codex asks a question",
      requires_action: true,
    });
  });

  it("exec_command_end derives a friendly title from parsed_cmd", () => {
    const ctx = ctxWithSession();
    const read = mapCodexEntry(
      entry("event_msg", {
        type: "exec_command_end",
        parsed_cmd: [{ type: "read", name: "STATUS.md" }],
        stdout: "x".repeat(10_000),
      }),
      ctx,
    );
    expect(read).toMatchObject({ type: "task_progress", title: "Reading STATUS.md" });
    // Big command output never rides along into detail.
    expect(JSON.stringify(read?.detail).length).toBeLessThan(1_000);

    const search = mapCodexEntry(
      entry("event_msg", { type: "exec_command_end", parsed_cmd: [{ type: "search" }] }),
      ctx,
    );
    expect(search?.title).toBe("Searching");

    const unknown = mapCodexEntry(
      entry("event_msg", { type: "exec_command_end", parsed_cmd: [{ type: "unknown" }] }),
      ctx,
    );
    expect(unknown?.title).toBe("working…");
  });

  it("patch_apply_end counts the changed files", () => {
    const mapped = mapCodexEntry(
      entry("event_msg", {
        type: "patch_apply_end",
        success: true,
        changes: { "/a/b.ts": {}, "/a/c.ts": {} },
      }),
      ctxWithSession(),
    );
    expect(mapped).toMatchObject({ type: "task_progress", title: "Edited 2 files" });
  });

  it("mcp and web-search ends surface as progress", () => {
    const ctx = ctxWithSession();
    const mcp = mapCodexEntry(
      entry("event_msg", {
        type: "mcp_tool_call_end",
        invocation: { server: "vaani", tool: "list_agents" },
      }),
      ctx,
    );
    expect(mcp?.title).toBe("vaani.list_agents");
    const web = mapCodexEntry(entry("event_msg", { type: "web_search_end", query: "x" }), ctx);
    expect(web?.title).toBe("Searching the web");
  });
});

describe("mapCodexEntry — noise is ignored", () => {
  it("returns null for token_count, messages, reasoning, outputs and unknowns", () => {
    const ctx = createCodexContext();
    mapCodexEntry(SESSION_META, ctx);
    const ignored = [
      entry("event_msg", { type: "token_count", rate_limits: {} }),
      entry("event_msg", { type: "agent_message", message: "hi" }),
      entry("event_msg", { type: "user_message", message: "yo" }),
      entry("response_item", { type: "reasoning" }),
      entry("response_item", { type: "message" }),
      entry("response_item", { type: "function_call_output", call_id: "c1" }),
      entry("response_item", { type: "custom_tool_call_output", call_id: "c2" }),
      entry("response_item", { type: "function_call", name: "write_stdin", arguments: "{}" }),
      entry("world_state", {}),
      entry("event_msg", { type: "brand_new_thing" }),
      { type: undefined, payload: undefined },
    ];
    for (const e of ignored) expect(mapCodexEntry(e, ctx)).toBeNull();
  });
});

describe("extractCodexQuestion", () => {
  it("parses questions/options from request_user_input arguments", () => {
    const q = extractCodexQuestion(
      entry("response_item", {
        type: "function_call",
        name: "request_user_input",
        arguments:
          '{"questions":[{"question":"Deploy now?","options":[{"label":"Yes"},{"label":"No"}]}]}',
      }),
    );
    expect(q).toMatchObject({ question: "Deploy now?", options: ["Yes", "No"] });
    expect(q?.id).toBeTruthy();
    expect(q?.created_at).toBeTruthy();
  });

  it("returns null for anything else or malformed arguments", () => {
    expect(extractCodexQuestion(entry("event_msg", { type: "task_started" }))).toBeNull();
    expect(
      extractCodexQuestion(
        entry("response_item", { type: "function_call", name: "request_user_input", arguments: "{nope" }),
      ),
    ).toBeNull();
    expect(
      extractCodexQuestion(
        entry("response_item", { type: "function_call", name: "request_user_input", arguments: "{}" }),
      ),
    ).toBeNull();
  });
});

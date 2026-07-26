import { describe, expect, it } from "vitest";
import { mapCursorHook, resolveCursorEventName } from "./event-mapper";

const BASE = { conversation_id: "conv-1", workspace_roots: ["/Users/me/proj"] };

describe("resolveCursorEventName", () => {
  it("prefers the payload's hook_event_name, falling back to the slug", () => {
    expect(resolveCursorEventName("stop", { hook_event_name: "afterFileEdit" })).toBe(
      "afterFileEdit",
    );
    expect(resolveCursorEventName("stop", {})).toBe("stop");
  });
});

describe("mapCursorHook", () => {
  it("keys the session on conversation_id and takes cwd from workspace_roots", () => {
    const mapped = mapCursorHook("beforeSubmitPrompt", BASE, "(unknown)");
    expect(mapped).toMatchObject({
      agent: "cursor",
      session_id: "conv-1",
      cwd: "/Users/me/proj",
      type: "task_progress",
      title: "working…",
    });
    expect(mapped?.detail?._meta).toMatchObject({
      app_bundle_id: "com.todesktop.230313mzl4w4u92",
    });
  });

  it("falls back to session_id then generation_id, and prefers payload.cwd", () => {
    expect(
      mapCursorHook("sessionStart", { session_id: "sess-9", cwd: "/from/payload" }, "/known"),
    ).toMatchObject({ session_id: "sess-9", cwd: "/from/payload", type: "session_started" });

    expect(mapCursorHook("stop", { generation_id: "gen-9" }, "/known/dir")).toMatchObject({
      session_id: "gen-9",
      cwd: "/known/dir",
    });
  });

  it("drops payloads with no usable session id", () => {
    expect(mapCursorHook("stop", {}, "(unknown)")).toBeNull();
  });

  it("maps sessionStart with composer mode and model meta", () => {
    expect(
      mapCursorHook(
        "sessionStart",
        { ...BASE, composer_mode: "agent", model: "claude-opus-4", is_background_agent: false },
        "x",
      ),
    ).toMatchObject({
      type: "session_started",
      title: "session agent",
      detail: {
        composer_mode: "agent",
        _meta: {
          model: "claude-opus-4",
          permission_mode: "agent",
          app_bundle_id: "com.todesktop.230313mzl4w4u92",
        },
      },
    });
  });

  it("maps beforeSubmitPrompt to a truncated prompt title when present", () => {
    expect(
      mapCursorHook("beforeSubmitPrompt", { ...BASE, prompt: "fix the flaky test" }, "x"),
    ).toMatchObject({ type: "task_progress", title: "fix the flaky test" });
  });

  it("maps preToolUse with Claude-like activity titles", () => {
    expect(
      mapCursorHook(
        "preToolUse",
        { ...BASE, tool_name: "Shell", tool_input: { command: "pnpm test --run" } },
        "x",
      ),
    ).toMatchObject({ type: "tool_use", title: "Running pnpm test --run" });

    expect(
      mapCursorHook(
        "preToolUse",
        { ...BASE, tool_name: "Grep", tool_input: { pattern: "sessionKey" } },
        "x",
      ),
    ).toMatchObject({ type: "tool_use", title: "Searching for sessionKey" });

    expect(
      mapCursorHook(
        "preToolUse",
        { ...BASE, tool_name: "Write", tool_input: { file_path: "/a/b/index.ts" } },
        "x",
      ),
    ).toMatchObject({ type: "tool_use", title: "Editing index.ts" });

    expect(
      mapCursorHook(
        "preToolUse",
        { ...BASE, tool_name: "Task", tool_input: { description: "explore auth" } },
        "x",
      ),
    ).toMatchObject({ type: "tool_use", title: "Delegating: explore auth" });
  });

  it("maps postToolUseFailure to error, or interrupted when cancelled", () => {
    expect(
      mapCursorHook(
        "postToolUseFailure",
        { ...BASE, tool_name: "Shell", error_message: "timed out", failure_type: "timeout" },
        "x",
      ),
    ).toMatchObject({ type: "error", title: "timed out" });

    expect(
      mapCursorHook(
        "postToolUseFailure",
        { ...BASE, is_interrupt: true, failure_type: "error" },
        "x",
      ),
    ).toMatchObject({ type: "task_progress", title: "interrupted" });
  });

  it("maps specialized tool hooks with friendly titles", () => {
    expect(
      mapCursorHook("beforeShellExecution", { ...BASE, command: "pnpm test --run" }, "x"),
    ).toMatchObject({ type: "tool_use", title: "Running pnpm test --run" });

    expect(
      mapCursorHook("beforeReadFile", { ...BASE, file_path: "/a/b/notes.md" }, "x"),
    ).toMatchObject({ type: "tool_use", title: "Reading notes.md" });

    expect(
      mapCursorHook("afterFileEdit", { ...BASE, file_path: "/a/b/index.ts" }, "x"),
    ).toMatchObject({ type: "tool_use", title: "Editing index.ts" });

    expect(
      mapCursorHook(
        "beforeMCPExecution",
        { ...BASE, server_name: "linear", tool_name: "create_issue" },
        "x",
      ),
    ).toMatchObject({ type: "tool_use", title: "linear.create_issue" });
  });

  it("maps subagent lifecycle with task text and failure status", () => {
    expect(
      mapCursorHook(
        "subagentStart",
        { ...BASE, task: "Explore the authentication flow", subagent_type: "explore" },
        "x",
      ),
    ).toMatchObject({
      type: "tool_use",
      title: "Delegating: Explore the authentication flow",
    });

    expect(
      mapCursorHook("subagentStop", { ...BASE, status: "error", summary: "could not find auth" }, "x"),
    ).toMatchObject({ type: "error", title: "could not find auth" });

    expect(
      mapCursorHook("subagentStop", { ...BASE, status: "completed", summary: "found 3 files" }, "x"),
    ).toMatchObject({ type: "task_progress", title: "found 3 files" });
  });

  it("maps preCompact and lifecycle stop/sessionEnd", () => {
    expect(
      mapCursorHook("preCompact", { ...BASE, context_usage_percent: 85.4, trigger: "auto" }, "x"),
    ).toMatchObject({ type: "task_progress", title: "compacting context (85%)" });

    expect(mapCursorHook("afterAgentThought", BASE, "x")).toMatchObject({ title: "thinking…" });
    expect(mapCursorHook("afterShellExecution", BASE, "x")?.type).toBe("task_progress");

    expect(mapCursorHook("stop", { ...BASE, status: "completed" }, "x")).toMatchObject({
      type: "session_ended",
      title: "finished responding",
    });
    expect(mapCursorHook("stop", { ...BASE, status: "error" }, "x")).toMatchObject({
      type: "error",
      title: "agent error",
    });
    expect(mapCursorHook("sessionEnd", { ...BASE, reason: "user_close" }, "x")).toMatchObject({
      type: "session_ended",
      title: "session closed",
    });
  });

  it("returns null for unknown hook events", () => {
    expect(mapCursorHook("someFutureHook", BASE, "x")).toBeNull();
  });
});

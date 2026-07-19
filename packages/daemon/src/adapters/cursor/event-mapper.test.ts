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
  });

  it("falls back to generation_id then to the known cwd", () => {
    const mapped = mapCursorHook("stop", { generation_id: "gen-9" }, "/known/dir");
    expect(mapped).toMatchObject({ session_id: "gen-9", cwd: "/known/dir" });
  });

  it("drops payloads with no usable session id", () => {
    expect(mapCursorHook("stop", {}, "(unknown)")).toBeNull();
  });

  it("maps tool activity with friendly titles", () => {
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
      mapCursorHook("beforeMCPExecution", { ...BASE, server_name: "linear", tool_name: "create_issue" }, "x"),
    ).toMatchObject({ type: "tool_use", title: "linear.create_issue" });

    expect(mapCursorHook("subagentStart", BASE, "x")).toMatchObject({
      type: "tool_use",
      title: "Delegating to a subagent",
    });
  });

  it("maps lifecycle: after-events keep working, stop ends the session", () => {
    expect(mapCursorHook("afterShellExecution", BASE, "x")?.type).toBe("task_progress");
    expect(mapCursorHook("afterAgentThought", BASE, "x")).toMatchObject({ title: "thinking…" });
    expect(mapCursorHook("stop", BASE, "x")).toMatchObject({
      type: "session_ended",
      title: "finished responding",
    });
  });

  it("returns null for unknown hook events", () => {
    expect(mapCursorHook("someFutureHook", BASE, "x")).toBeNull();
  });
});

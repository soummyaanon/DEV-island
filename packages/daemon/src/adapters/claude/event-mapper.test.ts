import { describe, expect, it } from "vitest";
import { mapClaudeHook } from "./event-mapper";

describe("mapClaudeHook", () => {
  it("surfaces AskUserQuestion permission events as questions, not approvals", () => {
    const mapped = mapClaudeHook(
      "PermissionRequest",
      {
        session_id: "session-1",
        cwd: "/Users/me/project",
        tool_name: "AskUserQuestion",
        tool_input: {
          questions: [
            {
              question: "Which environment?",
              options: [{ label: "Production" }, { label: "Staging" }],
            },
          ],
        },
      },
      "(unknown)",
    );

    expect(mapped).toMatchObject({
      type: "notification",
      title: "Claude asks a question",
      requires_action: true,
    });
  });

  it("persists the SessionStart model and permission mode as session metadata", () => {
    const mapped = mapClaudeHook(
      "SessionStart",
      {
        session_id: "session-1",
        cwd: "/Users/me/project",
        source: "startup",
        model: "claude-opus-4-6",
        permission_mode: "plan",
      },
      "(unknown)",
    );

    expect(mapped?.detail?._meta).toEqual({
      model: "claude-opus-4-6",
      permission_mode: "plan",
    });
  });
});

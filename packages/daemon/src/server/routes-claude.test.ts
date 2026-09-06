import Fastify from "fastify";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { DaemonConfig } from "../config";
import { EventHub } from "../hub/event-hub";
import { registerClaudeRoutes } from "./routes-claude";
import { registerQuestionRoutes } from "./routes-questions";

const config: DaemonConfig = {
  host: "127.0.0.1",
  port: 7433,
  tokenPath: "/tmp/agent-island-test-token",
  strictAuth: false,
  ringBufferSize: 20,
  heartbeatMs: 30_000,
  approvalHoldMs: 5,
  codexHome: "/tmp",
  usagePollMs: 45_000,
  codexActiveMs: 600_000,
  codexPollMs: 1_500,
  codexScanMs: 10_000,
};

describe("Claude hook routes", () => {
  const apps: ReturnType<typeof Fastify>[] = [];

  afterEach(async () => {
    await Promise.all(apps.splice(0).map((app) => app.close()));
  });

  it("turns an AskUserQuestion permission request into selectable question state", async () => {
    const app = Fastify();
    apps.push(app);
    const hub = new EventHub(20, 5);
    hub.subscribe(() => {});
    registerClaudeRoutes(app, hub, config, "test-token");

    const response = await app.inject({
      method: "POST",
      url: "/events/claude/permission-request",
      payload: {
        session_id: "session-1",
        cwd: "/Users/me/project",
        hook_event_name: "PermissionRequest",
        tool_name: "AskUserQuestion",
        tool_input: {
          questions: [
            {
              question: "Deploy where?",
              options: [
                { label: "Production", description: "Deploy the current release" },
                { label: "Staging", description: "Run a final smoke test" },
              ],
            },
          ],
        },
      },
    });

    expect(response.statusCode).toBe(204);
    expect(hub.sessions()[0]).toMatchObject({
      pending_approval: null,
      pending_question: {
        questions: [
          {
            question: "Deploy where?",
            options: [
              "Production — Deploy the current release",
              "Staging — Run a final smoke test",
            ],
          },
        ],
      },
    });
  });

  it("answers a held AskUserQuestion from the notch through the hook response", async () => {
    const app = Fastify();
    apps.push(app);
    const hub = new EventHub(20, 500);
    hub.subscribe(() => {});
    registerClaudeRoutes(app, hub, config, "test-token");
    registerQuestionRoutes(app, hub);

    // Not awaited: the route holds this reply open until the notch answers.
    const held = app.inject({
      method: "POST",
      url: "/events/claude/permission-request",
      payload: {
        session_id: "session-1",
        cwd: "/Users/me/project",
        hook_event_name: "PermissionRequest",
        tool_name: "AskUserQuestion",
        tool_input: {
          questions: [
            {
              question: "Deploy where?",
              options: [
                { label: "Production", description: "Deploy the current release" },
                { label: "Staging", description: "Run a final smoke test" },
              ],
            },
          ],
        },
      },
    });

    await vi.waitFor(() => expect(hub.sessions()[0]?.pending_question).toBeTruthy());
    const questionId = hub.sessions()[0]?.pending_question?.id ?? "";

    const answered = await app.inject({
      method: "POST",
      url: `/questions/${questionId}`,
      payload: { options: [1] },
    });
    expect(answered.statusCode).toBe(200);

    const response = await held;
    expect(response.statusCode).toBe(200);
    expect(response.json()).toMatchObject({
      hookSpecificOutput: {
        hookEventName: "PermissionRequest",
        decision: {
          behavior: "allow",
          updatedInput: { answers: { "Deploy where?": "Staging" } },
        },
      },
    });
    // Answered remotely: the card must clear without waiting for PostToolUse.
    expect(hub.sessions()[0]?.pending_question).toBeNull();
  });

  it("answers every question of a multi-question ask through one hook response", async () => {
    const app = Fastify();
    apps.push(app);
    const hub = new EventHub(20, 500);
    hub.subscribe(() => {});
    registerClaudeRoutes(app, hub, config, "test-token");
    registerQuestionRoutes(app, hub);

    const held = app.inject({
      method: "POST",
      url: "/events/claude/permission-request",
      payload: {
        session_id: "session-1",
        cwd: "/Users/me/project",
        hook_event_name: "PermissionRequest",
        tool_name: "AskUserQuestion",
        tool_input: {
          questions: [
            { question: "Deploy where?", options: [{ label: "Production" }, { label: "Staging" }] },
            { question: "Notify the team?", options: [{ label: "Yes" }, { label: "No" }] },
          ],
        },
      },
    });

    await vi.waitFor(() => expect(hub.sessions()[0]?.pending_question).toBeTruthy());
    const pending = hub.sessions()[0]?.pending_question;
    expect(pending?.questions).toHaveLength(2);

    await app.inject({
      method: "POST",
      url: `/questions/${pending?.id ?? ""}`,
      payload: { options: [0, 1] },
    });

    const response = await held;
    expect(response.statusCode).toBe(200);
    expect(response.json()).toMatchObject({
      hookSpecificOutput: {
        decision: {
          behavior: "allow",
          updatedInput: { answers: { "Deploy where?": "Production", "Notify the team?": "No" } },
        },
      },
    });
  });

  it("keeps the card when a held question times out (Claude's picker takes over)", async () => {
    const app = Fastify();
    apps.push(app);
    const hub = new EventHub(20, 5);
    hub.subscribe(() => {});
    registerClaudeRoutes(app, hub, config, "test-token");

    const response = await app.inject({
      method: "POST",
      url: "/events/claude/permission-request",
      payload: {
        session_id: "session-1",
        cwd: "/Users/me/project",
        hook_event_name: "PermissionRequest",
        tool_name: "AskUserQuestion",
        tool_input: {
          questions: [{ question: "Deploy where?", options: [{ label: "Production" }] }],
        },
      },
    });

    expect(response.statusCode).toBe(204);
    expect(response.body).toBe("");
    expect(hub.sessions()[0]?.pending_question).not.toBeNull();
  });

  it("keeps the question pending while notifications arrive, clears it on real activity", async () => {
    const app = Fastify();
    apps.push(app);
    const hub = new EventHub(20, 5);
    hub.subscribe(() => {});
    registerClaudeRoutes(app, hub, config, "test-token");

    await app.inject({
      method: "POST",
      url: "/events/claude/pre-tool",
      payload: {
        session_id: "session-1",
        cwd: "/Users/me/project",
        hook_event_name: "PreToolUse",
        tool_name: "AskUserQuestion",
        tool_input: { questions: [{ question: "Deploy where?", options: [{ label: "Production" }] }] },
      },
    });
    expect(hub.sessions()[0]?.pending_question).not.toBeNull();

    // Claude emits Notification hooks WHILE it waits on the question — the
    // card must survive them, not flash and vanish.
    await app.inject({
      method: "POST",
      url: "/events/claude/notification",
      payload: {
        session_id: "session-1",
        cwd: "/Users/me/project",
        hook_event_name: "Notification",
        message: "Claude is waiting for your input",
      },
    });
    expect(hub.sessions()[0]?.pending_question).not.toBeNull();

    // The answer shows up as tool activity — that clears it.
    await app.inject({
      method: "POST",
      url: "/events/claude/post-tool",
      payload: {
        session_id: "session-1",
        cwd: "/Users/me/project",
        hook_event_name: "PostToolUse",
        tool_name: "AskUserQuestion",
      },
    });
    expect(hub.sessions()[0]?.pending_question).toBeNull();
  });

  it("stores only plausible app bundle ids from hook headers", async () => {
    const app = Fastify();
    apps.push(app);
    const hub = new EventHub(20, 5);
    registerClaudeRoutes(app, hub, config, "test-token");

    const payload = {
      session_id: "session-1",
      cwd: "/Users/me/project",
      hook_event_name: "PreToolUse",
      tool_name: "Bash",
      tool_input: { command: "ls" },
    };

    // Claude's header interpolation only knows UPPERCASE env vars, so a
    // "$__CFBundleIdentifier" template arrives as the literal tail
    // "undleIdentifier" — it must be rejected, not stored.
    await app.inject({
      method: "POST",
      url: "/events/claude/pre-tool",
      headers: { "x-app-bundle-id": "undleIdentifier" },
      payload,
    });
    expect(hub.sessions()[0]?.meta.app_bundle_id).toBeUndefined();

    await app.inject({
      method: "POST",
      url: "/events/claude/pre-tool",
      headers: { "x-app-bundle-id": "com.todesktop.230313mzl4w4u92" },
      payload,
    });
    expect(hub.sessions()[0]?.meta.app_bundle_id).toBe("com.todesktop.230313mzl4w4u92");
  });

  it("stores the agent pid from the bridge header, rejecting anything that isn't one", async () => {
    const app = Fastify();
    apps.push(app);
    const hub = new EventHub(20, 5);
    registerClaudeRoutes(app, hub, config, "test-token");

    const payload = {
      session_id: "session-pid",
      cwd: "/Users/me/project",
      hook_event_name: "SessionStart",
    };

    await app.inject({
      method: "POST",
      url: "/events/claude/session-start",
      headers: { "x-agent-pid": "not-a-pid" },
      payload,
    });
    expect(hub.sessions()[0]?.meta.pid).toBeUndefined();

    await app.inject({
      method: "POST",
      url: "/events/claude/session-start",
      headers: { "x-agent-pid": "48213" },
      payload,
    });
    expect(hub.sessions()[0]?.meta.pid).toBe("48213");
  });
});

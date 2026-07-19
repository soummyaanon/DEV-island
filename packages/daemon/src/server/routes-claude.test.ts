import Fastify from "fastify";
import { afterEach, describe, expect, it } from "vitest";
import type { DaemonConfig } from "../config";
import { EventHub } from "../hub/event-hub";
import { registerClaudeRoutes } from "./routes-claude";

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
        question: "Deploy where?",
        options: ["Production — Deploy the current release", "Staging — Run a final smoke test"],
      },
    });
  });
});

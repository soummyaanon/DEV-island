import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

vi.mock("electron", () => ({
  Notification: class {
    show() {}
  },
}));

describe("Claude zero-config", () => {
  const originalHome = process.env.AGENT_ISLAND_HOME;
  const originalSettings = process.env.AGENT_ISLAND_CLAUDE_SETTINGS;

  afterEach(() => {
    process.env.AGENT_ISLAND_HOME = originalHome;
    process.env.AGENT_ISLAND_CLAUDE_SETTINGS = originalSettings;
    vi.resetModules();
  });

  it("uses a command bridge for SessionStart so Claude sends model and host metadata", async () => {
    const root = mkdtempSync(join(tmpdir(), "agent-island-zero-config-"));
    const home = join(root, "home");
    const settingsPath = join(root, "settings.json");
    process.env.AGENT_ISLAND_HOME = home;
    process.env.AGENT_ISLAND_CLAUDE_SETTINGS = settingsPath;

    const { setupZeroConfig } = await import("./zero-config");
    expect(setupZeroConfig()).toBe("installed");

    const settings = JSON.parse(readFileSync(settingsPath, "utf8")) as {
      hooks: Record<string, Array<{ hooks: Array<Record<string, unknown>> }>>;
    };
    const handler = settings.hooks.SessionStart[0].hooks[0];
    expect(handler).toMatchObject({
      type: "command",
      command: join(home, "bin", "claude-hook.sh"),
      args: ["session-start"],
    });

    const bridge = readFileSync(join(home, "bin", "claude-hook.sh"), "utf8");
    expect(bridge).toContain('X-App-Bundle-Id: ${__CFBundleIdentifier:-}');
    expect(bridge).toContain("--data-binary @-");
  });
});

import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
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
    // $PPID in the bridge shell is Claude Code itself — the resource meter's root.
    expect(bridge).toContain('X-Agent-Pid: ${PPID:-}');
    expect(bridge).toContain("--data-binary @-");
  });

  // The app now calls removeClaudeHooks() on quit so the HTTP hooks don't fire
  // against a dead daemon. This locks in that it strips ONLY our handlers.
  it("removeClaudeHooks strips our hooks but keeps the user's own", async () => {
    const root = mkdtempSync(join(tmpdir(), "agent-island-zero-config-"));
    const home = join(root, "home");
    const settingsPath = join(root, "settings.json");
    process.env.AGENT_ISLAND_HOME = home;
    process.env.AGENT_ISLAND_CLAUDE_SETTINGS = settingsPath;

    // A user's own PreToolUse hook that must survive both install and removal.
    writeFileSync(
      settingsPath,
      JSON.stringify({
        hooks: {
          PreToolUse: [{ matcher: "*", hooks: [{ type: "command", command: "echo mine" }] }],
        },
      }),
    );

    const { setupZeroConfig, removeClaudeHooks } = await import("./zero-config");
    expect(setupZeroConfig()).toBe("updated");
    const installed = JSON.stringify(
      (JSON.parse(readFileSync(settingsPath, "utf8")) as { hooks: unknown }).hooks,
    );
    expect(installed).toContain("/events/claude/pre-tool"); // ours added
    expect(installed).toContain("echo mine"); // user's kept

    expect(removeClaudeHooks()).toBe("updated");
    const after = JSON.stringify(
      (JSON.parse(readFileSync(settingsPath, "utf8")) as { hooks?: unknown }).hooks ?? {},
    );
    expect(after).not.toContain("/events/claude/"); // ours gone
    expect(after).toContain("echo mine"); // user's still there
  });
});

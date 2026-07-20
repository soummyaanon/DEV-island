import { beforeEach, describe, expect, it, vi } from "vitest";

const execFile = vi.fn((_file, _args, callback) => callback?.(null));
const openExternal = vi.fn();
const isTrusted = vi.fn();
const electronApp = { isPackaged: true };

vi.mock("node:child_process", () => ({ execFile }));
vi.mock("electron", () => ({
  app: electronApp,
  shell: { openExternal },
  systemPreferences: {
    isTrustedAccessibilityClient: (prompt: boolean) => isTrusted(prompt),
  },
}));

beforeEach(() => {
  execFile.mockClear();
  openExternal.mockClear();
  isTrusted.mockReset();
  electronApp.isPackaged = true;
});

describe("requestAccessibility", () => {
  it("resets the stale TCC entry, re-prompts, and opens the pane when untrusted", async () => {
    isTrusted.mockReturnValue(false);
    const { requestAccessibility } = await import("./accessibility");
    requestAccessibility();

    expect(execFile.mock.calls[0]?.[0]).toBe("tccutil");
    expect(execFile.mock.calls[0]?.[1]).toEqual(["reset", "Accessibility", "com.agentisland.app"]);
    // The (true) call asks macOS to re-add the CURRENT binary to the list.
    expect(isTrusted).toHaveBeenCalledWith(true);
    expect(openExternal).toHaveBeenCalledWith(
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
    );
  });

  it("skips the TCC reset in dev runs (the responsible binary is Electron, not us)", async () => {
    isTrusted.mockReturnValue(false);
    electronApp.isPackaged = false;
    const { requestAccessibility } = await import("./accessibility");
    requestAccessibility();

    expect(execFile).not.toHaveBeenCalled();
    expect(isTrusted).toHaveBeenCalledWith(true);
    expect(openExternal).toHaveBeenCalled();
  });

  it("leaves a working grant alone — just opens the pane", async () => {
    isTrusted.mockReturnValue(true);
    const { requestAccessibility } = await import("./accessibility");
    requestAccessibility();

    expect(execFile).not.toHaveBeenCalled();
    expect(isTrusted).not.toHaveBeenCalledWith(true);
    expect(openExternal).toHaveBeenCalled();
  });

  it("still prompts and opens the pane when tccutil fails", async () => {
    isTrusted.mockReturnValue(false);
    execFile.mockImplementationOnce((_file, _args, callback) =>
      callback?.(new Error("not permitted")),
    );
    const { requestAccessibility } = await import("./accessibility");
    requestAccessibility();

    expect(isTrusted).toHaveBeenCalledWith(true);
    expect(openExternal).toHaveBeenCalled();
  });
});

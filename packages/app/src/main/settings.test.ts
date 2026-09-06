import { describe, expect, it, vi } from "vitest";

// settings.ts imports Electron's `app` for the userData path; the pure
// normaliser under test never touches it.
vi.mock("electron", () => ({ app: { getPath: () => "/tmp" } }));

import { DEFAULT_SETTINGS, SETTINGS_VERSION, normalizeSettings } from "./settings";

describe("normalizeSettings", () => {
  it("fills every default for an empty file and stamps the version", () => {
    const s = normalizeSettings({});
    expect(s).toEqual(DEFAULT_SETTINGS);
    expect(s.settingsVersion).toBe(SETTINGS_VERSION);
  });

  it("migrates a legacy (unversioned) file's openWith to the new default", () => {
    const s = normalizeSettings({ openWith: "hover", sounds: false } as never);
    expect(s.openWith).toBe("swipe");
    expect(s.sounds).toBe(false); // everything else is kept
  });

  it("respects a chosen openWith once the file is versioned", () => {
    expect(normalizeSettings({ settingsVersion: 2, openWith: "hover" }).openWith).toBe("hover");
    expect(normalizeSettings({ settingsVersion: 2, openWith: "swipe" }).openWith).toBe("swipe");
  });

  it("rejects junk enums", () => {
    const s = normalizeSettings({ settingsVersion: 2, openWith: "tap", textSize: "huge" } as never);
    expect(s.openWith).toBe("swipe");
    expect(s.textSize).toBe("default");
  });
});

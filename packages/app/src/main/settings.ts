import { app } from "electron";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { AgentKind } from "@agent-island/shared";

/** Everything the Settings window can change, persisted across launches. */
export interface AppSettings {
  agents: Record<AgentKind, boolean>;
  sounds: boolean;
  /** Menu-bar icon (off by default — the island is the app). */
  tray: boolean;
  /** Anonymous GitHub Releases version check. */
  updateCheck: boolean;
}

export const DEFAULT_SETTINGS: AppSettings = {
  agents: { "claude-code": true, codex: true, cursor: true },
  sounds: true,
  tray: false,
  updateCheck: true,
};

function settingsPath(): string {
  return join(app.getPath("userData"), "settings.json");
}

let cached: AppSettings | null = null;

export function loadSettings(): AppSettings {
  if (cached) return cached;
  let stored: Partial<AppSettings> = {};
  try {
    if (existsSync(settingsPath())) {
      stored = JSON.parse(readFileSync(settingsPath(), "utf8")) as Partial<AppSettings>;
    }
  } catch {
    /* corrupt settings -> defaults; the next save repairs the file */
  }
  cached = {
    ...DEFAULT_SETTINGS,
    ...stored,
    agents: { ...DEFAULT_SETTINGS.agents, ...(stored.agents ?? {}) },
  };
  return cached;
}

export function saveSettings(next: AppSettings): void {
  cached = next;
  try {
    writeFileSync(settingsPath(), `${JSON.stringify(next, null, 2)}\n`);
  } catch (err) {
    console.error("[settings] save failed:", err);
  }
}

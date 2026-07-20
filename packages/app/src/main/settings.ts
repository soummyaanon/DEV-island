import { app } from "electron";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { AgentKind } from "@agent-island/shared";

export const SOUND_THEMES = ["8bit", "arcade", "soft", "anime"] as const;
export type SoundTheme = (typeof SOUND_THEMES)[number];

export const SOUND_EVENTS = ["success", "attention", "question", "approve"] as const;
export type SoundEvent = (typeof SOUND_EVENTS)[number];

/** Everything the Settings window can change, persisted across launches. */
export interface AppSettings {
  agents: Record<AgentKind, boolean>;
  sounds: boolean;
  /** Which sound set plays; per-event overrides win over the theme. */
  soundTheme: SoundTheme;
  soundOverrides: Partial<Record<SoundEvent, SoundTheme>>;
  /** Per-event imported audio files (absolute paths under userData/sounds).
   *  A custom file, when present, wins over both the override and the theme. */
  customSounds: Partial<Record<SoundEvent, string>>;
  /** Original file names of the imports above (the copy is renamed per event),
   *  so Settings can show "goku-punch.mp3" instead of a generic "Custom". */
  customSoundNames: Partial<Record<SoundEvent, string>>;
  /** Menu-bar icon (off by default — the island is the app). */
  tray: boolean;
  /** Anonymous GitHub Releases version check. */
  updateCheck: boolean;
}

export const DEFAULT_SETTINGS: AppSettings = {
  agents: { "claude-code": true, codex: true, cursor: true },
  sounds: true,
  soundTheme: "8bit",
  soundOverrides: {},
  customSounds: {},
  customSoundNames: {},
  tray: false,
  updateCheck: true,
};

export function isSoundTheme(value: unknown): value is SoundTheme {
  return typeof value === "string" && (SOUND_THEMES as readonly string[]).includes(value);
}

export function isSoundEvent(value: unknown): value is SoundEvent {
  return typeof value === "string" && (SOUND_EVENTS as readonly string[]).includes(value);
}

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
    soundTheme: isSoundTheme(stored.soundTheme) ? stored.soundTheme : DEFAULT_SETTINGS.soundTheme,
    soundOverrides: { ...(stored.soundOverrides ?? {}) },
    customSounds: { ...(stored.customSounds ?? {}) },
    customSoundNames: { ...(stored.customSoundNames ?? {}) },
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

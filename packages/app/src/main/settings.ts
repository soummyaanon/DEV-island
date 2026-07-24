import { app } from "electron";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { AgentKind } from "@agent-island/shared";

export const SOUND_THEMES = ["8bit", "arcade", "soft", "anime"] as const;
export type SoundTheme = (typeof SOUND_THEMES)[number];

export const SOUND_EVENTS = ["success", "attention", "question", "approve"] as const;
export type SoundEvent = (typeof SOUND_EVENTS)[number];

/**
 * Text scale. macOS has no Dynamic Type API and doesn't expose the
 * Accessibility text-size setting to Chromium, so the honest equivalent is our
 * own scale driving --ui-scale over the type tokens.
 */
export const TEXT_SIZES = ["default", "large", "larger"] as const;
export type TextSize = (typeof TEXT_SIZES)[number];

export const TEMPERATURE_UNITS = ["auto", "c", "f"] as const;
export type TemperatureUnit = (typeof TEMPERATURE_UNITS)[number];

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
  /** Trackpad haptics. Inert on hardware without a Force Touch trackpad. */
  haptics: boolean;
  /** UI text scale (accessibility). */
  textSize: TextSize;
  /**
   * Local weather in the idle island. OFF by default: it is the only ongoing
   * network request the app makes besides the update check, so it stays an
   * explicit choice rather than something to discover after the fact.
   */
  weather: boolean;
  /** "lat, lon" typed by the user. Empty = fall back to the timezone guess. */
  weatherLocation: string;
  weatherUnits: TemperatureUnit;
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
  haptics: true,
  textSize: "default",
  weather: false,
  weatherLocation: "",
  weatherUnits: "auto",
};

export function isSoundTheme(value: unknown): value is SoundTheme {
  return typeof value === "string" && (SOUND_THEMES as readonly string[]).includes(value);
}

export function isSoundEvent(value: unknown): value is SoundEvent {
  return typeof value === "string" && (SOUND_EVENTS as readonly string[]).includes(value);
}

export function isTextSize(value: unknown): value is TextSize {
  return typeof value === "string" && (TEXT_SIZES as readonly string[]).includes(value);
}

export function isTemperatureUnit(value: unknown): value is TemperatureUnit {
  return typeof value === "string" && (TEMPERATURE_UNITS as readonly string[]).includes(value);
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
    textSize: isTextSize(stored.textSize) ? stored.textSize : DEFAULT_SETTINGS.textSize,
    weatherUnits: isTemperatureUnit(stored.weatherUnits)
      ? stored.weatherUnits
      : DEFAULT_SETTINGS.weatherUnits,
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

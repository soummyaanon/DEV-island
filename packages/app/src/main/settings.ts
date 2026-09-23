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

/** How the collapsed island opens. Swipe (default): a two-finger swipe down
 *  or a click opens it and grazing the top of the screen doesn't. Hover: the
 *  classic behavior. */
export const OPEN_WITH = ["hover", "swipe"] as const;
export type OpenWith = (typeof OPEN_WITH)[number];

/** How sessions show in the open island: small avatar bubbles (default) or
 *  the full rows with activity, model and meter. */
export const SESSION_VIEWS = ["compact", "detailed"] as const;
export type SessionView = (typeof SESSION_VIEWS)[number];

/**
 * Bumped when a stored field's meaning changes.
 * - v1 → v2: v1 files (no version) were written before "Open with" existed in
 *   Settings, so their `openWith` was only ever the old implicit default — it
 *   is reset to the new default once.
 * - v2 → v3: `glass` used to default to on. The island is now one solid black
 *   body and glass is an opt-in translucent look, so a v2 file's `glass` (only
 *   ever the old default) is reset to off once.
 */
export const SETTINGS_VERSION = 3;

/** Everything the Settings window can change, persisted across launches. */
export interface AppSettings {
  settingsVersion: number;
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
  /** Hover-to-open (default) or gesture-to-open. */
  openWith: OpenWith;
  sessionView: SessionView;
  /** Opt-in: a translucent Liquid Glass panel (native sheet, falls back to
   *  CSS) instead of the solid deep-black body. Off by default. */
  glass: boolean;
  /** Battery live activity in the wings and footer. */
  battery: boolean;
  /** Per-agent CPU/memory meter (samples only while the panel is open). */
  procStats: boolean;
  /** Mute sounds and notification haptics while a Focus is on. */
  respectFocus: boolean;
  /** The Ask bar (✦ and the bot crew) at all. */
  assistant: boolean;
  /** Use Apple Intelligence's on-device model. Off = commands only. */
  assistantModel: boolean;
  /** The mic button in the Ask bar. */
  voice: boolean;
  /** Read spoken questions' answers aloud. */
  speakReplies: boolean;
  /** The colourful edge glow while the assistant is open. */
  edgeGlow: boolean;
}

export const DEFAULT_SETTINGS: AppSettings = {
  settingsVersion: SETTINGS_VERSION,
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
  openWith: "swipe",
  sessionView: "compact",
  glass: false,
  battery: true,
  procStats: true,
  respectFocus: true,
  assistant: true,
  assistantModel: true,
  voice: true,
  speakReplies: true,
  edgeGlow: true,
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

export function isSessionView(value: unknown): value is SessionView {
  return typeof value === "string" && (SESSION_VIEWS as readonly string[]).includes(value);
}

export function isOpenWith(value: unknown): value is OpenWith {
  return typeof value === "string" && (OPEN_WITH as readonly string[]).includes(value);
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
  cached = normalizeSettings(stored);
  // A migrated file is written back once, so the migration doesn't re-run
  // (and re-reset the field) on every launch.
  if (stored.settingsVersion !== SETTINGS_VERSION) saveSettings(cached);
  return cached;
}

/**
 * Merge a stored file over the defaults, validating enums and applying
 * migrations. Pure, so it is unit-tested without Electron.
 */
export function normalizeSettings(stored: Partial<AppSettings>): AppSettings {
  // Unversioned files are v1.
  const version = typeof stored.settingsVersion === "number" ? stored.settingsVersion : 1;
  return {
    ...DEFAULT_SETTINGS,
    ...stored,
    settingsVersion: SETTINGS_VERSION,
    agents: { ...DEFAULT_SETTINGS.agents, ...(stored.agents ?? {}) },
    soundTheme: isSoundTheme(stored.soundTheme) ? stored.soundTheme : DEFAULT_SETTINGS.soundTheme,
    textSize: isTextSize(stored.textSize) ? stored.textSize : DEFAULT_SETTINGS.textSize,
    weatherUnits: isTemperatureUnit(stored.weatherUnits)
      ? stored.weatherUnits
      : DEFAULT_SETTINGS.weatherUnits,
    // Migration: a v1 file's openWith was never a choice, only the old default.
    openWith: version >= 2 && isOpenWith(stored.openWith) ? stored.openWith : DEFAULT_SETTINGS.openWith,
    sessionView: isSessionView(stored.sessionView) ? stored.sessionView : DEFAULT_SETTINGS.sessionView,
    // Migration: before v3, glass was on by default — a stored `true` was the
    // default, not a choice. The solid black body is the look now; glass is opt-in.
    glass: version >= 3 && typeof stored.glass === "boolean" ? stored.glass : DEFAULT_SETTINGS.glass,
    soundOverrides: { ...(stored.soundOverrides ?? {}) },
    customSounds: { ...(stored.customSounds ?? {}) },
    customSoundNames: { ...(stored.customSoundNames ?? {}) },
  };
}

export function saveSettings(next: AppSettings): void {
  cached = next;
  try {
    writeFileSync(settingsPath(), `${JSON.stringify(next, null, 2)}\n`);
  } catch (err) {
    console.error("[settings] save failed:", err);
  }
}

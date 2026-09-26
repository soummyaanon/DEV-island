/** Sound preference model + pure resolution logic (kept import-light for tests). */

export const SOUND_THEMES = ["8bit", "arcade", "soft", "glass", "marimba", "zen", "anime"] as const;
export type SoundTheme = (typeof SOUND_THEMES)[number];

export const SOUND_EVENTS = ["success", "attention", "question", "approve"] as const;
export type SoundEvent = (typeof SOUND_EVENTS)[number];

export interface SoundPrefs {
  on: boolean;
  theme: SoundTheme;
  /** Per-event theme override; absent = follow `theme`. */
  overrides: Partial<Record<SoundEvent, SoundTheme>>;
  /** Per-event imported audio as a data URL; when present it wins over the theme. */
  custom?: Partial<Record<SoundEvent, string>>;
}

export const DEFAULT_SOUND_PREFS: SoundPrefs = { on: true, theme: "8bit", overrides: {}, custom: {} };

export const THEME_LABELS: Record<SoundTheme, string> = {
  "8bit": "8-bit",
  arcade: "Arcade",
  soft: "Soft",
  glass: "Glass",
  marimba: "Marimba",
  zen: "Zen",
  anime: "Anime",
};

/** One line per theme, for the Settings picker. */
export const THEME_BLURBS: Record<SoundTheme, string> = {
  "8bit": "Chiptune blips and arpeggios.",
  arcade: "Coins, klaxons and power-ups.",
  soft: "Gentle sine chimes.",
  glass: "Bright crystal pings with a shimmer.",
  marimba: "Warm wooden taps.",
  zen: "Low singing bowls that ring out.",
  anime: "The bundled voice pack.",
};

export const EVENT_LABELS: Record<SoundEvent, string> = {
  success: "Done",
  attention: "Needs you",
  question: "Question",
  approve: "You allow",
};

function isTheme(value: unknown): value is SoundTheme {
  return typeof value === "string" && (SOUND_THEMES as readonly string[]).includes(value);
}

/** The theme whose sound plays for `event`: a valid override wins, else the base theme. */
export function resolveTheme(event: SoundEvent, prefs: SoundPrefs): SoundTheme {
  const override = prefs.overrides[event];
  return isTheme(override) ? override : isTheme(prefs.theme) ? prefs.theme : "8bit";
}

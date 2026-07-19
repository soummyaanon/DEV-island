/** Sound preference model + pure resolution logic (kept import-light for tests). */

export const SOUND_THEMES = ["8bit", "arcade", "soft", "anime"] as const;
export type SoundTheme = (typeof SOUND_THEMES)[number];

export const SOUND_EVENTS = ["success", "attention", "question", "approve"] as const;
export type SoundEvent = (typeof SOUND_EVENTS)[number];

export interface SoundPrefs {
  on: boolean;
  theme: SoundTheme;
  /** Per-event theme override; absent = follow `theme`. */
  overrides: Partial<Record<SoundEvent, SoundTheme>>;
}

export const DEFAULT_SOUND_PREFS: SoundPrefs = { on: true, theme: "8bit", overrides: {} };

export const THEME_LABELS: Record<SoundTheme, string> = {
  "8bit": "8-bit",
  arcade: "Arcade",
  soft: "Soft",
  anime: "Anime",
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

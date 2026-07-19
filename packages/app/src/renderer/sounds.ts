// Sound themes: three synthesized WebAudio sets (no files) plus the bundled
// "anime" MP3 pack. Which theme plays is resolved per event via SoundPrefs.

import { resolveTheme, type SoundEvent, type SoundPrefs, type SoundTheme } from "./sound-prefs";
import animeShineUrl from "./assets/sounds/anime-shine.mp3";
import animeWowUrl from "./assets/sounds/anime-wow.mp3";
import fahhhhhUrl from "./assets/sounds/fahhhhh.mp3";
import thikHaUrl from "./assets/sounds/thik-ha.mp3";

let ctx: AudioContext | null = null;

function audio(): AudioContext {
  if (!ctx) ctx = new AudioContext();
  return ctx;
}

/**
 * One synthesized note. `at`/`dur` in seconds relative to now; `attack` slow =
 * soft chime, fast = 8-bit chip envelope.
 */
function note(
  freq: number,
  at: number,
  dur: number,
  volume = 0.045,
  wave: OscillatorType = "square",
  attack = 0.008,
): void {
  const ac = audio();
  const osc = ac.createOscillator();
  const gain = ac.createGain();
  osc.type = wave;
  osc.frequency.value = freq;
  const t0 = ac.currentTime + at;
  gain.gain.setValueAtTime(0.0001, t0);
  gain.gain.exponentialRampToValueAtTime(volume, t0 + attack);
  gain.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
  osc.connect(gain).connect(ac.destination);
  osc.start(t0);
  osc.stop(t0 + dur + 0.02);
}

/** A pitch slide (arcade power-up/down feel). */
function slide(from: number, to: number, at: number, dur: number, volume = 0.06): void {
  const ac = audio();
  const osc = ac.createOscillator();
  const gain = ac.createGain();
  osc.type = "square";
  const t0 = ac.currentTime + at;
  osc.frequency.setValueAtTime(from, t0);
  osc.frequency.exponentialRampToValueAtTime(to, t0 + dur);
  gain.gain.setValueAtTime(0.0001, t0);
  gain.gain.exponentialRampToValueAtTime(volume, t0 + 0.01);
  gain.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
  osc.connect(gain).connect(ac.destination);
  osc.start(t0);
  osc.stop(t0 + dur + 0.02);
}

function mp3(url: string, volume = 0.5): void {
  const player = new Audio(url);
  player.volume = volume;
  void player.play().catch(() => {
    /* autoplay refusal or missing device — sounds are best-effort */
  });
}

type ThemeSounds = Record<SoundEvent, () => void>;

const THEMES: Record<SoundTheme, ThemeSounds> = {
  "8bit": {
    // Task finished: quick rising arpeggio (C5 E5 G5 C6).
    success: () => {
      note(523.25, 0, 0.09, 0.06);
      note(659.25, 0.07, 0.09, 0.06);
      note(783.99, 0.14, 0.09, 0.06);
      note(1046.5, 0.21, 0.16, 0.08);
    },
    // Needs you (approval): insistent double ping — deliberately loud.
    attention: () => {
      note(1318.5, 0, 0.08, 0.14);
      note(1318.5, 0.13, 0.12, 0.16);
    },
    // Question: rising two-note "hm?" inquiry.
    question: () => {
      note(659.25, 0, 0.09, 0.09);
      note(987.77, 0.09, 0.16, 0.11);
    },
    // You allowed something: crisp confirm blip.
    approve: () => {
      note(880, 0, 0.06, 0.07);
      note(1318.5, 0.06, 0.1, 0.08);
    },
  },
  arcade: {
    // Coin-up: fast octave hop with a sparkle on top.
    success: () => {
      note(987.77, 0, 0.06, 0.07);
      slide(1318.5, 2637, 0.06, 0.14, 0.07);
    },
    // Klaxon: alternating loud fifths.
    attention: () => {
      note(783.99, 0, 0.1, 0.14);
      note(1174.7, 0.11, 0.1, 0.14);
      note(783.99, 0.22, 0.1, 0.14);
      note(1174.7, 0.33, 0.12, 0.16);
    },
    // Quirky up-down blip.
    question: () => {
      note(1046.5, 0, 0.07, 0.09);
      note(1568, 0.08, 0.07, 0.09);
      note(1318.5, 0.16, 0.12, 0.09);
    },
    // Coin-tick confirm.
    approve: () => {
      slide(1046.5, 2093, 0, 0.12, 0.07);
    },
  },
  soft: {
    // Gentle major chime, slow attack.
    success: () => {
      note(523.25, 0, 0.5, 0.05, "sine", 0.06);
      note(783.99, 0.12, 0.6, 0.045, "sine", 0.06);
    },
    // Two soft bells.
    attention: () => {
      note(880, 0, 0.4, 0.08, "triangle", 0.02);
      note(880, 0.28, 0.5, 0.09, "triangle", 0.02);
    },
    // Single raised bell.
    question: () => {
      note(1046.5, 0, 0.45, 0.07, "triangle", 0.02);
    },
    // Soft low confirmation.
    approve: () => {
      note(659.25, 0, 0.3, 0.06, "sine", 0.03);
    },
  },
  anime: {
    success: () => mp3(thikHaUrl, 0.55),
    attention: () => mp3(animeWowUrl, 0.55),
    question: () => mp3(animeShineUrl, 0.5),
    approve: () => mp3(fahhhhhUrl, 0.55),
  },
};

/** Play `event`'s sound per prefs (custom file > override/theme). No-op when off. */
export function playSound(event: SoundEvent, prefs: SoundPrefs): void {
  if (!prefs.on) return;
  const custom = prefs.custom?.[event];
  if (custom) {
    mp3(custom, 0.6);
    return;
  }
  THEMES[resolveTheme(event, prefs)][event]();
}

/** Preview a specific theme's sound for one event (Settings ▶ buttons). */
export function previewSound(event: SoundEvent, theme: SoundTheme): void {
  THEMES[theme][event]();
}

/** Preview an imported custom sound (data URL) — Settings ▶ for custom rows. */
export function previewCustom(dataUrl: string): void {
  mp3(dataUrl, 0.6);
}

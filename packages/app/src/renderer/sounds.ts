// 8-bit synthesized sound effects — square-wave chiptunes via WebAudio.
// No audio files; every sound is a tiny oscillator envelope.

let ctx: AudioContext | null = null;

function audio(): AudioContext {
  if (!ctx) ctx = new AudioContext();
  return ctx;
}

/** One square-wave note. `at`/`dur` in seconds relative to now. */
function note(freq: number, at: number, dur: number, volume = 0.045): void {
  const ac = audio();
  const osc = ac.createOscillator();
  const gain = ac.createGain();
  osc.type = "square";
  osc.frequency.value = freq;
  const t0 = ac.currentTime + at;
  // Sharp attack, quick decay — the 8-bit envelope.
  gain.gain.setValueAtTime(0.0001, t0);
  gain.gain.exponentialRampToValueAtTime(volume, t0 + 0.008);
  gain.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
  osc.connect(gain).connect(ac.destination);
  osc.start(t0);
  osc.stop(t0 + dur + 0.02);
}

/** Task finished: quick rising arpeggio (C5 E5 G5 C6). */
export function playSuccess(): void {
  note(523.25, 0, 0.09);
  note(659.25, 0.07, 0.09);
  note(783.99, 0.14, 0.09);
  note(1046.5, 0.21, 0.16, 0.05);
}

/** Needs you (approval/question): insistent double ping. */
export function playAttention(): void {
  note(1318.5, 0, 0.07, 0.05);
  note(1318.5, 0.12, 0.1, 0.05);
}

/** Failure: short descending buzz. */
export function playFail(): void {
  note(392.0, 0, 0.11);
  note(311.13, 0.09, 0.11);
  note(233.08, 0.18, 0.2);
}

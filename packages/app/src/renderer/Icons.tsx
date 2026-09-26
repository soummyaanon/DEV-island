import type { CSSProperties } from "react";
import {
  Accessibility,
  Activity,
  Blocks,
  CircleArrowUp,
  CloudSun,
  Copy,
  Cpu,
  Download,
  type LucideIcon,
  Mic,
  Moon,
  Music,
  Palette,
  Play,
  Power,
  Settings,
  SlidersHorizontal,
  Sparkles,
  SquarePen,
  Volume2,
  VolumeX,
  X,
  Zap,
} from "lucide-react";

/**
 * Icons come from Lucide (ISC) — a consistent 24-grid stroke set that reads
 * like macOS's own symbols. Tree-shaken: only the icons named here ship. Every
 * icon is decorative; the control that wraps it carries the label. Colour is
 * always `currentColor`: gray at rest (`--text-dim`), white on hover.
 */

export type IconName =
  | "speaker"
  | "speaker-slash"
  | "compose"
  | "gear"
  | "power"
  | "send"
  | "moon"
  | "bolt"
  | "cpu"
  | "play"
  | "close"
  | "copy"
  | "sparkles"
  | "mic"
  // Settings sidebar
  | "integrations"
  | "appearance"
  | "sounds"
  | "weather"
  | "live"
  | "accessibility"
  | "general"
  | "updates";

const ICONS: Record<IconName, LucideIcon> = {
  speaker: Volume2,
  "speaker-slash": VolumeX,
  compose: SquarePen,
  gear: Settings,
  power: Power,
  send: CircleArrowUp,
  moon: Moon,
  bolt: Zap,
  cpu: Cpu,
  play: Play,
  close: X,
  copy: Copy,
  sparkles: Sparkles,
  mic: Mic,
  integrations: Blocks,
  appearance: Palette,
  sounds: Music,
  weather: CloudSun,
  live: Activity,
  accessibility: Accessibility,
  general: SlidersHorizontal,
  updates: Download,
};

export function Icon({ name, size = 16, className }: { name: IconName; size?: number; className?: string }) {
  const Glyph = ICONS[name];
  return <Glyph size={size} strokeWidth={1.75} absoluteStrokeWidth className={className} aria-hidden />;
}

/** The ring's colour for a charge level: red → amber → green. */
export function batteryHue(percent: number, low: boolean): number {
  if (low) return 2;
  return Math.round(Math.max(0, Math.min(100, percent)) * 1.3);
}

/**
 * The battery as a ring, like the usage rings: the arc is the charge and runs
 * red through amber to green. On a charger the ring glows and a small bolt
 * sits in the middle (or, with `label`, the percentage stays put and the glow
 * alone says charging); low (on battery) the arc turns red and blinks. Plugging
 * in redraws the arc from empty (`surge`). All CSS on SVG — decorative; the
 * number beside it carries the meaning. `size` is the ring's diameter.
 */
export function Battery({
  percent,
  charging,
  low,
  size = 14,
  surge = false,
  label = false,
  className,
}: {
  percent: number;
  /** On a charger (charging, charged, or AC). */
  charging: boolean;
  low: boolean;
  size?: number;
  /** The moment the charger goes in: the arc fills up from empty. */
  surge?: boolean;
  /** Print the percentage inside the ring, always readable, in place of the bolt. */
  label?: boolean;
  className?: string;
}) {
  const pct = Math.max(0, Math.min(100, percent));
  // A thin arc on a wide radius leaves the most room for the number inside.
  const r = label ? 6.9 : 6.2;
  const stroke = label ? 1.8 : 2;
  const c = 2 * Math.PI * r;
  // A sliver always shows, so an empty battery still reads as a battery.
  const filled = Math.max(0.04, pct / 100);
  const dead = low && !charging;
  const hue = batteryHue(pct, dead);
  const cls = `battery${charging ? " charging" : ""}${dead ? " low" : ""}${surge ? " surge" : ""}${
    pct >= 100 ? " full" : ""
  }${label ? " labelled" : ""}${className ? ` ${className}` : ""}`;
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 16 16"
      className={cls}
      style={{ "--bat-hue": hue, "--ring-c": c.toFixed(2) } as CSSProperties}
      aria-hidden
    >
      <circle cx="8" cy="8" r={r} fill="none" stroke="currentColor" strokeOpacity="0.18" strokeWidth={stroke} />
      <circle
        className="bat-arc"
        cx="8"
        cy="8"
        r={r}
        fill="none"
        stroke={`hsl(${hue} 85% 55%)`}
        strokeWidth={stroke}
        strokeLinecap="round"
        strokeDasharray={c.toFixed(2)}
        strokeDashoffset={(c * (1 - filled)).toFixed(2)}
        transform="rotate(-90 8 8)"
      />
      {label && (
        <text className={`bat-label${pct >= 100 ? " wide" : ""}`} x="8" y="8" dy="0.36em" textAnchor="middle">
          {Math.round(pct)}
        </text>
      )}
      {/* With the number inside, the bolt makes room: the glow says "charging". */}
      {charging && !label && (
        <g className="bat-bolt-wrap">
          <path className="bat-bolt" d="M8.8 4.4 5.8 8.6h2.1l-.7 3 3-4.2H8.1z" fill="#fff" />
        </g>
      )}
    </svg>
  );
}

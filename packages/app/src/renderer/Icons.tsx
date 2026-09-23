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

/**
 * The battery as a small ring — the Watch idiom rather than a bar of text.
 * Static: the arc is set once per reading, nothing animates but the wrapper.
 */
export function BatteryRing({
  percent,
  charging,
  low,
  size = 14,
  className,
}: {
  percent: number;
  /** On a charger (charging, charged, or AC): shows the bolt. */
  charging: boolean;
  low: boolean;
  size?: number;
  className?: string;
}) {
  const p = Math.max(0, Math.min(100, percent)) / 100;
  const r = 6.2;
  const c = 2 * Math.PI * r;
  const tone = low ? "var(--failed)" : charging ? "var(--done)" : "currentColor";
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 16 16"
      className={`ring${className ? ` ${className}` : ""}`}
      aria-hidden
    >
      <circle cx="8" cy="8" r={r} fill="none" stroke="currentColor" strokeOpacity="0.18" strokeWidth="2" />
      <circle
        cx="8"
        cy="8"
        r={r}
        fill="none"
        stroke={tone}
        strokeWidth="2"
        strokeLinecap="round"
        strokeDasharray={c.toFixed(2)}
        strokeDashoffset={(c * (1 - p)).toFixed(2)}
        transform="rotate(-90 8 8)"
      />
      {charging && (
        // Lucide's `zap` outline, scaled into the ring and filled.
        <path
          d="M4 14a1 1 0 0 1-.78-1.63l9.9-10.2a.5.5 0 0 1 .86.46l-1.92 6.02A1 1 0 0 0 13 10h7a1 1 0 0 1 .78 1.63l-9.9 10.2a.5.5 0 0 1-.86-.46l1.92-6.02A1 1 0 0 0 11 14z"
          fill={tone}
          transform="translate(8 8) scale(0.36) translate(-12 -12)"
        />
      )}
    </svg>
  );
}

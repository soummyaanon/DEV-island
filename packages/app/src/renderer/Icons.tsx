import { useId, type CSSProperties } from "react";
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

/** The liquid's colour for a charge level: red → amber → green. */
export function batteryHue(percent: number, low: boolean): number {
  if (low) return 2;
  return Math.round(Math.max(0, Math.min(100, percent)) * 1.3);
}

/** One wobbling liquid surface, as a vertical sine column two periods tall. */
function wavePath(amp: number, period: number, top: number, bottom: number): string {
  let d = `M-40 ${top} L0 ${top}`;
  for (let y = top; y <= bottom; y += 0.5) {
    d += ` L${(Math.sin(((y - top) / period) * Math.PI * 2) * amp).toFixed(2)} ${y}`;
  }
  return `${d} L-40 ${bottom} Z`;
}
const WAVE_PERIOD = 4.9;
const WAVE = wavePath(1.1, WAVE_PERIOD, -WAVE_PERIOD * 2, 15 + WAVE_PERIOD * 2);

/**
 * A liquid battery. The charge is a glowing liquid whose colour runs from red
 * through amber to green and whose surface never stops wobbling. On a
 * charger, sparks of energy stream in, the bolt flickers like a live wire and
 * the whole cell glows; low (on battery) it turns red, blinks and shivers.
 * Plugging in plays a one-off surge (`surge`). All CSS on SVG — decorative;
 * the number beside it carries the meaning. `size` is the glyph's height.
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
  /** The moment the charger goes in: a fill-up sweep and a flash. */
  surge?: boolean;
  /** Print the percentage inside the cell (on a charger it trades places with the bolt). */
  label?: boolean;
  className?: string;
}) {
  const uid = useId().replace(/:/g, "");
  const clipId = `bat-clip-${uid}`;
  const gradId = `bat-grad-${uid}`;
  const pct = Math.max(0, Math.min(100, percent));
  const inner = { x: 2.7, y: 2.7, w: 21.2, h: 9.6 };
  // A sliver always shows, so an empty battery still reads as a battery.
  const level = Math.max(1.8, inner.w * (pct / 100));
  const dead = low && !charging;
  const hue = batteryHue(pct, dead);
  const cls = `battery${charging ? " charging" : ""}${dead ? " low" : ""}${surge ? " surge" : ""}${
    pct >= 100 ? " full" : ""
  }${label ? " labelled" : ""}${className ? ` ${className}` : ""}`;
  return (
    <svg
      width={size * 2}
      height={size}
      viewBox="0 0 30 15"
      className={cls}
      style={{ "--bat-hue": hue, "--bat-run": `${level}px` } as CSSProperties}
      aria-hidden
    >
      <defs>
        <clipPath id={clipId}>
          <rect x={inner.x} y={inner.y} width={inner.w} height={inner.h} rx="2.4" />
        </clipPath>
        <linearGradient id={gradId} x1="0" x2="0" y1="0" y2="1">
          <stop offset="0" stopColor={`hsl(${hue} 95% 68%)`} />
          <stop offset="1" stopColor={`hsl(${hue} 85% 45%)`} />
        </linearGradient>
      </defs>
      <rect className="bat-shell" x="0.8" y="0.8" width="25" height="13.4" rx="4.2" fill="none" strokeWidth="1.3" />
      <rect className="bat-nub" x="27" y="5" width="2.3" height="5" rx="1.1" />
      <g clipPath={`url(#${clipId})`}>
        {/* The liquid: a body up to the level, then the wobbling surface. */}
        <g className="bat-liquid" style={{ transform: `translateX(${(inner.x + level).toFixed(2)}px)` }}>
          <path className="bat-wave" d={WAVE} fill={`url(#${gradId})`} />
        </g>
        {charging && (
          <g className="bat-sparks">
            {[0, 1, 2, 3].map((i) => (
              <circle
                key={i}
                className="bat-spark"
                cx={inner.x}
                cy={4.4 + ((i * 2.3) % 6.2)}
                r="0.75"
                style={{ animationDelay: `${i * 0.33}s` }}
              />
            ))}
          </g>
        )}
        {surge && <rect className="bat-surge" x={inner.x} y={inner.y} width={inner.w} height={inner.h} />}
      </g>
      {label && (
        <text className="bat-label" x="13.4" y="10.7" textAnchor="middle">
          {Math.round(pct)}
        </text>
      )}
      {charging && (
        <g className="bat-bolt-wrap">
          <path
            className="bat-bolt"
            d="M14.6 1.6 9.6 8h3.6l-1.3 5.4 5.1-6.6h-3.7z"
            fill="#fff"
            stroke="#000"
            strokeWidth="1"
            strokeLinejoin="round"
          />
        </g>
      )}
    </svg>
  );
}

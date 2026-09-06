/**
 * Icons in the SF Symbols idiom — 16-unit grid, round caps, 1.6 stroke,
 * `currentColor` — drawn inline so the overlay ships no icon font. Every icon
 * is decorative; the control that wraps it carries the label.
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
  | "cpu";

/** An 8-tooth gear outline on the 16 grid (SF `gearshape` silhouette). */
function gearPath(): string {
  const teeth = 8;
  const outer = 6.9;
  const inner = 5.4;
  const points: string[] = [];
  for (let i = 0; i < teeth; i++) {
    const a0 = (i / teeth) * Math.PI * 2;
    const step = (Math.PI * 2) / teeth;
    const at = (angle: number, r: number) =>
      `${(8 + Math.cos(angle) * r).toFixed(2)} ${(8 + Math.sin(angle) * r).toFixed(2)}`;
    points.push(at(a0 - step * 0.18, outer), at(a0 + step * 0.18, outer));
    points.push(at(a0 + step * 0.32, inner), at(a0 + step * 0.68, inner));
  }
  return `M${points.join("L")}Z`;
}
const GEAR = gearPath();

const STROKE = {
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 1.6,
  strokeLinecap: "round" as const,
  strokeLinejoin: "round" as const,
};

export function Icon({ name, size = 16, className }: { name: IconName; size?: number; className?: string }) {
  const common = { width: size, height: size, viewBox: "0 0 16 16", className, "aria-hidden": true as const };
  switch (name) {
    case "speaker":
      return (
        <svg {...common}>
          <path d="M2.8 6.3h2.1L8.3 3.6v8.8L4.9 9.7H2.8z" fill="currentColor" />
          <path d="M10.6 6a2.9 2.9 0 0 1 0 4" {...STROKE} />
          <path d="M12.6 4.2a5.4 5.4 0 0 1 0 7.6" {...STROKE} />
        </svg>
      );
    case "speaker-slash":
      return (
        <svg {...common}>
          <path d="M2.8 6.3h2.1L8.3 3.6v8.8L4.9 9.7H2.8z" fill="currentColor" />
          <path d="M10.4 6.2l3.6 3.6M14 6.2l-3.6 3.6" {...STROKE} />
        </svg>
      );
    case "compose":
      return (
        <svg {...common}>
          <path d="M8.6 3.6H4.4A1.6 1.6 0 0 0 2.8 5.2v6.4a1.6 1.6 0 0 0 1.6 1.6h6.4a1.6 1.6 0 0 0 1.6-1.6V7.4" {...STROKE} />
          <path d="M12.7 2.4l1.3 1.3-5.6 5.6-1.9.6.6-1.9z" {...STROKE} />
        </svg>
      );
    case "gear":
      return (
        <svg {...common}>
          <path d={GEAR} {...STROKE} strokeWidth={1.4} />
          <circle cx="8" cy="8" r="2.1" {...STROKE} strokeWidth={1.4} />
        </svg>
      );
    case "power":
      return (
        <svg {...common}>
          <path d="M8 2.6v5.6" {...STROKE} />
          <path d="M4.9 5.1a4.6 4.6 0 1 0 6.2 0" {...STROKE} />
        </svg>
      );
    case "send":
      return (
        <svg {...common}>
          <circle cx="8" cy="8" r="6.6" fill="currentColor" />
          <path d="M8 11.2V5.4M5.6 7.6L8 5.2l2.4 2.4" {...STROKE} stroke="#0b0b0d" strokeWidth={1.7} />
        </svg>
      );
    case "moon":
      return (
        <svg {...common}>
          <path d="M9.6 2.4a5.9 5.9 0 1 0 4 10.1 5.1 5.1 0 0 1-4-10.1z" fill="currentColor" />
        </svg>
      );
    case "bolt":
      return (
        <svg {...common}>
          <path d="M9.2 1.6L3.6 9.1h3.7l-.9 5.3 5.9-7.7H8.5z" fill="currentColor" />
        </svg>
      );
    case "cpu":
      return (
        <svg {...common}>
          <rect x="4.3" y="4.3" width="7.4" height="7.4" rx="1.4" {...STROKE} />
          <path d="M6.5 1.8v2.5M9.5 1.8v2.5M6.5 11.7v2.5M9.5 11.7v2.5M1.8 6.5h2.5M1.8 9.5h2.5M11.7 6.5h2.5M11.7 9.5h2.5" {...STROKE} strokeWidth={1.3} />
        </svg>
      );
  }
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
        <path
          d="M9.2 1.6L3.6 9.1h3.7l-.9 5.3 5.9-7.7H8.5z"
          fill={tone}
          transform="translate(8 8) scale(0.5) translate(-8 -8)"
        />
      )}
    </svg>
  );
}

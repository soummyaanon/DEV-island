/**
 * Transient wing content — the island's version of an iOS live activity. A
 * few seconds of "the charger just came in" or "Focus is on", then it yields.
 * Decorative: the aria-label on the wing carries the meaning.
 */

import { Battery, Icon } from "./Icons";

/** System Settings → Battery → Energy Mode, as main reads it from pmset. */
export type EnergyMode = "automatic" | "low" | "high";

export type LiveActivityKind = "battery-plugged" | "battery-unplugged" | "battery-low" | "focus-on" | "focus-off";

export interface LiveActivityProps {
  kind: LiveActivityKind;
  /** Battery percentage for the battery kinds. */
  percent?: number;
  /** Tints and tempers the charger moment. */
  energyMode?: EnergyMode;
}

/** How long a moment stays in the wing before it yields. */
export const LIVE_ACTIVITY_MS: Record<LiveActivityKind, number> = {
  "battery-plugged": 3500,
  "battery-unplugged": 3500,
  "battery-low": 4000,
  "focus-on": 2000,
  "focus-off": 2000,
};

/** Sparks thrown off the ring when the bolt lands; Low Power throws none. */
const SPARKS: Record<EnergyMode, number> = { automatic: 6, low: 0, high: 10 };

export function LiveActivity({ kind, percent = 0, energyMode = "automatic" }: LiveActivityProps) {
  if (kind === "focus-on" || kind === "focus-off") {
    return (
      <span className={`la la-focus ${kind}`} aria-hidden>
        <Icon name="moon" size={11} />
      </span>
    );
  }
  const plugged = kind === "battery-plugged";
  const unplugged = kind === "battery-unplugged";
  const sparks = plugged ? SPARKS[energyMode] : 0;
  return (
    <span
      className={`la la-battery ${kind}${plugged || unplugged ? " la-charge" : ""}${unplugged ? " la-unplug" : ""}`}
      data-energy={plugged ? energyMode : undefined}
      aria-hidden
    >
      <Battery
        size={plugged || unplugged ? 22 : 16}
        percent={percent}
        charging={plugged}
        low={kind === "battery-low"}
        surge={plugged}
        drain={unplugged}
      />
      {sparks > 0 && (
        <svg className="charge-sparks" viewBox="-14 -14 28 28">
          {Array.from({ length: sparks }, (_, i) => (
            <line
              key={i}
              x1="0"
              y1="-8"
              x2="0"
              y2="-13"
              transform={`rotate(${(360 / sparks) * i + (i % 2) * 14})`}
              style={{ animationDelay: `${120 + (i % 3) * 40}ms` }}
            />
          ))}
        </svg>
      )}
    </span>
  );
}

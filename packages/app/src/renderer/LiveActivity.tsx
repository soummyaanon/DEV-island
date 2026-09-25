/**
 * Transient wing content — the island's version of an iOS live activity. A
 * few seconds of "the charger just came in" or "Focus is on", then it yields.
 * Decorative: the aria-label on the wing carries the meaning.
 */

import { Battery, Icon } from "./Icons";

export type LiveActivityKind = "battery-plugged" | "battery-unplugged" | "battery-low" | "focus-on" | "focus-off";

export interface LiveActivityProps {
  kind: LiveActivityKind;
  /** Battery percentage for the battery kinds. */
  percent?: number;
}

/** How long a moment stays in the wing before it yields. */
export const LIVE_ACTIVITY_MS: Record<LiveActivityKind, number> = {
  "battery-plugged": 3500,
  "battery-unplugged": 3500,
  "battery-low": 4000,
  "focus-on": 2000,
  "focus-off": 2000,
};

export function LiveActivity({ kind, percent = 0 }: LiveActivityProps) {
  if (kind === "focus-on" || kind === "focus-off") {
    return (
      <span className={`la la-focus ${kind}`} aria-hidden>
        <Icon name="moon" size={11} />
      </span>
    );
  }
  return (
    <span className={`la la-battery ${kind}`} aria-hidden>
      <Battery
        size={13}
        percent={percent}
        charging={kind === "battery-plugged"}
        low={kind === "battery-low"}
        surge={kind === "battery-plugged"}
      />
    </span>
  );
}

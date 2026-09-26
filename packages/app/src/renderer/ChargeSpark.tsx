import { useId, type RefObject } from "react";
import { EAR, islandOutline, useIslandSize } from "./IslandGlow";
import type { EnergyMode } from "./LiveActivity";

/**
 * The charger went in: current runs in from both ears, down the island's
 * sides and along its bottom into the Mac, crackling as it goes. Its temper
 * follows the Energy Mode — Low Power is a calm amber trickle with no crackle
 * (and less work for the GPU), High Power a fast cyan double surge.
 *
 * The outline is symmetric, so one half is drawn and mirrored: each run goes
 * from an ear to just past the middle, where the hardware notch swallows it.
 * Pulling the plug plays it backwards: the current drains out to the ears.
 * The rim lights along the same outline — ears, sides, rounded bottom, never
 * the top, which is the bezel — so it reads as the island, not a box.
 * Lives as long as the charge pulse does (App unmounts it on animationend).
 */
export function ChargeSpark({
  target,
  energyMode,
  direction,
}: {
  target: RefObject<HTMLElement | null>;
  energyMode: EnergyMode;
  /** "in" as the charger goes in, "out" as it comes out. */
  direction: "in" | "out";
}) {
  const size = useIslandSize(target, true);
  const uid = useId().replace(/:/g, "");
  if (!size || size.w <= 0) return null;

  const edge = islandOutline(size.w, size.h);
  const boxW = size.w + EAR * 2;
  const crackle = energyMode !== "low";
  const run = (
    <g filter={crackle ? `url(#crackle-${uid})` : undefined}>
      <path className="cs-glow" d={edge} pathLength={100} />
      <path className="cs-core" d={edge} pathLength={100} />
    </g>
  );

  return (
    <svg
      className={`charge-spark${direction === "out" ? " out" : ""}`}
      data-energy={energyMode}
      width={boxW}
      height={size.h}
      viewBox={`0 0 ${boxW} ${size.h}`}
      aria-hidden
    >
      {crackle && (
        <defs>
          {/* Noise that reseeds every few frames shoves the line about: a live wire. */}
          <filter id={`crackle-${uid}`} x="-10%" y="-40%" width="120%" height="180%">
            <feTurbulence type="fractalNoise" baseFrequency="0.8" numOctaves={2} seed={1}>
              <animate
                attributeName="seed"
                values="1;4;2;7;3;9;5"
                dur="0.35s"
                calcMode="discrete"
                repeatCount="indefinite"
              />
            </feTurbulence>
            <feDisplacementMap in="SourceGraphic" scale={energyMode === "high" ? 4.5 : 3} />
          </filter>
        </defs>
      )}
      <path className="cs-rim" d={edge} />
      {run}
      <g transform={`translate(${boxW} 0) scale(-1 1)`}>{run}</g>
    </svg>
  );
}

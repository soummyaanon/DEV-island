import { useEffect, useState } from "react";
import { useReducedMotion } from "../a11y";

/**
 * The weather scene: ten conditions, all motion declared in CSS.
 *
 * The overlay runs without hardware acceleration and composites over the menu
 * bar all day, so the rules here are strict and deliberate:
 *
 *  - Only `transform` and `opacity` animate. Never `filter`, `box-shadow`, or a
 *    gradient — those repaint every frame, forever, on the CPU.
 *  - JS never runs per frame. The condition becomes a `data-condition`
 *    attribute and CSS does the rest. Lightning is the sole exception, and it's
 *    one timer every ~10s, not a render loop.
 *  - Element counts are capped and phased by hand rather than randomised, so
 *    the look is stable across re-renders and cheap to reason about.
 *
 * The whole scene is decorative: it's `aria-hidden`, and the textual summary
 * beside it carries the meaning for anyone who can't see it.
 */

export type WeatherCondition =
  | "clear-day"
  | "clear-night"
  | "cloudy"
  | "fog"
  | "rain"
  | "snow"
  | "thunder"
  | "sunrise"
  | "sunset"
  | "rainbow";

/** Hand-placed so the fall reads as a steady curtain rather than a clump. */
const DROPS = [
  { x: 6, delay: 0, dur: 0.72 },
  { x: 17, delay: 0.31, dur: 0.66 },
  { x: 28, delay: 0.12, dur: 0.79 },
  { x: 39, delay: 0.54, dur: 0.7 },
  { x: 48, delay: 0.24, dur: 0.63 },
  { x: 58, delay: 0.44, dur: 0.75 },
  { x: 69, delay: 0.06, dur: 0.68 },
  { x: 78, delay: 0.36, dur: 0.72 },
  { x: 87, delay: 0.18, dur: 0.61 },
  { x: 12, delay: 0.62, dur: 0.77 },
  { x: 63, delay: 0.68, dur: 0.65 },
  { x: 93, delay: 0.49, dur: 0.71 },
];

/** Fewer, slower, and wider apart than rain — snow should feel unhurried. */
const FLAKES = [
  { x: 8, delay: 0, dur: 3.1, size: 3 },
  { x: 22, delay: 0.9, dur: 3.8, size: 2 },
  { x: 34, delay: 1.9, dur: 3.4, size: 3 },
  { x: 46, delay: 0.5, dur: 4.1, size: 2 },
  { x: 57, delay: 2.4, dur: 3.2, size: 3 },
  { x: 68, delay: 1.3, dur: 3.9, size: 2 },
  { x: 79, delay: 2.9, dur: 3.5, size: 3 },
  { x: 90, delay: 0.7, dur: 4.2, size: 2 },
  { x: 15, delay: 3.3, dur: 3.6, size: 2 },
];

const STARS = [
  { x: 12, y: 22, delay: 0 },
  { x: 27, y: 58, delay: 1.4 },
  { x: 41, y: 30, delay: 0.7 },
  { x: 55, y: 66, delay: 2.1 },
  { x: 68, y: 24, delay: 1.1 },
  { x: 81, y: 52, delay: 2.8 },
  { x: 92, y: 34, delay: 0.4 },
];

const CLOUDS = [
  { x: -20, y: 18, scale: 1, dur: 54, delay: 0 },
  { x: 30, y: 46, scale: 0.72, dur: 68, delay: -22 },
  { x: 70, y: 26, scale: 0.86, dur: 61, delay: -44 },
];

function Clouds({ tone }: { tone: "light" | "dark" }) {
  return (
    <span className={`wx-clouds wx-clouds-${tone}`}>
      {CLOUDS.map((cloud, i) => (
        <span
          key={i}
          className="wx-cloud"
          style={{
            left: `${cloud.x}%`,
            top: `${cloud.y}%`,
            // Kept off `transform` so the drift animation owns that channel.
            width: `${28 * cloud.scale}px`,
            height: `${11 * cloud.scale}px`,
            animationDuration: `${cloud.dur}s`,
            animationDelay: `${cloud.delay}s`,
          }}
        />
      ))}
    </span>
  );
}

function Sun() {
  return (
    <span className="wx-sun">
      <span className="wx-sun-disc" />
      <span className="wx-sun-rays" />
    </span>
  );
}

function MoonAndStars() {
  return (
    <>
      <span className="wx-moon" />
      <span className="wx-stars">
        {STARS.map((star, i) => (
          <span
            key={i}
            className="wx-star"
            style={{ left: `${star.x}%`, top: `${star.y}%`, animationDelay: `${star.delay}s` }}
          />
        ))}
      </span>
    </>
  );
}

function Rain() {
  return (
    <span className="wx-rain">
      {DROPS.map((drop, i) => (
        <span
          key={i}
          className="wx-drop"
          style={{
            left: `${drop.x}%`,
            animationDuration: `${drop.dur}s`,
            animationDelay: `${drop.delay}s`,
          }}
        />
      ))}
    </span>
  );
}

function Snow() {
  return (
    <span className="wx-snow">
      {FLAKES.map((flake, i) => (
        <span
          key={i}
          className="wx-flake"
          style={{
            left: `${flake.x}%`,
            width: `${flake.size}px`,
            height: `${flake.size}px`,
            animationDuration: `${flake.dur}s`,
            animationDelay: `${flake.delay}s`,
          }}
        />
      ))}
    </span>
  );
}

/**
 * Thunder: clouds most of the time, a triple-stab flash every 6–14s.
 *
 * Randomised timing rather than a fixed loop, because a metronome reads as a
 * broken UI while irregularity reads as weather. Under reduced motion the timer
 * is never armed at all — CSS alone could stop the flash animating but not this
 * component from re-rendering every few seconds.
 */
function Thunder({ still }: { still: boolean }) {
  const [strike, setStrike] = useState(0);

  useEffect(() => {
    if (still) return;
    let timer = 0;
    const arm = (): void => {
      timer = window.setTimeout(
        () => {
          setStrike((n) => n + 1);
          arm();
        },
        6000 + Math.random() * 8000,
      );
    };
    arm();
    return () => window.clearTimeout(timer);
  }, [still]);

  return (
    <>
      <Clouds tone="dark" />
      {/* Keyed on the strike count so each one restarts the animation. */}
      {strike > 0 && <span key={`f${strike}`} className="wx-flash" />}
      <svg
        key={`b${strike}`}
        className="wx-bolt"
        viewBox="0 0 12 20"
        preserveAspectRatio="xMidYMid meet"
      >
        <path d="M7.2 0 1 11h3.4L3.4 20 10.6 8H7z" />
      </svg>
    </>
  );
}

function Fog() {
  return (
    <span className="wx-fog">
      <span className="wx-fog-band" />
      <span className="wx-fog-band" />
    </span>
  );
}

function Golden({ kind }: { kind: "sunrise" | "sunset" }) {
  return (
    <span className={`wx-golden wx-${kind}`}>
      {/* Two stacked static gradients cross-fading: interpolating one gradient
          into another repaints, cross-fading two opacities does not. */}
      <span className="wx-sky wx-sky-a" />
      <span className="wx-sky wx-sky-b" />
      <span className="wx-horizon-sun" />
    </span>
  );
}

/** Outermost first — red on the outside, violet on the inside. */
const RAINBOW_BANDS = ["#ff5f56", "#ffb020", "#ffe66d", "#4ecb8d", "#5ba8ff", "#a98cff"];

function Rainbow() {
  return (
    <span className="wx-rainbow">
      <svg viewBox="0 0 100 46" preserveAspectRatio="none">
        {/* Each band's ENDPOINTS move inward with its radius. Concentric arcs
            between fixed endpoints are geometrically impossible — an arc
            spanning a chord of 2r needs a radius of at least r, so SVG silently
            clamps every smaller radius up and draws six identical paths.
            non-scaling-stroke keeps the bands even despite the non-uniform
            scale this wide, short box implies. */}
        {RAINBOW_BANDS.map((color, i) => {
          const rx = 46 - i * 5;
          const ry = 40 - i * 5;
          return (
            <path
              key={color}
              d={`M ${50 - rx} 46 A ${rx} ${ry} 0 0 1 ${50 + rx} 46`}
              fill="none"
              stroke={color}
              vectorEffect="non-scaling-stroke"
            />
          );
        })}
      </svg>
      <Sun />
    </span>
  );
}

function Layers({ condition, still }: { condition: WeatherCondition; still: boolean }) {
  switch (condition) {
    case "clear-day":
      return <Sun />;
    case "clear-night":
      return <MoonAndStars />;
    case "cloudy":
      return <Clouds tone="light" />;
    case "fog":
      return <Fog />;
    case "rain":
      return (
        <>
          <Clouds tone="dark" />
          <Rain />
        </>
      );
    case "snow":
      return (
        <>
          <Clouds tone="light" />
          <Snow />
        </>
      );
    case "thunder":
      return <Thunder still={still} />;
    case "sunrise":
    case "sunset":
      return <Golden kind={condition} />;
    case "rainbow":
      return <Rainbow />;
  }
}

/**
 * `ambient` is the tiny strip beside the notch when nothing else is happening;
 * `card` is the wider panel version. Same layers, different box — the sizes come
 * from CSS so no layer needs to know which it's in.
 */
export function WeatherScene({
  condition,
  variant,
}: {
  condition: WeatherCondition;
  variant: "ambient" | "card";
}) {
  const still = useReducedMotion();
  return (
    <span className={`wx wx-${variant}`} data-condition={condition} aria-hidden>
      <Layers condition={condition} still={still} />
    </span>
  );
}

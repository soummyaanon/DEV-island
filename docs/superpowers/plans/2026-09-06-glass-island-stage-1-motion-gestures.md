# Glass Island — Stage 1: Motion + Gestures — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the island's single hand-tuned bezier with real spring physics baked into CSS `linear()` easings, add entrance choreography (staggered rows, cards, sprite pop, rolling count), and add two-finger swipe gestures with an "Open with: hover / swipe" setting.

**Architecture:** A pure spring sampler (`renderer/motion.ts`) publishes two easings and their durations as CSS custom properties on `<html>` once at startup; every transition and keyframe in `island.css` reads those variables, so the budget rule (only `transform`/`opacity` animate, no JS frame loop) holds. A pure wheel accumulator (`renderer/gesture.ts`) turns forwarded wheel deltas into "open"/"close" decisions and a rubber-band fraction; `App.tsx` maps them onto the existing `hovering`/`expanded`/`interactive` state. Main reads the macOS natural-scrolling preference once so "swipe down" means the fingers moved down on every Mac.

**Tech Stack:** Electron 35 (Chromium 134 — supports CSS `linear()`), React 19, TypeScript 5.8, vitest 3 (node environment, no DOM; component tests use `renderToStaticMarkup`). Package: `packages/app`. Run tests with `pnpm --filter @agent-island/app test`, typecheck with `pnpm --filter @agent-island/app typecheck`, dev app with `pnpm --filter @agent-island/app dev`.

**Spec:** `docs/superpowers/specs/2026-09-06-glass-island-design.md` (sections "Budget", "Stage 1").

## Global Constraints

- Only `transform` and `opacity` animate in CSS. Never `filter`, `box-shadow`, `backdrop-filter`, `background`, `width` via keyframes. (`width`/`border-radius`/`grid-template-rows` **transitions** on the island are the pre-existing exceptions and stay.)
- No JS frame loop (`requestAnimationFrame` loops, `setInterval` at frame rate). Motion is declarative CSS keyed off classes/attributes/custom properties; JS only swaps values.
- Nothing animates unseen: every new animation must be frozen by the existing `.app.paused *` rule (it uses `animation-play-state: paused !important`, so any CSS animation qualifies automatically).
- **The black band (`.notch-spacer`) never transforms.** It must stay pixel-aligned with the hardware notch.
- Reduced Motion: every new animation/transition is disabled in the `@media (prefers-reduced-motion: reduce)` block, and JS-published easings become a step with 1ms duration.
- Font sizes come from `styles/tokens.css` tokens; never hard-code a px font size.
- Default behavior for existing users is unchanged: `openWith` defaults to `hover`.
- Commit after every task with a message in the repo's sentence style (`Motion: …`, `Gestures: …`).

## File structure

| File | Responsibility |
| --- | --- |
| `packages/app/src/renderer/motion.ts` (new) | Pure spring integration → CSS `linear()` easing string + settle duration. Reduced-motion step variant. |
| `packages/app/src/renderer/motion.test.ts` (new) | Ranges for overshoot/settle/duration; endpoints; step variant. |
| `packages/app/src/renderer/gesture.ts` (new) | Pure `WheelGesture` accumulator (sliding window, threshold, lock-out, progress). |
| `packages/app/src/renderer/gesture.test.ts` (new) | Threshold, expiry, lock, both directions, progress clamp. |
| `packages/app/src/main/scroll-direction.ts` (new) | Read `com.apple.swipescrolldirection` once; pure parser. |
| `packages/app/src/main/scroll-direction.test.ts` (new) | Parser table. |
| `packages/app/src/renderer/styles/tokens.css` (modify) | Default values for `--spring-open`, `--dur-open`, `--spring-settle`, `--dur-settle`, `--dur-close`. |
| `packages/app/src/renderer/styles/island.css` (modify) | Transitions read the motion variables; new keyframes `row-in`, `card-in`, `sprite-pop`, `count-roll`; rubber-band transforms; reduced-motion additions. |
| `packages/app/src/renderer/App.tsx` (modify) | Publish springs; `settled` class; sprite slots; count roll span; row index; gesture wiring; `openWith` prefs. |
| `packages/app/src/renderer/SessionRow.tsx` (modify) | Accepts `index` and sets `--i` for the stagger. |
| `packages/app/src/main/settings.ts` (modify) | `openWith` setting. |
| `packages/app/src/main/index.ts` (modify) | `applySetting("openWith")`, `uiPrefs()` carries `openWith` + `naturalScroll`. |
| `packages/app/src/preload/index.ts` (modify) | `UiPrefs.openWith`, `UiPrefs.naturalScroll`, `SettingsState.openWith`. |
| `packages/app/src/renderer/settings.tsx` (modify) | New **Appearance** section with a `Segmented` control for "Open with". |
| `packages/app/src/renderer/styles/settings.css` (modify) | `.s-seg` segmented control styles. |
| `docs/STATUS.md` (modify) | Stage 1 entry. |

---

### Task 1: Spring sampler — `renderer/motion.ts`

**Files:**
- Create: `packages/app/src/renderer/motion.ts`
- Test: `packages/app/src/renderer/motion.test.ts`

**Interfaces:**
- Produces:
  ```ts
  export interface SpringConfig { stiffness: number; damping: number; mass: number }
  export interface SpringEasing { easing: string; ms: number }
  export const OPEN_SPRING: SpringConfig;    // { stiffness: 380, damping: 28, mass: 1 }
  export const SETTLE_SPRING: SpringConfig;  // { stiffness: 380, damping: 36, mass: 1 }
  export const STEP_EASING: SpringEasing;    // { easing: "linear(0, 1)", ms: 1 }
  export function sampleSpring(cfg: SpringConfig, samples?: number): { values: number[]; ms: number }
  export function springEasing(cfg: SpringConfig, samples?: number): SpringEasing
  ```

- [ ] **Step 1: Write the failing test**

```ts
// packages/app/src/renderer/motion.test.ts
import { describe, expect, it } from "vitest";
import {
  OPEN_SPRING,
  SETTLE_SPRING,
  STEP_EASING,
  sampleSpring,
  springEasing,
} from "./motion";

describe("sampleSpring", () => {
  it("starts at 0 and ends exactly at 1", () => {
    const { values } = sampleSpring(OPEN_SPRING);
    expect(values[0]).toBe(0);
    expect(values[values.length - 1]).toBe(1);
  });

  it("the open spring overshoots a little, then settles in under 600ms", () => {
    const { values, ms } = sampleSpring(OPEN_SPRING);
    const peak = Math.max(...values);
    expect(peak).toBeGreaterThan(1.02);
    expect(peak).toBeLessThan(1.08);
    expect(ms).toBeGreaterThanOrEqual(300);
    expect(ms).toBeLessThanOrEqual(600);
  });

  it("the settle spring never visibly overshoots and is quicker", () => {
    const { values, ms } = sampleSpring(SETTLE_SPRING);
    expect(Math.max(...values)).toBeLessThanOrEqual(1.005);
    expect(ms).toBeGreaterThanOrEqual(200);
    expect(ms).toBeLessThanOrEqual(450);
  });

  it("returns the requested number of samples", () => {
    expect(sampleSpring(OPEN_SPRING, 12).values).toHaveLength(12);
  });

  it("caps runaway springs at the integration ceiling instead of looping forever", () => {
    const { ms } = sampleSpring({ stiffness: 400, damping: 0.1, mass: 1 });
    expect(ms).toBe(1500);
  });
});

describe("springEasing", () => {
  it("emits a CSS linear() with evenly spaced stops", () => {
    const { easing, ms } = springEasing(OPEN_SPRING, 5);
    expect(easing.startsWith("linear(0, ")).toBe(true);
    expect(easing.endsWith(", 1)")).toBe(true);
    expect(easing.split(",").length).toBe(5);
    expect(ms).toBeGreaterThan(0);
  });

  it("rounds stops to three decimals so the string stays short", () => {
    const { easing } = springEasing(OPEN_SPRING, 40);
    for (const stop of easing.slice("linear(".length, -1).split(", ")) {
      expect(stop).toMatch(/^-?\d+(\.\d{1,3})?$/);
    }
  });
});

describe("STEP_EASING", () => {
  it("is an instant step for reduced motion", () => {
    expect(STEP_EASING).toEqual({ easing: "linear(0, 1)", ms: 1 });
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pnpm --filter @agent-island/app test -- motion`
Expected: FAIL — `Cannot find module './motion'`.

- [ ] **Step 3: Write the implementation**

```ts
// packages/app/src/renderer/motion.ts
/**
 * Spring motion for the island, precomputed into CSS `linear()` easings.
 *
 * The overlay composites over the menu bar all day with hardware acceleration
 * off, so motion must stay declarative: no JS frame loop. A damped spring is
 * integrated ONCE here, sampled, and published as a `linear()` timing function
 * plus its settle time; CSS transitions and keyframes then read the variables.
 *
 * Pure on purpose — vitest covers the physics without a DOM.
 */

export interface SpringConfig {
  /** N/m — higher is snappier. */
  stiffness: number;
  /** N·s/m — higher settles sooner; below critical (2·√(k·m)) it overshoots. */
  damping: number;
  mass: number;
}

export interface SpringEasing {
  /** A CSS `linear(...)` timing function with evenly spaced stops. */
  easing: string;
  /** How long the spring takes to settle, in ms. Use as the duration. */
  ms: number;
}

/** Opening: lands with ~4% overshoot, settles in ~400ms. */
export const OPEN_SPRING: SpringConfig = { stiffness: 380, damping: 28, mass: 1 };
/** Adjusting while already open, and the count roll: firm, no visible overshoot, ~300ms. */
export const SETTLE_SPRING: SpringConfig = { stiffness: 380, damping: 36, mass: 1 };
/** Reduced motion: a step. 1ms rather than 0 so `transitionend` still fires. */
export const STEP_EASING: SpringEasing = { easing: "linear(0, 1)", ms: 1 };

/** Integration step (s) and ceiling (ms) for a spring that never settles. */
const DT = 0.001;
const MAX_MS = 1500;
/** Settled when within 0.5% of the target and nearly still — visually at rest. */
const SETTLE_DISTANCE = 0.005;
const SETTLE_VELOCITY = 0.1;

/**
 * Integrate a unit spring (0 → 1) with semi-implicit Euler at 1ms steps, then
 * sample the trajectory evenly over its settle time. The last sample is pinned
 * to exactly 1 so the easing always lands on the final value.
 */
export function sampleSpring(cfg: SpringConfig, samples = 48): { values: number[]; ms: number } {
  const trajectory: number[] = [0];
  let x = 0;
  let v = 0;
  let settledAt = MAX_MS;
  for (let step = 1; step <= MAX_MS; step++) {
    const acceleration = (cfg.stiffness * (1 - x) - cfg.damping * v) / cfg.mass;
    v += acceleration * DT;
    x += v * DT;
    trajectory.push(x);
    if (Math.abs(1 - x) < SETTLE_DISTANCE && Math.abs(v) < SETTLE_VELOCITY) {
      settledAt = step;
      break;
    }
  }

  const count = Math.max(2, Math.floor(samples));
  const values: number[] = [];
  for (let i = 0; i < count; i++) {
    const t = Math.round((i / (count - 1)) * settledAt);
    values.push(trajectory[Math.min(t, trajectory.length - 1)]);
  }
  values[0] = 0;
  values[count - 1] = 1;
  return { values, ms: settledAt };
}

/** The same trajectory as a CSS timing function string. */
export function springEasing(cfg: SpringConfig, samples = 48): SpringEasing {
  const { values, ms } = sampleSpring(cfg, samples);
  const stops = values.map((value) => String(Math.round(value * 1000) / 1000));
  return { easing: `linear(${stops.join(", ")})`, ms };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pnpm --filter @agent-island/app test -- motion`
Expected: PASS (8 tests). If the overshoot or duration range assertions fail, adjust **only** `SETTLE_DISTANCE`/`SETTLE_VELOCITY` or the two `SpringConfig` constants until the open spring peaks between 1.02 and 1.08 and settles between 300 and 600ms; do not loosen the test.

- [ ] **Step 5: Commit**

```bash
git add packages/app/src/renderer/motion.ts packages/app/src/renderer/motion.test.ts
git commit -m "Motion: pure spring sampler that emits CSS linear() easings"
```

---

### Task 2: Publish the springs and move the island onto them

**Files:**
- Modify: `packages/app/src/renderer/styles/tokens.css` (append to the `:root` block)
- Modify: `packages/app/src/renderer/styles/island.css:57-79` (the `--motion` block and `.island` / `.island.expanded` transitions), `:244-263` (`.panel-wrap` / `.panel`)
- Modify: `packages/app/src/renderer/App.tsx` (new effect after the text-scale effect near line 306; `onTransitionEnd` + `settled` class on the `.island` div near line 440)

**Interfaces:**
- Consumes: `springEasing`, `OPEN_SPRING`, `SETTLE_SPRING`, `STEP_EASING` from Task 1; `useReducedMotion()` from `renderer/a11y.ts` (returns `boolean`, already exists).
- Produces: CSS custom properties on `<html>`: `--spring-open`, `--dur-open`, `--spring-settle`, `--dur-settle`. CSS class `.island.settled` (present once the open transition finished, cleared on collapse).

- [ ] **Step 1: Add fallback motion tokens**

Append inside the `:root { … }` block of `packages/app/src/renderer/styles/tokens.css` (after `--max-question`):

```css
  /* Motion. JS replaces the two springs with sampled linear() curves at
     startup (renderer/motion.ts); these fallbacks keep the first paint moving
     with the old overshoot bezier if a render lands before that. Collapse is
     deliberately not a spring: things leave faster than they arrive. */
  --spring-open: cubic-bezier(0.34, 1.2, 0.64, 1);
  --dur-open: 400ms;
  --spring-settle: cubic-bezier(0.22, 1, 0.36, 1);
  --dur-settle: 300ms;
  --dur-close: 180ms;
```

- [ ] **Step 2: Point the island transitions at the tokens**

In `packages/app/src/renderer/styles/island.css`, replace the block from the `:root { --motion … }` rule through `.island.expanded { … }` (currently lines ~57–79) with:

```css
/* Motion comes from the spring tokens in tokens.css (published by
   renderer/motion.ts). Collapsed → expanded uses the open spring; width
   changes while already open (content growth) use the firmer settle spring;
   collapsing eases in over --dur-close. */

/* All widths derive from the measured hardware notch (--notch-width is set at
   runtime by main via JXA/NSScreen; 196px is the fallback for unknown). Wings
   get generous room: sprite row on the left, count badge on the right. */
.island {
  width: calc(var(--notch-width, 196px) + 68px);
  background: #000;
  border-radius: 0 0 12px 12px;
  overflow: hidden;
  transition:
    width var(--dur-close) ease-in,
    border-radius var(--dur-close) ease-in;
}

/* Expanded width is measured from the content (see island-width.ts) and handed
   over as --island-w. The fallback is the old fixed width, so a render before
   the first measurement — or with the measurement disabled — looks exactly like
   it used to. */
.island.expanded {
  width: var(--island-w, max(360px, calc(var(--notch-width, 196px) + 110px)));
  border-radius: 0 0 16px 16px;
  transition:
    width var(--dur-open) var(--spring-open),
    border-radius var(--dur-open) var(--spring-open);
}
/* Already open and merely growing to fit new content: firm, no bounce. */
.island.expanded.settled {
  transition:
    width var(--dur-settle) var(--spring-settle),
    border-radius var(--dur-settle) var(--spring-settle);
}
```

Then replace the `.panel-wrap` / `.island.expanded .panel-wrap` / `.panel` / `.island.expanded .panel` rules (currently lines ~244–263) with:

```css
/* ---- Expanding panel ---- */
.panel-wrap {
  display: grid;
  grid-template-rows: 0fr;
  transition: grid-template-rows var(--dur-close) ease-in;
}
.island.expanded .panel-wrap {
  grid-template-rows: 1fr;
  transition: grid-template-rows var(--dur-open) var(--spring-open);
}
.panel {
  overflow: hidden;
  min-height: 0;
  opacity: 0;
  transform: translateY(-8px) scale(0.985);
  transition:
    opacity 80ms ease-in,
    transform var(--dur-close) ease-in;
}
.island.expanded .panel {
  opacity: 1;
  transform: none;
  transition:
    opacity 120ms ease-out,
    transform var(--dur-open) var(--spring-open);
}
```

Also delete the now-unused `--motion` definition (`:root { --motion: … }`) — grep first: `grep -n "var(--motion)" packages/app/src/renderer/styles/*.css` must return nothing before removing it. If anything else still uses it, leave the definition in place.

- [ ] **Step 3: Publish the springs from App.tsx**

Add the import at the top of `packages/app/src/renderer/App.tsx`:

```ts
import { OPEN_SPRING, SETTLE_SPRING, STEP_EASING, springEasing } from "./motion";
import { useReducedMotion } from "./a11y";
```

(`useReducedMotion` is exported from `./a11y`; merge it into the existing `./a11y` import line instead of a second import.)

Inside `App()`, after the text-scale effect (`// Text scale (our stand-in for Dynamic Type…`), add:

```tsx
  // Spring motion: integrate once, publish as CSS timing functions. Reduced
  // Motion swaps both for a 1ms step so CSS and any JS timing agree.
  const reducedMotion = useReducedMotion();
  useEffect(() => {
    const open = reducedMotion ? STEP_EASING : springEasing(OPEN_SPRING);
    const settle = reducedMotion ? STEP_EASING : springEasing(SETTLE_SPRING);
    const root = document.documentElement.style;
    root.setProperty("--spring-open", open.easing);
    root.setProperty("--dur-open", `${open.ms}ms`);
    root.setProperty("--spring-settle", settle.easing);
    root.setProperty("--dur-settle", `${settle.ms}ms`);
  }, [reducedMotion]);

  // Once the open transition lands, further width changes use the firm spring.
  const [settled, setSettled] = useState(false);
  useEffect(() => {
    if (!expanded) setSettled(false);
  }, [expanded]);
```

Then on the `.island` div in the JSX, add the class and handler:

```tsx
        <div
          className={`island ${stateCls}${expanded ? " expanded" : ""}${settled ? " settled" : ""}${
            sessions.length === 0 && !ambientWeather ? " bare" : ""
          }${showFeast ? " has-pac" : ""}${ambientWeather ? " has-weather" : ""} spr-${
            showFeast ? 0 : shown.length
          }`}
          role="region"
          aria-label="Agent Island"
          onTransitionEnd={(e) => {
            if (e.target === e.currentTarget && e.propertyName === "width" && expanded) setSettled(true);
          }}
        >
```

- [ ] **Step 4: Typecheck and run the existing tests**

Run: `pnpm --filter @agent-island/app typecheck && pnpm --filter @agent-island/app test`
Expected: both pass.

- [ ] **Step 5: Manual check in the dev app**

Run: `pnpm --filter @agent-island/app dev` (kill stale instances first: `pkill -f electron@35.7.5`). Hover the notch with a session running (`node scripts/claude-smoke.mjs` produces one).
Expected: the panel opens with a visible small overshoot and settles; closing is quicker; no jitter on the black band. In DevTools console: `getComputedStyle(document.documentElement).getPropertyValue("--spring-open")` starts with `linear(`.

- [ ] **Step 6: Commit**

```bash
git add packages/app/src/renderer/styles/tokens.css packages/app/src/renderer/styles/island.css packages/app/src/renderer/App.tsx
git commit -m "Motion: island, panel, and rows transition on sampled springs"
```

---

### Task 3: Entrance choreography — rows, cards, sprites, count

**Files:**
- Modify: `packages/app/src/renderer/styles/island.css` (append keyframes after the `.panel` rules; extend the reduced-motion block near line ~990)
- Modify: `packages/app/src/renderer/SessionRow.tsx` (new `index` prop → `--i`)
- Modify: `packages/app/src/renderer/App.tsx` (sprite slots ~line 466, count span ~line 476, row index ~line 510)
- Test: `packages/app/src/renderer/SessionRow.test.tsx` (one added case)

**Interfaces:**
- Consumes: `--dur-open`, `--spring-open`, `--dur-settle`, `--spring-settle` (Task 2).
- Produces: `SessionRow` prop `index: number`; CSS classes `.sprite-slot`, keyframes `row-in`, `card-in`, `sprite-pop`, `count-roll`.

- [ ] **Step 1: Write the failing test for the stagger index**

Append to `packages/app/src/renderer/SessionRow.test.tsx` inside the existing `describe` (use the file's existing `session()` helper):

```tsx
  it("exposes its stagger index as --i for the entrance animation", () => {
    const html = renderToStaticMarkup(
      <SessionRow session={session()} now={Date.parse("2026-07-19T10:00:30.000Z")} index={3} onJump={() => {}} />,
    );
    expect(html).toContain("--i:3");
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `pnpm --filter @agent-island/app test -- SessionRow`
Expected: FAIL — TypeScript/vitest complains `index` is not a known prop, or the markup lacks `--i:3`.

- [ ] **Step 3: Add the prop to SessionRow**

In `packages/app/src/renderer/SessionRow.tsx`, change the component signature and the `<button>`:

```tsx
export function SessionRow({
  session,
  now,
  index,
  onJump,
}: {
  session: SessionSnapshot;
  now: number;
  /** Position in the list — drives the entrance stagger (`--i`). */
  index: number;
  onJump: (session: SessionSnapshot) => void;
}) {
```

and on the button element add the style (keep every existing attribute):

```tsx
      <button
        type="button"
        className={`row state-${session.state}`}
        style={{ "--i": index } as React.CSSProperties}
```

`React` is not imported as a namespace in this file; add `import type { CSSProperties } from "react";` at the top and use `as CSSProperties` instead of `as React.CSSProperties`.

In `App.tsx`, pass the index where rows render:

```tsx
                {visible.map((s, i) => (
                  <SessionRow
                    key={s.key}
                    session={s}
                    now={now}
                    index={i}
                    onJump={(sess) => window.agentIsland.jump(sess)}
                  />
                ))}
```

- [ ] **Step 4: Wrap the wing sprites and the count so they can animate**

In `App.tsx`, the `.sprites` span currently renders `PacFeast`, `WeatherScene`, or the sprite list directly. Wrap each in a slot:

```tsx
            <span className="sprites">
              {showFeast ? (
                <span className="sprite-slot" key="feast">
                  <PacFeast kinds={activeKinds} />
                </span>
              ) : ambientWeather ? (
                <span className="sprite-slot" key="weather">
                  <WeatherScene condition={condition} variant="ambient" />
                </span>
              ) : (
                shown.map(({ kind, Sprite }) => (
                  <span className="sprite-slot" key={kind}>
                    <Sprite live />
                  </span>
                ))
              )}
            </span>
```

And the count: compute the text once and key a span by it so a changed value remounts (and therefore replays `count-roll`):

```tsx
            {(() => {
              const countText =
                needsYou.length > 0
                  ? `${needsYou.length}!`
                  : active.length > 0
                    ? String(active.length)
                    : ambientWeather
                      ? (weather?.temperature ?? "")
                      : "";
              return (
                <span
                  className="spacer-info"
                  aria-label={
                    needsYou.length > 0
                      ? `${needsYou.length} sessions need attention`
                      : ambientWeather
                        ? weather?.summary
                        : `${active.length} active sessions`
                  }
                >
                  <span key={countText}>{countText}</span>
                </span>
              );
            })()}
```

- [ ] **Step 5: Add the keyframes and the reduced-motion exclusions**

Append to `packages/app/src/renderer/styles/island.css` right after the `.island.expanded .panel { … }` rule:

```css
/* ---- Entrance choreography ----
   Everything below is transform/opacity only and starts matching when
   `.expanded` is added (or when the element mounts), so each plays once per
   open — a row re-render doesn't remount and doesn't replay. */
.island.expanded .row {
  animation: row-in var(--dur-open) var(--spring-open) both;
  animation-delay: calc(var(--i, 0) * 22ms);
}
@keyframes row-in {
  from {
    opacity: 0;
    transform: translateY(6px);
  }
  to {
    opacity: 1;
    transform: none;
  }
}
.island.expanded .approval,
.island.expanded .question {
  animation: card-in var(--dur-open) var(--spring-open) both;
}
@keyframes card-in {
  from {
    opacity: 0;
    transform: translateY(-6px) scale(0.98);
  }
  to {
    opacity: 1;
    transform: none;
  }
}
/* A sprite (or the feast / weather strip) arriving in the wing pops in. The
   wrapper animates so the sprites' own spin/bob/frame animations are untouched. */
.sprite-slot {
  display: inline-flex;
  align-items: center;
  animation: sprite-pop var(--dur-open) var(--spring-open) both;
}
@keyframes sprite-pop {
  0% {
    opacity: 0;
    transform: scale(0.6);
  }
  60% {
    opacity: 1;
    transform: scale(1.12);
  }
  100% {
    opacity: 1;
    transform: none;
  }
}
/* The count rolls in like a counter: the value is keyed, so a change remounts. */
.spacer-info > span {
  display: inline-block;
  animation: count-roll var(--dur-settle) var(--spring-settle) both;
}
@keyframes count-roll {
  from {
    opacity: 0;
    transform: translateY(8px);
  }
  to {
    opacity: 1;
    transform: none;
  }
}
```

The `.sprites` rule has `gap: 5px` between direct children; `.sprite-slot` is now the direct child, so spacing is preserved.

Extend the existing `@media (prefers-reduced-motion: reduce) { … }` block: add these rules inside it.

```css
  .island.expanded .row,
  .island.expanded .approval,
  .island.expanded .question,
  .sprite-slot,
  .spacer-info > span {
    animation: none;
  }
```

- [ ] **Step 6: Run tests and typecheck**

Run: `pnpm --filter @agent-island/app typecheck && pnpm --filter @agent-island/app test`
Expected: PASS, including the new SessionRow case.

- [ ] **Step 7: Manual check**

Dev app, two sessions running. Expected: rows fade/rise in one after another; a new agent's sprite pops into the wing; the count rolls when it changes; with System Settings → Accessibility → Display → Reduce motion ON, everything appears instantly.

- [ ] **Step 8: Commit**

```bash
git add packages/app/src/renderer/styles/island.css packages/app/src/renderer/SessionRow.tsx packages/app/src/renderer/SessionRow.test.tsx packages/app/src/renderer/App.tsx
git commit -m "Motion: staggered rows, card and sprite entrances, rolling count"
```

---

### Task 4: Wheel gesture accumulator — `renderer/gesture.ts`

**Files:**
- Create: `packages/app/src/renderer/gesture.ts`
- Test: `packages/app/src/renderer/gesture.test.ts`

**Interfaces:**
- Produces:
  ```ts
  export type SwipeDirection = "down" | "up";
  export interface WheelGestureOptions { windowMs?: number; thresholdPx?: number; lockMs?: number }
  export class WheelGesture {
    constructor(opts?: WheelGestureOptions);
    /** fingerDy > 0 means the fingers moved DOWN. `now` in ms. */
    feed(fingerDy: number, now: number): SwipeDirection | null;
    /** −1..1 fraction toward the threshold; positive = pulling down. 0 while locked. */
    progress(now: number): number;
    reset(): void;
  }
  export function fingerDelta(wheelDeltaY: number, naturalScroll: boolean): number;
  ```

- [ ] **Step 1: Write the failing test**

```ts
// packages/app/src/renderer/gesture.test.ts
import { describe, expect, it } from "vitest";
import { WheelGesture, fingerDelta } from "./gesture";

describe("WheelGesture", () => {
  it("fires 'down' once the window's sum crosses the threshold", () => {
    const g = new WheelGesture({ thresholdPx: 28 });
    expect(g.feed(10, 0)).toBeNull();
    expect(g.feed(10, 20)).toBeNull();
    expect(g.feed(10, 40)).toBe("down");
  });

  it("fires 'up' for negative deltas", () => {
    const g = new WheelGesture({ thresholdPx: 28 });
    g.feed(-15, 0);
    expect(g.feed(-15, 10)).toBe("up");
  });

  it("forgets deltas older than the window", () => {
    const g = new WheelGesture({ windowMs: 160, thresholdPx: 28 });
    g.feed(20, 0);
    expect(g.feed(10, 500)).toBeNull(); // the 20 expired; only 10 counts
  });

  it("locks out further decisions after firing", () => {
    const g = new WheelGesture({ thresholdPx: 28, lockMs: 250 });
    expect(g.feed(30, 0)).toBe("down");
    expect(g.feed(30, 100)).toBeNull();
    expect(g.feed(30, 249)).toBeNull();
    expect(g.feed(30, 251)).toBe("down");
  });

  it("reports progress toward the threshold, clamped", () => {
    const g = new WheelGesture({ thresholdPx: 40 });
    g.feed(10, 0);
    expect(g.progress(0)).toBeCloseTo(0.25);
    g.feed(-30, 5);
    expect(g.progress(5)).toBeCloseTo(-0.5);
    g.feed(-100, 6); // fires "up" and locks
    expect(g.progress(6)).toBe(0);
  });

  it("progress decays to 0 once the window expires", () => {
    const g = new WheelGesture({ windowMs: 160, thresholdPx: 40 });
    g.feed(20, 0);
    expect(g.progress(1000)).toBe(0);
  });

  it("reset clears everything including the lock", () => {
    const g = new WheelGesture({ thresholdPx: 28, lockMs: 250 });
    g.feed(30, 0);
    g.reset();
    expect(g.feed(30, 1)).toBe("down");
  });
});

describe("fingerDelta", () => {
  it("with natural scrolling, a positive wheel delta means the fingers moved up", () => {
    expect(fingerDelta(12, true)).toBe(-12);
  });
  it("without natural scrolling, wheel and finger directions agree", () => {
    expect(fingerDelta(12, false)).toBe(12);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `pnpm --filter @agent-island/app test -- gesture`
Expected: FAIL — `Cannot find module './gesture'`.

- [ ] **Step 3: Implement**

```ts
// packages/app/src/renderer/gesture.ts
/**
 * Two-finger swipe detection from wheel events.
 *
 * Wheel events are the only trackpad signal a web view gets, and they arrive
 * as a stream of small deltas. This accumulates them over a short sliding
 * window, fires once the sum crosses a threshold, then locks briefly so the
 * tail of the same swipe can't fire twice. Pure — no DOM, no timers — so the
 * thresholds are unit-tested and App.tsx stays plumbing.
 *
 * Direction is expressed as FINGER motion (down = fingers moved down), never
 * raw wheel sign: with macOS "natural scrolling" the two are inverted, and the
 * island's gestures must mean the same thing on every Mac.
 */

export type SwipeDirection = "down" | "up";

export interface WheelGestureOptions {
  /** Deltas older than this no longer count. */
  windowMs?: number;
  /** Summed finger travel (px) that counts as a swipe. */
  thresholdPx?: number;
  /** Quiet period after firing during which nothing else fires. */
  lockMs?: number;
}

interface Sample {
  t: number;
  dy: number;
}

export class WheelGesture {
  private readonly windowMs: number;
  private readonly thresholdPx: number;
  private readonly lockMs: number;
  private samples: Sample[] = [];
  private lockedUntil = Number.NEGATIVE_INFINITY;

  constructor(opts: WheelGestureOptions = {}) {
    this.windowMs = opts.windowMs ?? 160;
    this.thresholdPx = opts.thresholdPx ?? 28;
    this.lockMs = opts.lockMs ?? 250;
  }

  /** Feed one wheel event's finger delta. Returns a decision at most once per swipe. */
  feed(fingerDy: number, now: number): SwipeDirection | null {
    if (now < this.lockedUntil) return null;
    this.prune(now);
    this.samples.push({ t: now, dy: fingerDy });
    const sum = this.sum();
    if (Math.abs(sum) < this.thresholdPx) return null;
    this.samples = [];
    this.lockedUntil = now + this.lockMs;
    return sum > 0 ? "down" : "up";
  }

  /** How far toward a decision the current swipe is, −1..1. Positive = down. */
  progress(now: number): number {
    if (now < this.lockedUntil) return 0;
    this.prune(now);
    const fraction = this.sum() / this.thresholdPx;
    return Math.max(-1, Math.min(1, fraction));
  }

  reset(): void {
    this.samples = [];
    this.lockedUntil = Number.NEGATIVE_INFINITY;
  }

  private prune(now: number): void {
    const cutoff = now - this.windowMs;
    this.samples = this.samples.filter((s) => s.t >= cutoff);
  }

  private sum(): number {
    let total = 0;
    for (const s of this.samples) total += s.dy;
    return total;
  }
}

/**
 * Convert a wheel deltaY into finger travel. Natural scrolling (the macOS
 * default) moves content WITH the fingers, so fingers moving down produce a
 * negative wheel delta; the classic setting is the reverse.
 */
export function fingerDelta(wheelDeltaY: number, naturalScroll: boolean): number {
  return naturalScroll ? -wheelDeltaY : wheelDeltaY;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `pnpm --filter @agent-island/app test -- gesture`
Expected: PASS (9 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/app/src/renderer/gesture.ts packages/app/src/renderer/gesture.test.ts
git commit -m "Gestures: pure wheel accumulator with threshold, window, and lock-out"
```

---

### Task 5: Natural-scroll preference — `main/scroll-direction.ts`

**Files:**
- Create: `packages/app/src/main/scroll-direction.ts`
- Test: `packages/app/src/main/scroll-direction.test.ts`

**Interfaces:**
- Produces:
  ```ts
  export function parseSwipeScrollDirection(stdout: string | null | undefined): boolean; // true = natural
  export function readNaturalScroll(): Promise<boolean>;
  ```

- [ ] **Step 1: Write the failing test**

```ts
// packages/app/src/main/scroll-direction.test.ts
import { describe, expect, it } from "vitest";
import { parseSwipeScrollDirection } from "./scroll-direction";

describe("parseSwipeScrollDirection", () => {
  it("1 is natural scrolling", () => {
    expect(parseSwipeScrollDirection("1\n")).toBe(true);
  });
  it("0 is classic scrolling", () => {
    expect(parseSwipeScrollDirection("0\n")).toBe(false);
  });
  it("anything else — unset key, error text, empty — assumes the macOS default (natural)", () => {
    expect(parseSwipeScrollDirection("")).toBe(true);
    expect(parseSwipeScrollDirection(undefined)).toBe(true);
    expect(parseSwipeScrollDirection("The domain/default pair does not exist")).toBe(true);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `pnpm --filter @agent-island/app test -- scroll-direction`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement**

```ts
// packages/app/src/main/scroll-direction.ts
import { execFile } from "node:child_process";

/**
 * macOS "Natural scrolling" (System Settings → Trackpad → Scroll & Zoom).
 *
 * Web wheel events carry no hint of it, yet it inverts what a two-finger swipe
 * looks like to the renderer. Read the global default once so the island's
 * gestures can be defined in terms of finger motion. Missing key (never
 * toggled) means the default, which is ON.
 */
export function parseSwipeScrollDirection(stdout: string | null | undefined): boolean {
  const value = (stdout ?? "").trim();
  if (value === "0") return false;
  return true;
}

export function readNaturalScroll(): Promise<boolean> {
  return new Promise((resolve) => {
    execFile(
      "defaults",
      ["read", "-g", "com.apple.swipescrolldirection"],
      { timeout: 2000 },
      (err, stdout) => resolve(parseSwipeScrollDirection(err ? "" : stdout)),
    );
  });
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `pnpm --filter @agent-island/app test -- scroll-direction`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/app/src/main/scroll-direction.ts packages/app/src/main/scroll-direction.test.ts
git commit -m "Gestures: read the natural-scrolling preference once at startup"
```

---

### Task 6: The `openWith` setting end to end (main, preload, Settings UI)

**Files:**
- Modify: `packages/app/src/main/settings.ts` (constants after `TEMPERATURE_UNITS`; `AppSettings`; `DEFAULT_SETTINGS`; `loadSettings` normalization)
- Modify: `packages/app/src/main/index.ts` (imports; `uiPrefs()` ~line 229; `applySetting` switch ~line 277; startup read)
- Modify: `packages/app/src/preload/index.ts` (`SettingsState` ~line 14; `UiPrefs` ~line 50)
- Modify: `packages/app/src/renderer/settings.tsx` (`SettingsState`/`DEFAULTS` ~lines 22–62; `NAV` ~line 64; new section; new `Segmented` component near `Row`)
- Modify: `packages/app/src/renderer/styles/settings.css` (append `.s-seg` rules)

**Interfaces:**
- Consumes: `readNaturalScroll()` (Task 5).
- Produces: setting key `openWith` with values `"hover" | "swipe"`; `UiPrefs` gains `openWith: string` and `naturalScroll: boolean`; `SettingsState.openWith: string`. Settings section id `"appearance"` (Stage 2 adds the glass toggle to it).

- [ ] **Step 1: Add the setting in main**

In `packages/app/src/main/settings.ts`, after the `TEMPERATURE_UNITS` block:

```ts
/** How the collapsed island opens. Hover is today's behavior; swipe means a
 *  two-finger swipe down (or a click) opens it and grazing the top of the
 *  screen no longer does. */
export const OPEN_WITH = ["hover", "swipe"] as const;
export type OpenWith = (typeof OPEN_WITH)[number];
```

In `AppSettings`, after `weatherUnits: TemperatureUnit;`:

```ts
  /** Hover-to-open (default) or gesture-to-open. */
  openWith: OpenWith;
```

In `DEFAULT_SETTINGS`, after `weatherUnits: "auto",`:

```ts
  openWith: "hover",
```

Add the guard beside the other `is*` functions:

```ts
export function isOpenWith(value: unknown): value is OpenWith {
  return typeof value === "string" && (OPEN_WITH as readonly string[]).includes(value);
}
```

In `loadSettings()`'s `cached = { … }` object, after the `weatherUnits:` entry:

```ts
    openWith: isOpenWith(stored.openWith) ? stored.openWith : DEFAULT_SETTINGS.openWith,
```

- [ ] **Step 2: Wire main/index.ts**

Add to the `./settings` import list: `isOpenWith,`. Add a new import line:

```ts
import { readNaturalScroll } from "./scroll-direction";
```

Inside `app.whenReady().then(async () => { … })`, right after `const settings = loadSettings();`:

```ts
    // Natural scrolling inverts what a swipe looks like to the renderer; read
    // it once so gestures are defined by finger motion, not wheel sign.
    let naturalScroll = true;
    void readNaturalScroll().then((natural) => {
      naturalScroll = natural;
      sendToNotch("agent-island:ui-prefs", uiPrefs());
    });
```

Change `uiPrefs`:

```ts
    /** Presentation prefs the overlay itself needs (text scale, open gesture). */
    const uiPrefs = () => ({
      textSize: settings.textSize,
      openWith: settings.openWith,
      naturalScroll,
    });
```

(`uiPrefs` is a `const` arrow defined after `naturalScroll`; keep that order so the closure sees the variable.)

In `applySetting`, add a case next to `"textSize"`:

```ts
        case "openWith":
          if (!isOpenWith(value)) return;
          settings.openWith = value;
          sendToNotch("agent-island:ui-prefs", uiPrefs());
          break;
```

`settingsState()` spreads `...settings`, so `openWith` reaches the Settings window with no further change.

- [ ] **Step 3: Preload types**

In `packages/app/src/preload/index.ts`, `SettingsState`: after `weatherUnits: string;` add

```ts
  /** "hover" | "swipe" — how the collapsed island opens. */
  openWith: string;
```

`UiPrefs`: replace the interface with

```ts
export interface UiPrefs {
  /** "default" | "large" | "larger" — drives --ui-scale. */
  textSize: string;
  /** "hover" | "swipe" — how the collapsed island opens. */
  openWith: string;
  /** macOS natural scrolling; inverts wheel sign relative to finger motion. */
  naturalScroll: boolean;
}
```

- [ ] **Step 4: Settings UI — Appearance section with a segmented control**

In `packages/app/src/renderer/settings.tsx`:

`SettingsState` interface: after `weatherUnits: string;` add `openWith: string;`. `DEFAULTS`: after `weatherUnits: "auto",` add `openWith: "hover",`.

`NAV`: insert after the `integrations` entry:

```ts
  { id: "appearance", label: "Appearance", icon: "◐" },
```

Add the options table next to `TEXT_SIZES`:

```ts
const OPEN_WITH: { value: string; label: string }[] = [
  { value: "hover", label: "Hover" },
  { value: "swipe", label: "Swipe" },
];
```

Add a `Segmented` component after `Row`:

```tsx
/** A small segmented control — one choice among a few, all visible at once. */
function Segmented({
  value,
  options,
  onChange,
  label,
}: {
  value: string;
  options: { value: string; label: string }[];
  onChange: (next: string) => void;
  label: string;
}) {
  return (
    <div className="s-seg" role="radiogroup" aria-label={label}>
      {options.map((o) => (
        <button
          key={o.value}
          type="button"
          role="radio"
          aria-checked={value === o.value}
          className={`s-seg-item${value === o.value ? " on" : ""}`}
          onClick={() => onChange(o.value)}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}
```

Add the section JSX right after the `{section === "integrations" && ( … )}` block:

```tsx
        {section === "appearance" && (
          <div className="s-group">
            <div className="s-row">
              <div className="s-text">
                <b>Open with</b>
                <span>
                  {state.openWith === "swipe"
                    ? "Two-finger swipe down (or a click) opens the island; grazing the top of the screen doesn't. Swipe up closes it."
                    : "Hovering the notch opens the island. Swipe up closes it either way."}
                </span>
              </div>
              <Segmented
                label="Open the island with"
                value={state.openWith}
                options={OPEN_WITH}
                onChange={(v) => set("openWith", v)}
              />
            </div>
          </div>
        )}
```

- [ ] **Step 5: Segmented control styles**

Append to `packages/app/src/renderer/styles/settings.css`:

```css
/* Segmented control (Appearance → Open with). Mirrors .s-select's surface. */
.s-seg {
  flex: none;
  display: inline-flex;
  padding: 2px;
  gap: 2px;
  background: var(--group-bg);
  border: 1px solid var(--group-edge);
  border-radius: 8px;
}
.s-seg-item {
  font: inherit;
  font-size: 11.5px;
  font-weight: 500;
  color: var(--text-dim);
  background: none;
  border: 0;
  border-radius: 6px;
  padding: 3px 10px;
  cursor: pointer;
}
.s-seg-item:hover {
  color: var(--text);
}
.s-seg-item.on {
  color: var(--text);
  background: var(--accent-soft, rgba(116, 183, 255, 0.18));
}
.s-seg-item:focus-visible {
  outline: 2px solid var(--accent, #74b7ff);
  outline-offset: 1px;
}
```

Check the variable names exist: `grep -n "\-\-group-bg\|\-\-group-edge\|\-\-accent" packages/app/src/renderer/styles/settings.css | head`. If `--accent-soft` is absent the fallback in `var()` covers it; if `--accent` is named differently, use that name.

- [ ] **Step 6: Typecheck, test, and check Settings**

Run: `pnpm --filter @agent-island/app typecheck && pnpm --filter @agent-island/app test`
Expected: PASS.

Dev app → open the panel → ⚙ → Appearance. Expected: "Open with" segmented control shows Hover selected; clicking Swipe persists (reopen Settings, still Swipe). `~/Library/Application Support/agent-island/settings.json` (or the dev userData path printed by `app.getPath("userData")`) contains `"openWith": "swipe"`.

- [ ] **Step 7: Commit**

```bash
git add packages/app/src/main/settings.ts packages/app/src/main/index.ts packages/app/src/preload/index.ts packages/app/src/renderer/settings.tsx packages/app/src/renderer/styles/settings.css
git commit -m "Gestures: 'Open with' setting (hover / swipe) and an Appearance section"
```

---

### Task 7: Wire the gestures into the island

**Files:**
- Modify: `packages/app/src/renderer/App.tsx` (state near line 34; `expanded` ~lines 85–93; ui-prefs effect ~line 300; interactive effect ~lines 359–365; `.island` and `.notch-spacer` JSX)
- Modify: `packages/app/src/renderer/styles/island.css` (rubber-band rules; reduced-motion)

**Interfaces:**
- Consumes: `WheelGesture`, `fingerDelta` (Task 4); `UiPrefs.openWith`, `UiPrefs.naturalScroll` (Task 6).
- Produces: state `gestureOpen`, `dismissed`, `rubber`; CSS custom property `--rubber` on `.island`; class `.rubbering`.

- [ ] **Step 1: Add the gesture state and the ui-prefs plumbing**

Import at the top of `App.tsx`:

```ts
import { WheelGesture, fingerDelta } from "./gesture";
```

Inside `App()`, near the other `useState` calls (after `const [pinned, setPinned] = useState(false);`):

```tsx
  // Gestures. `openWith` and `naturalScroll` come from main's ui-prefs.
  const [openWith, setOpenWith] = useState<"hover" | "swipe">("hover");
  const [naturalScroll, setNaturalScroll] = useState(true);
  // Swipe mode: a swipe-down (or wing click) happened while hovering.
  const [gestureOpen, setGestureOpen] = useState(false);
  // Swipe-up while open: stay closed until the pointer leaves the island.
  const [dismissed, setDismissed] = useState(false);
  // −1..1 rubber-band fraction while a swipe accumulates; 0 at rest.
  const [rubber, setRubber] = useState(0);
  const gesture = useRef(new WheelGesture());
  const rubberTimer = useRef<number | null>(null);
```

Replace the text-scale effect so it also applies the gesture prefs:

```tsx
  // Presentation prefs from main: text scale (our stand-in for Dynamic Type)
  // and how the island opens.
  useEffect(() => {
    const apply = (p: { textSize: string; openWith?: string; naturalScroll?: boolean }) => {
      document.documentElement.setAttribute("data-text-size", p.textSize);
      setOpenWith(p.openWith === "swipe" ? "swipe" : "hover");
      setNaturalScroll(p.naturalScroll ?? true);
    };
    void window.agentIsland.getUiPrefs?.().then(apply);
    return window.agentIsland.onUiPrefs?.(apply);
  }, []);
```

- [ ] **Step 2: Rewrite `expanded` and `interactive`**

Replace the `const expanded = …` block with:

```tsx
  // Leaving the island resets both gesture latches, so a gesture-opened island
  // can always be closed by moving away — never stuck open.
  useEffect(() => {
    if (hovering) return;
    setGestureOpen(false);
    setDismissed(false);
  }, [hovering]);

  // Hover opens the island in hover mode; in swipe mode it also needs a
  // swipe-down (or a wing click). A swipe-up parks it closed until you leave.
  const hoverExpands = hovering && !dismissed && (openWith === "hover" || gestureOpen);
  // Anything waiting on the human forces the panel open automatically.
  // Typing a prompt keeps it open even if the cursor drifts off the window.
  const expanded =
    hoverExpands ||
    pinned ||
    promptFocused ||
    a11yFocused ||
    pending.length > 0 ||
    asking.length > 0 ||
    needsYou.length > 0;
  // Wheel events only reach a window that captures the mouse, so swipe mode
  // makes the collapsed wings interactive while the pointer is over them.
  const interactive = expanded || (openWith === "swipe" && hovering);
```

Replace the interactive effect (`// Capture the mouse only while expanded…`) with:

```tsx
  // Capture the mouse only while needed so the rest of the desktop stays clickable.
  useEffect(() => {
    if (interactive !== interactiveRef.current) {
      interactiveRef.current = interactive;
      window.agentIsland.setInteractive(interactive);
    }
  }, [interactive]);
```

- [ ] **Step 3: Listen for wheel events**

Add after the mouse-move effect (`// The window is click-through with forwarded mouse-move…`):

```tsx
  // Two-finger swipes. Deltas are converted to FINGER motion first, so "down"
  // means the same thing whatever the natural-scrolling setting. Swipe up
  // over an open island closes it; in swipe mode, swipe down over the wings
  // opens it. Nothing fires while you're typing a prompt.
  useEffect(() => {
    const onWheel = (e: WheelEvent) => {
      if (promptFocused) return;
      const el = islandRef.current;
      if (!el) return;
      const r = el.getBoundingClientRect();
      const inside =
        e.clientX >= r.left && e.clientX <= r.right && e.clientY >= r.top && e.clientY <= r.bottom;
      if (!inside) return;
      const g = gesture.current;
      const direction = g.feed(fingerDelta(e.deltaY, naturalScroll), e.timeStamp);
      setRubber(g.progress(e.timeStamp));
      if (rubberTimer.current !== null) window.clearTimeout(rubberTimer.current);
      rubberTimer.current = window.setTimeout(() => setRubber(0), 200);
      if (direction === "up" && expanded) {
        setDismissed(true);
        setGestureOpen(false);
        window.agentIsland.haptic?.("tick");
      } else if (direction === "down" && !expanded && openWith === "swipe") {
        setGestureOpen(true);
        window.agentIsland.haptic?.("tick");
      }
    };
    window.addEventListener("wheel", onWheel, { passive: true });
    return () => {
      window.removeEventListener("wheel", onWheel);
      if (rubberTimer.current !== null) window.clearTimeout(rubberTimer.current);
    };
  }, [promptFocused, naturalScroll, expanded, openWith]);
```

- [ ] **Step 4: Wing click toggles in swipe mode; publish `--rubber`**

On the `.island` div, add the style and the extra class (keep the Task 2 `onTransitionEnd`):

```tsx
          style={{ "--rubber": rubber } as React.CSSProperties}
```

and extend the className template with `${rubber !== 0 ? " rubbering" : ""}`. `App.tsx` already imports from `"react"`; add `type CSSProperties` to that import and write `as CSSProperties`.

On the `.notch-spacer` div:

```tsx
          <div
            className={`notch-spacer ${stateCls}`}
            onClick={() => {
              if (openWith !== "swipe") return;
              window.agentIsland.haptic?.("tick");
              if (expanded && hoverExpands) setDismissed(true);
              else if (!expanded) setGestureOpen(true);
            }}
          >
```

- [ ] **Step 5: Rubber-band CSS**

Append to `packages/app/src/renderer/styles/island.css` after the choreography block:

```css
/* ---- Rubber band ----
   While a swipe accumulates, --rubber (−1..1) pulls the wing contents down a
   touch (collapsed, pulling to open) or the panel up (open, pushing to close).
   The band itself never moves. Fast while fingers are on it; on release
   (--rubber back to 0) it springs home. */
.island:not(.expanded) .notch-spacer > .sprites,
.island:not(.expanded) .notch-spacer > .spacer-info {
  transform: translateY(calc(max(var(--rubber, 0), 0) * 3px));
  transition: transform var(--dur-settle) var(--spring-settle);
}
.island.expanded .panel-measure {
  transform: translateY(calc(min(var(--rubber, 0), 0) * 8px));
  transition: transform var(--dur-settle) var(--spring-settle);
}
.island.rubbering .notch-spacer > .sprites,
.island.rubbering .notch-spacer > .spacer-info,
.island.rubbering .panel-measure {
  transition-duration: 90ms;
  transition-timing-function: ease-out;
}
```

Extend the reduced-motion block with:

```css
  .island:not(.expanded) .notch-spacer > .sprites,
  .island:not(.expanded) .notch-spacer > .spacer-info,
  .island.expanded .panel-measure {
    transform: none;
    transition: none;
  }
```

- [ ] **Step 6: Typecheck and run tests**

Run: `pnpm --filter @agent-island/app typecheck && pnpm --filter @agent-island/app test`
Expected: PASS.

- [ ] **Step 7: Manual check on a trackpad**

Dev app with one session:

- Hover mode (default): hover opens; two-finger swipe up over the open panel closes it and it stays closed until the pointer leaves; approaching again reopens.
- Settings → Appearance → Swipe: hovering the wings does **not** open; swipe down opens (wing contents nudge down a few px first); clicking a wing toggles; swipe up closes; leaving the island closes it.
- With Reduce motion on: no rubber band, still opens/closes.
- Console shows `[notch] interactive=true` when hovering the wings in swipe mode and `false` after leaving.

- [ ] **Step 8: Commit**

```bash
git add packages/app/src/renderer/App.tsx packages/app/src/renderer/styles/island.css
git commit -m "Gestures: swipe up closes, swipe mode opens on swipe or click, rubber band"
```

---

### Task 8: Docs and stage wrap-up

**Files:**
- Modify: `docs/STATUS.md` (new section after "Living Island", before "Next up")
- Modify: `.impeccable.md` (one clarifying sentence under "Every animation stays on transform and opacity only")

- [ ] **Step 1: Record the stage in STATUS.md**

Insert before `## Next up`:

```markdown
## Glass Island (spec: docs/superpowers/specs/2026-09-06-glass-island-design.md)

Three stages on `feat/glass-island`; plans in docs/superpowers/plans/2026-09-06-glass-island-stage-*.md.

- **Stage 1 — Motion + gestures — DONE <date>**: springs sampled once into CSS
  `linear()` easings (`renderer/motion.ts`; `--spring-open`/`--dur-open`,
  `--spring-settle`/`--dur-settle`, `--dur-close`), entrance choreography
  (staggered rows via `--i`, card-in, sprite-pop on `.sprite-slot`, count-roll),
  two-finger swipe up always closes, `openWith` setting (hover | swipe) in a new
  Appearance section, rubber band via `--rubber`. Natural scrolling is read once
  (`main/scroll-direction.ts`) so swipes mean finger motion.
  **Not verified by machine:** gesture feel on a physical trackpad.
- **Stage 2 — Liquid Glass**: pending.
- **Stage 3 — Live activities**: pending.
```

Replace `<date>` with today's date.

- [ ] **Step 2: Clarify the motion rule in `.impeccable.md`**

Under the bullet that begins "Every animation stays on `transform` and `opacity` only", append a sentence:

```
  Timing comes from the spring tokens (`--spring-open`, `--spring-settle`,
  `--dur-*`) published by `renderer/motion.ts` — never a new ad-hoc bezier.
```

- [ ] **Step 3: Full verification**

Run: `pnpm typecheck && pnpm test`
Expected: all packages pass.

- [ ] **Step 4: Commit**

```bash
git add docs/STATUS.md .impeccable.md
git commit -m "Docs: Stage 1 of Glass Island (motion + gestures) recorded"
```

Version bump and release notes happen when the stage ships (see `superpowers:finishing-a-development-branch`), not in this plan.

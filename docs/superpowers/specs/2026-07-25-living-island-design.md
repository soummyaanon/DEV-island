# Living Island — Adaptive Width, Accessibility, Haptics, Weather — Design

_2026-07-25. Branch `feat/living-island` (from `main`). New backlog item; adds
weight, so it runs against STATUS.md item 1 (size reduction) — see Budget._

## Goal

Make the island feel alive, premium, and native: an expanded panel that sizes
itself to its content instead of a fixed 360px, real trackpad haptics with a
distinct rhythm per event class, best-in-class accessibility (VoiceOver,
reduced motion, high contrast, scalable text), and ambient weather animations
that fill the island's dead idle state.

Everything stays local except one disclosed weather request, and the software
compositing budget the overlay runs under today is preserved.

## Staging

Two stages, shipped and reviewed independently.

- **Stage A — adaptive width, accessibility, haptics.** No network, no
  Info.plist change, no privacy-policy change. Lands the native helper (for
  haptics) and the type-token refactor that Stage B builds on.
- **Stage B — weather.** Extends the same helper with one `location` command,
  adds the first ongoing network call, and changes the README's privacy
  section.

The seam is deliberate: Stage A carries all the risk that touches existing
behavior; Stage B is almost entirely additive.

## Budget (applies to both stages)

The overlay runs with `app.disableHardwareAcceleration()` (`main/index.ts:43`),
a 96MB V8 cap, and `backgroundThrottling: true`. It composites over the
menu-bar band permanently, so every animation is a CPU cost the user pays all
day. Three non-negotiable rules:

1. **Only `transform` and `opacity` animate.** Never `filter`, `box-shadow`,
   or gradient interpolation — those repaint. The existing `.edge-spark` is the
   model: it animates opacity over a *static* box-shadow.
2. **No JS in a frame loop.** Motion is declarative CSS keyed off a `data-*`
   attribute; JS only swaps the attribute value. The one exception is
   lightning's randomized scheduler, which is a `setTimeout` every ~10s.
3. **Nothing animates unseen.** `.app.paused` (`island.css:49`) already freezes
   everything on lock/sleep. New animations inherit it and must additionally
   not render at all when their state isn't visible.

STATUS.md item 1 wants the app smaller. This work adds a ~200KB Swift binary
and roughly 400 lines of CSS. That is a real regression on that goal, accepted
knowingly; no image or font assets are added, and the pet spritesheets
(~6.5MB) are explicitly out of scope.

---

# Stage A

## A1. Native helper — `native/AgentIslandNative.swift`

One `arm64` Mach-O binary in `Contents/Resources`, spawned once at launch and
kept alive, speaking newline-delimited text on stdin/stdout:

```
→ haptic levelChange,55,levelChange     ← ok
→ ping                                  ← pong
```

Long-lived rather than spawned per use because haptics need sub-10ms latency;
`osascript` per pulse costs 150ms+ and a process spawn. The protocol is plain
lines — no IPC framework, no dependency.

Built by `scripts/build-native.sh` (`swiftc -O`), invoked from the app
package's `build` script and copied in via `electron-builder.yml`
`extraResources`. `codesign --deep` in `scripts/package-dmg.sh` already signs
nested binaries.

**Absence is a supported state.** No Xcode CLT, a failed build, a quarantined
or crashed helper: `scripts/build-native.sh` exits 0 with a warning,
`pnpm build` succeeds, and the app runs with haptics as a no-op. This is
verified by a test, not assumed.

### `main/native-helper.ts`

Owns the child process: lazy spawn on first use, one restart attempt on
unexpected exit, then permanent disable. Exposes
`send(line: string): boolean` (false = unavailable) and `isAvailable()`.
Never throws. Killed in the existing `before-quit` handler
(`main/index.ts:446`) alongside the daemon.

## A2. Haptics — `main/haptics.ts`

macOS offers exactly three primitives via `NSHapticFeedbackManager`
(`.generic`, `.alignment`, `.levelChange`), trackpad-only, and honours the
system "Force Click and haptic feedback" setting. There is no waveform
control, so **distinctness comes from count and spacing, not texture.** The
vocabulary is stated plainly rather than implying richer output than the
hardware gives.

| Class | Event | Pattern | Rhythm |
| --- | --- | --- | --- |
| Notification | session done | `success` | `levelChange` ×2 @ 55ms |
| | needs you | `attention` | `generic` ×3 @ 90ms |
| | question asked | `inquiry` | `alignment` → `levelChange` @ 70ms |
| | session failed | `failure` | `generic` ×2 @ 40ms (tight = wrong) |
| System action | approve / deny | `commit` | `levelChange` ×1 |
| | row click, jump, control | `tick` | `alignment` ×1 (lightest) |
| Weather (Stage B) | condition update | `whisper` | `alignment` ×1 |
| | thunder onset | `rumble` | `generic` ×3 @ 140ms |

`whisper` is deliberately the subtlest pattern available: an ambient weather
change must never read as an alert. `rumble`'s 140ms spacing is what
distinguishes it from `attention`'s 90ms.

**Coalescing is required, not optional.** Ten sessions finishing in one
snapshot must not machine-gun the trackpad. `haptics.ts` rate-limits to one
pattern group per 250ms; within a window, the highest-priority pattern wins
(`failure` > `attention` > `inquiry` > `success` > `commit` > `tick` >
`whisper`). This is a pure function, unit-tested.

Gated on a new `haptics` setting (default `true`) and silently inert when the
helper is unavailable.

**Wiring:** notification patterns fire from the transition detector already in
`App.tsx:159-196`, beside the existing `playSound` and `firePulse` calls — the
events are already computed there, so no new plumbing. Interaction patterns
fire from the relevant click handlers. Desktop Macs and external keyboards get
nothing from the trackpad, which is why the existing visual (`edge-spark`) and
audio layers stay untouched as the equivalent feedback.

## A3. Adaptive width

Today: window is a fixed 460×400 (`notch-window.ts:6-7`); the expanded island
is `max(360px, notchWidth + 110px)` (`island.css:80`).

**Window** grows to 820×560. It is transparent and click-through when
collapsed, so the extra area costs nothing visually. 560 tall is needed
because a question card (285px max) plus rows plus footer already approaches
400 at the default text size, and text scaling makes it worse.

**Island width becomes measured.** Panel children are wrapped in
`.panel-measure { width: max-content; max-width: <maxW>px }`, observed by a
`ResizeObserver`. The renderer clamps and publishes the result as `--island-w`:

```
minW = max(360, notchWidth + 110)          // today's behavior as the floor
maxW = min(720, screenWidth - 80)          // never overhang the display
--island-w = clamp(minW, contentW, maxW)
```

`.island.expanded { width: var(--island-w) }`, transitioned with the existing
overshoot `--motion` curve so growth feels sprung rather than mechanical.

Pure CSS `width: fit-content` was rejected: it cannot be transitioned, and the
fluid resize is the point of the request.

**Bounding the natural width.** `width: max-content` makes ellipsised text
report its full length, so a 200-character activity string would always demand
720px. Two guards: `max-width` on `.panel-measure` (which restores ellipsis
once clamped), and a `max-width` in `ch` on the elastic text elements
(`.activity`, `.row-context`, `.project`) so each contributes a bounded
natural width. Result in practice: a plain session list settles near 380px, a
diff-heavy approval card grows toward 720px.

**Loop safety.** `ResizeObserver` feeding a width that affects layout can
thrash. Updates are `requestAnimationFrame`-debounced and applied only when
the delta exceeds 2px.

**Contingency (documented, not ambiguous):** if the observer proves unstable
in practice, fall back to discrete content tiers — `has-diff` → 640,
`has-question` → 560, rows-only → 400 — driven by a class instead of a
measurement. Same CSS variable, same transition; only the source of the number
changes. Trigger for switching: visible width oscillation or an RO loop
warning in the console.

### Two existing bugs this forces us to fix

Both are real today and both become user-visible at 820px:

1. **`cursorWatch` tests the wrong rectangle.** `main/index.ts:382-394` polls
   the cursor against the *window* bounds plus a 10px margin. At 820px wide,
   the island would stay expanded with the pointer 180px away from it. The
   renderer already holds the island's rect in `islandRef`; it must report it
   (`reportIslandRect`) and main must poll against that instead.
2. **The window never re-centers.** `x` is computed once in
   `createNotchWindow` (`notch-window.ts:56`), so a resolution change, a
   display swap, or docking leaves the island off-centre from the notch.
   Subscribe to `screen`'s `display-metrics-changed` and
   `display-added`/`display-removed`, recompute `x`, and re-push layout.

## A4. Accessibility

### VoiceOver — the hard part

The notch window is created `focusable: false` (`notch-window.ts:84`) so it
never steals focus from the terminal. A non-focusable NSPanel is effectively
unreachable by VoiceOver, so no amount of ARIA fixes this on its own.

A new global shortcut **⌃⌥⌘I** flips the window focusable, focuses it, and
puts the renderer into an explicit a11y focus mode; **Escape** releases it and
restores `focusable: false`. This is the exact mechanism
`setPromptComposing` already uses for the prompt input
(`main/index.ts:423-428`), so it introduces no new window-management risk.
Four modifiers avoids collisions — notably ⌥⌘I is the browser devtools
shortcut, which this audience uses constantly.

Renderer behavior in a11y focus mode:

- `a11yFocused` joins the `expanded` OR-chain (`App.tsx:65-71`) so the panel
  is open, and keeps `setInteractive(true)`. The existing `onCursorLeft`
  collapse cannot close it, because `expanded` no longer depends only on
  hover — no change needed there, but it is the reason the ordering works.
- Focus moves to the first interactive element in the panel; Tab / Shift-Tab
  cycle within `.panel` as a trap.
- If `globalShortcut.register` fails, log it and surface the shortcut as
  unavailable in Settings rather than failing silently.

### Announcements

Two live regions in a new `.sr-only` utility class:

- `role="status" aria-live="polite"` — state transitions, one coalesced
  message per snapshot batch ("2 sessions need you", "agent-island finished").
- `aria-live="assertive"` — approval and question arrival only.

Weather (Stage B) is `aria-hidden` in its entirety; the *text* summary carries
the accessible name. Animations are never announced.

### Semantics

`SessionRow` is currently an `<li>` with an `onClick` — **not keyboard
reachable at all.** The clickable region becomes a `<button type="button">`
with `aria-label` composed of project, state, activity, and elapsed. `.rows`
keeps its `<ul>`. `.island` gains `role="region"` and an
`aria-label="Agent Island"`. Decorative sprites already carry `aria-hidden`
(`App.tsx:275-277`) and keep it. Visible `:focus-visible` rings are added
across rows, cards, options, and controls — `.q-option` already has one
(`island.css:762`) and sets the pattern.

### Reduced motion

`island.css:1023` already has a block; it is extended to cover every new
animation. Critically, reduced motion must also be honoured **in JS** — CSS
cannot stop lightning's `setTimeout`. A `useReducedMotion()` hook in
`renderer/a11y.ts` wraps `matchMedia` with a change listener, and the width
transition becomes an instant jump.

### High contrast

- `@media (prefers-contrast: more)` — opaque card backgrounds, solid 1px
  borders, `--text-dim` raised, focus rings to 2px, decorative glows
  (`.notch-glow`, the `.edge-spark` bloom) replaced by a solid border flash.
- `@media (prefers-reduced-transparency: reduce)` — `--bg` becomes fully
  opaque `#0b0b0d`.

Both are supported by Electron 35's Chromium (`prefers-contrast` since 96,
`prefers-reduced-transparency` since 118).

### Scalable text ("Dynamic Type")

macOS has no Dynamic Type API and does not expose the Accessibility text-size
setting to Chromium, so the honest equivalent is an app setting: `textSize` →
`default` | `large` | `larger` → `--ui-scale` of `1` / `1.15` / `1.3`.

This requires converting `island.css`'s hard-coded sizes into nine type tokens
in a new `styles/tokens.css`, each pre-multiplied so usages stay simple
(`font-size: var(--fs-body)`):

| Token | Base | Used by |
| --- | --- | --- |
| `--fs-micro` | 9.5px | `.elapsed`, `.row-context`, `.usage-item`, `.ctl` |
| `--fs-tiny` | 10px | `.approval-kicker`, `.q-hint`, `.prompt-hint`, `kbd` |
| `--fs-small` | 10.5px | `.spacer-info`, `.approval-project` |
| `--fs-body-sm` | 11px | `.activity`, `.prompt-input`, `.diff`, `.cmd`, `code` |
| `--fs-body` | 12px | `.approval-body`, `.q-option`, `.empty` |
| `--fs-strong` | 12.5px | `.project`, `.btn`, `.approval-body h*` |
| `--fs-title-sm` | 13px | `.question-text` |
| `--fs-title` | 13.5px | `.approval-title` |
| `--fs-icon` | 16px | `.ctl.icon` |

The scrollable maxima (`.approval-body` 150px, `.question` 285px) scale too.
Larger text produces a wider natural content width, so it feeds A3
automatically — the two features compose rather than fight.

**This is the largest mechanical chunk of Stage A.** It touches roughly 40
declarations across `island.css` and is pure substitution, so it should land as
its own commit with no behavioral change at `--ui-scale: 1`.

---

# Stage B — Weather

## B1. Location, layered

First layer that produces a fix wins:

1. **Manual** — coords or a city label in Settings. Always wins when set.
2. **CoreLocation** — via the helper's new `location` command. Coordinates are
   rounded to 2 decimals (~1km) **before they leave the machine**. Weather is
   city-scale; further precision is pure leakage for zero benefit.
3. **Timezone** — parse `/var/db/timezone/zoneinfo/zone.tab` for the zone from
   `Intl.DateTimeFormat().resolvedOptions().timeZone`. Verified present on
   macOS; entries are ISO 6709 (`IN +2232+08822 Asia/Kolkata`). Public-domain
   tz data already on every Mac: no bundled dataset, no permission, no
   network. Coarse (zone-level) but a good default the user can correct.

Falls back to layer 3 then manual whenever CoreLocation is denied, disabled
system-wide, or silently broken. **Weather never blocks on a permission.**

CoreLocation in a bare executable requires `NSLocationWhenInUseUsageDescription`
in `Bundle.main`, which for a Mach-O tool means embedding a plist via
`swiftc -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist` — the
standard CLI-tool approach. The app's own Info.plist gains the same key via
`electron-builder.yml` `extendInfo`.

**Grant fragility, stated up front:** macOS keys TCC grants to the code
signature, so ad-hoc builds lose the Location grant on every update — the
toggle still reads ON but no longer applies. This is the identical trap
`main/accessibility.ts` already documents and repairs for Accessibility, and
STATUS.md item 3 confirms no Developer ID exists yet, so it is live rather than
hypothetical. Mitigation: reuse the `tccutil reset` + re-prompt pattern from
`requestAccessibility`, and rely on layer 3 to cover the gap invisibly.

## B2. Weather service — `main/weather.ts`

Open-Meteo, no API key:

```
https://api.open-meteo.com/v1/forecast
  ?latitude=..&longitude=..
  &current=temperature_2m,weather_code,is_day
  &daily=sunrise,sunset
  &hourly=precipitation
  &timezone=auto
```

Fetched with Electron's `net`, reusing the request shape in
`main/update-check.ts`. Polled every 15 minutes, plus on `powerMonitor`
`resume`, with exponential backoff on failure. Last-good response is cached to
`userData` so an offline launch still renders something, flagged stale.
Broadcast to the notch and Settings through the existing `sendToNotch` /
`pushSettingsState` paths.

Weather never crosses the daemon boundary, so its types live in
`packages/app`, **not** `packages/shared` — that package is explicitly "the zod
schemas both sides trust" (README.md:115) and weather is not one of them.

### Conditions

Ten conditions cover the eight requested effects; three are derived rather
than read from a WMO code.

| Condition | Source |
| --- | --- |
| `clear-day` / `clear-night` | WMO 0–1, split on `is_day` |
| `cloudy` | WMO 2–3 |
| `fog` | WMO 45, 48 |
| `rain` | WMO 51–67, 80–82 |
| `snow` | WMO 71–77, 85–86 |
| `thunder` | WMO 95–99 |
| `sunrise` / `sunset` | *derived* — within ±25min of the daily time, sky clear-ish; overrides `clear-*` |
| `rainbow` | *derived* — precipitation stopped <30min ago, `is_day`, clouds breaking; a 90s treat that then reverts |

All derivation is pure functions, unit-tested against a table of WMO codes and
synthetic timestamps — no Electron, no network.

## B3. Scene — `renderer/weather/`

`WeatherScene.tsx` sets one `data-condition` attribute; `styles/weather.css`
owns every pixel of motion. Kept in its own stylesheet because `island.css` is
already 1057 lines and weather would nearly double it.

| Condition | Elements | Technique |
| --- | --- | --- |
| Rain | 12 drops | `translateY` linear, staggered delays, slight rotate for wind |
| Snow | 9 flakes | `translateY` + sway combined in one keyframe |
| Cloudy | 3 blobs | `translateX` drift, 40–70s |
| Sun | disc + ray group | static radial-gradient, one 60s `rotate` |
| Moon + stars | crescent + 7 stars | opacity-only twinkle — the cheapest possible animation |
| Lightning | flash + SVG bolt | 3-stab opacity burst on a randomized 6–14s `setTimeout`, so ~95% of the time it is just clouds; one-shot remount keyed like `edge-spark` (`App.tsx:39-44`) |
| Sunrise / sunset | 2 stacked gradients | cross-fade opacity (never `background-position`), sun on `translateY` |
| Rainbow | SVG arc | opacity + scale reveal, transient |
| Fog | 2 bands | very slow `translateX` |

Under reduced motion each becomes a static illustration: a still bolt, parked
drops, motionless clouds, and lightning's scheduler is never started.

## B4. Placement, and one behavior change to accept consciously

Weather occupies the collapsed island **only while no agent is active** —
agents always preempt it, so it never competes with work. Temperature sits in
the right wing where `.spacer-info` renders the active count, which is empty
when nothing is running. The expanded panel gains a weather card.

**The change:** today `sessions.length === 0` sets `.bare`, collapsing the
island to exactly the notch width and rendering it invisible
(`island.css:89-92`, `island.css:157-159`). With weather enabled, that dead
state becomes a small live scene — so **the island is never invisible again
while weather is on.** That is the requested "more alive", but it is a real
change to resting behavior, and it is why weather ships off by default.

## B5. Settings, and the privacy disclosure

New settings: `weather` (default **false**), `weatherLocation`
(`{lat, lon, label} | null`), `weatherUnits` (`auto` | `c` | `f`, default
`auto`, derived from locale). Enabling weather is what triggers the Location
prompt — nothing asks before then.

`README.md:72-82` currently promises "no accounts, no API keys, no telemetry"
with the GitHub version check as "the single exception". That sentence becomes
false the moment weather ships and **must** be rewritten to disclose
Open-Meteo, what is sent (2-decimal coordinates, nothing else), when, and how
to disable it. This is a required deliverable of Stage B, not documentation
polish.

---

## Design-guidance amendment

`.impeccable.md` states "no decorative gradients or glow-heavy AI styling" and
"keep the overlay compact". Weather animations are decoration, and a 720px
island is not compact. Rather than quietly contradict the guidance, amend it:

- Decoration is confined to the weather scene, where it is **semantic** — the
  animation conveys the actual condition, which is the information.
- Agent UI stays restrained: no new gradients or glows on rows, cards, or
  controls.
- "Compact" is restated as "no wider than its content needs", which is what
  A3 implements.

## Files

**New:** `native/AgentIslandNative.swift`, `scripts/build-native.sh`,
`main/native-helper.ts`, `main/haptics.ts` (+test), `renderer/a11y.ts`,
`styles/tokens.css`; Stage B adds `main/location.ts` (+test),
`main/weather.ts` (+test), `renderer/weather/WeatherScene.tsx`,
`renderer/weather/layers.tsx`, `styles/weather.css`.

**Modified:** `main/index.ts`, `main/windows/notch-window.ts`,
`main/settings.ts`, `preload/index.ts`, `renderer/App.tsx`,
`renderer/SessionRow.tsx`, `renderer/settings.tsx`, `styles/island.css`,
`styles/settings.css`, `electron-builder.yml`, `packages/app/package.json`,
`docs/STATUS.md`, `.impeccable.md`; Stage B also `README.md`.

`settings.tsx` is 371 lines and gains several rows across both stages. If it
passes ~450, extract a shared section/row component — but not preemptively.

## Testing

Pure functions are extracted specifically so vitest covers them without
Electron, matching the existing `zero-config.test.ts`, `jump-back.test.ts`,
and `accessibility.test.ts`:

- haptic pattern coalescing and priority ordering (A2)
- width clamp math (A3)
- WMO code → condition mapping (B2)
- sunrise/sunset window derivation, rainbow trigger (B2)
- `zone.tab` ISO 6709 parsing, including malformed and missing-file cases (B1)
- helper-unavailable degradation: haptics no-op, location falls through (A1/B1)

Manual verification:

- `AGENT_ISLAND_WEATHER=thunder` forces any of the ten scenes. **Without this
  you cannot see snow in July** — it is required, not a convenience.
- Reduced motion, Increase contrast, and Reduce transparency toggled live in
  System Settings → Accessibility → Display.
- VoiceOver: ⌘F5, then ⌃⌥⌘I, tab through every card and row, Escape to
  release; confirm the terminal regains focus.
- Width: open a diff-heavy approval and a long question; confirm smooth growth,
  no oscillation, and that the pointer leaving the *island* (not the window)
  collapses it.
- Haptics: on a Force Touch trackpad, confirm the four notification rhythms are
  distinguishable; confirm ten simultaneous completions produce one pulse.
- Idle power: Activity Monitor energy impact while collapsed with weather on
  and no sessions, compared against `main` — the number that must not regress.

## Non-goals

Multi-day forecast; weather in the Settings or onboarding windows beyond a
toggle and location field; per-event haptic customization (the sound system's
override model is not worth mirroring for three primitives); a configurable
VoiceOver hotkey; multi-display weather; pet spritesheets (deferred, and their
artwork is © OpenAI rather than covered by agent-notch's MIT licence); GPU
re-enablement.

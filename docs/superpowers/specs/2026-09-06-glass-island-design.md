# Glass Island — Spring Motion, Liquid Glass, Gestures, Live Activities — Design

_2026-09-06. Branch `feat/glass-island` (from `main`, v1.3.0). Follows the
Living Island spec (2026-07-25) and keeps its budget rules._

## Goal

Make the island move like a physical object and look like a macOS 26 system
surface, then give its idle and working states more to say: real spring
physics on every transition, a true Liquid Glass panel under the notch on
macOS 26 (with honest fallbacks), two-finger gestures, a battery live
activity, a per-agent CPU/memory meter, and Focus-mode awareness fed by a
Shortcuts automation.

Nothing new leaves the machine. The software-compositing budget of the
overlay is preserved: only `transform` and `opacity` animate, no JS frame
loops, nothing animates or polls unseen.

## Research that shaped this

- Liquid Glass on macOS 26 is refraction plus a specular rim plus adaptive
  tint. It is not blur. `NSGlassEffectView` (AppKit, macOS 26) exposes
  `cornerRadius`, `tintColor`, `style`.
- CSS cannot do it here. `backdrop-filter` in a transparent Electron window
  sees only the page, never the wallpaper. True see-through needs a native
  view behind the web content.
- `electron-liquid-glass` (npm) glasses the entire NSWindow. Our window is an
  820×560 mostly-transparent canvas, so it is unusable as-is, and it offers no
  frame control. We use our own sidecar instead.
- The notch-app field (boring.notch, NotchNook, Alcove, MacNotch, Atoll):
  media HUD, charging live activity, gestures, file shelf, calendar, HUD
  replacement, system stats. Alcove is praised for animation physics; MacNotch
  ships "Liquid Glass (Beta)" on Tahoe. Now Playing on macOS 15.4+ needs the
  MediaRemoteAdapter hack (a private framework loaded through a signed Apple
  binary) and is a non-goal here.
- Focus state lives in `~/Library/DoNotDisturb/DB`, which is protected by
  Full Disk Access (verified: "Operation not permitted", same as Mail and
  Safari). macOS has no public Focus-status API. macOS 26 Shortcuts gained
  automations on the Mac, including a Focus trigger, which is the bridge used
  below.

## Staging

Three stages, each shippable and reviewable on its own, in this order:

1. **Motion + gestures** — renderer only, no native code. Lowest risk,
   immediate visible payoff.
2. **Liquid Glass** — sidecar, main wiring, CSS restructure. Highest risk
   (cross-process window ordering), isolated so it cannot block Stage 1.
3. **Live activities** — battery, resource meter, Focus bridge, deep links.
   Touches the daemon and the hook bridge scripts.

Each stage may ship as its own minor release (1.4.0 / 1.5.0 / 1.6.0) or all
three as one; the seams are the same either way. Each stage gets its own
implementation plan.

## Budget (applies to every stage)

Unchanged from Living Island, restated because Stage 2 tempts every rule:

1. Only `transform` and `opacity` animate in CSS. The glass itself is a native
   view; the web layer over it never animates `filter`, `box-shadow`,
   `backdrop-filter`, or gradients.
2. No JS frame loop. Springs are precomputed into CSS `linear()` easings once
   at startup. The one per-frame path is the glass follower, which is a
   `ResizeObserver` reacting to a CSS transition, not a timer.
3. Nothing works unseen. `.app.paused` still freezes animation on lock/sleep;
   the process meter polls only while the panel is open; the glass panel
   exists only while expanded.

Size: roughly +200 lines Swift in the existing sidecar, +400 lines CSS, a few
hundred lines TS. No image, font, or audio assets. One `ps` (~10ms for ~900
processes, measured) every 2s while the panel is open. One `pmset` per minute
on laptops, none on desktops.

---

# Stage 1 — Motion + gestures

## 1.1 Spring motion — `renderer/motion.ts`

Today every transition is a single overshoot bezier at 0.12s/0.26s. Replace
with real damped springs, expressed as CSS `linear()` easings so the budget
holds (Chromium 134 in Electron 35 supports `linear()`).

`springLinear(stiffness, damping, mass, samples)` — pure — integrates the
spring, samples it, and returns `{ easing: "linear(0, 0.31 8%, …, 1)", ms }`
where `ms` is the settle time (|x−1| < 0.001 with velocity near zero). Two
named springs, published as CSS variables on `<html>` at startup:

| Variable | Spring | Feel | Used by |
| --- | --- | --- | --- |
| `--spring-open` / `--dur-open` | k=320 c=22 m=1 (~4% overshoot, ~420ms) | lands with life | island width, radius, panel-wrap rows, panel transform, card + row entrances |
| `--spring-settle` / `--dur-settle` | k=380 c=32 m=1 (no overshoot, ~300ms) | firm | width changes *while already open* (content growth), count roll |

Collapse is not a spring: `--dur-close: 180ms`, `ease-in`. Things should
leave faster than they arrive.

**Choreography** (all `transform`/`opacity`):

- **Panel**: `translateY(-8px) scale(0.985)` → identity with `--spring-open`;
  opacity 0→1 in the first 120ms.
- **Rows**: `.island.expanded .row` runs `row-in` (translateY(6px)+opacity)
  once with `animation-delay: calc(var(--i) * 22ms)`, `--i` set inline. The
  selector starts matching when `.expanded` is added, so it plays once per
  open; a row re-render does not remount and does not replay. New rows added
  while open animate in, which is desirable.
- **Cards** (`.approval`, `.question`): `card-in` (translateY(-6px)
  scale(0.98) + opacity) with `--spring-open`.
- **Wing sprite pop**: a sprite mounting in `.sprites` runs `sprite-pop`
  (scale 0.6 → 1.12 → 1).
- **Count roll**: `.spacer-info` wraps its text in a `<span key={value}>`; the
  new value runs `count-roll` (translateY(8px)+opacity), so "2" rolling to
  "3" reads as a counter, not a swap.
- **The black band never transforms.** It must stay pixel-aligned with the
  hardware notch, so no anticipation squish on `.island` — the life comes
  from the panel and the wing contents.

**Reduced motion**: every new animation and transition drops to `none` in the
existing `prefers-reduced-motion` block, and `useReducedMotion()` (already in
`a11y.ts`) makes `motion.ts` publish step-like easings with 1ms durations so
JS-driven timing agrees with CSS.

## 1.2 Gestures — `renderer/gesture.ts`

Electron forwards mouse-move through a click-through window but **not wheel
events**, so gestures need the window to be interactive over the island. That
already happens while expanded; Stage 1 extends it deliberately for one mode.

`WheelGesture` — pure — `feed(deltaY, t) → "open" | "close" | null` sums
deltaY over a 160ms sliding window, fires at ±28px, then locks until 250ms of
quiet; `progress()` returns the clamped fraction toward the threshold for
rubber-banding. Unit-tested: threshold, window expiry, lock, direction.

Behavior:

- **Swipe up over the open island collapses it — always**, both modes.
- New setting `openWith: "hover" | "swipe"` (default `hover`, today's
  behavior unchanged).
- **Swipe mode**: the collapsed wings are interactive while the pointer is
  over them, so grazing the top of the screen no longer pops the island open.
  Swipe down (or click a wing) opens it. Leaving the island still collapses
  it, exactly as in hover mode — a gesture-opened island that only a gesture
  can close is the "stuck open" failure the notch skill warns about.

  ```
  expanded = (hovering && (openWith === "hover" || gestureOpen))
           || pinned || promptFocused || a11yFocused
           || pending/asking/needsYou non-empty
  interactive = expanded || (openWith === "swipe" && hovering)
  gestureOpen resets when hovering becomes false
  ```

- **Rubber band**: while a swipe accumulates, the wing contents translate up
  to 3px (collapsed, pulling down) or the panel translates up to −8px (open,
  pushing up), following `progress()`; release below threshold springs back
  with `--spring-settle`. Off under reduced motion.
- Nothing fires while the prompt input is focused.

Settings: a new **Appearance** section carries "Open with" (segmented:
Hover / Swipe) — and, in Stage 2, the glass toggle.

---

# Stage 2 — Liquid Glass

## 2.1 The shape decision

The notch band (the `--notch-inset` strip that merges with the hardware notch)
**stays pure `#000`**. Glass would make it translucent and break the merge that
is the whole point of the island. Glass applies to the **expanded panel below
the notch line**: a black notch cap over a glass sheet, which is also what the
macOS 26 notch apps ship.

## 2.2 Spike first (Stage 2, task 1)

Before any wiring: a 30-line Swift script shows one `NSGlassEffectView` in a
borderless transparent NSPanel over the desktop. It must refract the
wallpaper behind the *window*, not only content inside it. If it does not,
the native tier becomes `NSVisualEffectView` (`.hudWindow`, `.behindWindow`)
everywhere — real see-through blur without refraction — and the rest of this
stage is unchanged. Recorded in STATUS.md either way.

## 2.3 Sidecar — `native/AgentIslandNative.swift`

One more command family on the existing stdin/stdout protocol:

```
→ glass caps                                    ← glass native | glass vibrancy | glass none
→ glass show <x> <y> <w> <h> <radius> <belowId> ← ok | err <reason>
→ glass hide                                    ← ok
```

Coordinates are screen points, top-left origin (Electron's convention); the
sidecar converts to AppKit's bottom-left using the primary screen's frame.

The sidecar owns one lazily created `NSPanel`: `[.borderless,
.nonactivatingPanel]`, `isOpaque = false`, `backgroundColor = .clear`,
`hasShadow = false`, `ignoresMouseEvents = true`, `hidesOnDeactivate = false`,
`level = .screenSaver` (Electron's `"screen-saver"`), `collectionBehavior =
[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
.transient]`. Its content view is:

- **native**: `NSGlassEffectView`, resolved with
  `NSClassFromString("NSGlassEffectView")` and configured through KVC
  (`cornerRadius`, `tintColor` = black at 35%). Runtime lookup, not a typed
  reference, so the file still compiles with `-target arm64-apple-macos12` on
  the macos-14 CI runner and no `#available` dance is needed.
- **vibrancy** (macOS < 26): `NSVisualEffectView`, `.hudWindow`,
  `.behindWindow`, `.active`, layer corner radius + `masksToBounds`.

`show` sets the frame **immediately** (no native animation), then
`order(.below, relativeTo: belowId)`. Ordering is re-asserted on every `show`
and on `NSWorkspace.activeSpaceDidChangeNotification`. `hide` orders out. The
`belowId` is the Electron window's CGWindowID, parsed from
`notch.getMediaSourceId()` (`"window:<id>:0"`).

## 2.4 Main — `main/glass.ts`

- `glassFrame(windowBounds, islandRect, inset, overlap = 6)` — pure — returns
  the screen rect of the panel portion: `x = b.x + r.x`, `y = b.y + inset −
  overlap`, `w = r.width`, `h = r.height − inset + overlap`, or `null` when
  `h ≤ overlap + 2` (collapsed). The overlap tucks the glass's top corners
  under the black band.
- Asks `glass caps` once at startup → `glassSupport: "native" | "vibrancy" |
  "none"`, exposed in settings state and pushed to the renderer as
  `data-glass="native|vibrancy|css"` on `<html>`.
- Forwards `glass show` whenever the island rect changes while expanded and
  glass is enabled and supported; deduplicates identical rects; `glass hide`
  on collapse, on `paused` (lock/sleep), and when the setting flips off.
- Glass is **off** when `prefers-reduced-transparency` or `prefers-contrast:
  more` is active and when the user disables it. The renderer already
  honours both in CSS; it additionally reports them to main over a new
  `agent-island:media-prefs { reducedTransparency, moreContrast }` message,
  sent on load and on every `matchMedia` change, so main can hide the native
  panel the moment the system setting flips. Setting `glass` (default `true`).

## 2.5 Renderer — the follower and the restructure

**Follower.** `reportIslandRect` becomes event-driven: a `ResizeObserver` on
`.island` (fires each frame during the width/height transitions), coalesced
with `requestAnimationFrame`, plus a 1s heartbeat replacing today's 300ms
poll. The glass frame therefore tracks the CSS spring exactly, one frame
behind at most. The cursor watcher in main keeps using the same rect.

**Lag cover.** The CSS panel keeps a faint scrim even over native glass
(`--panel-scrim: rgba(8, 8, 10, 0.35)`), so the single frame where the glass
trails the content still reads as a dark panel, and text stays legible over a
bright wallpaper. Contingency if per-frame IPC proves janky in practice: the
renderer sends the *target* rect at transition start and the sidecar animates
the frame with the same spring; the protocol already carries everything
needed. Trigger: visible tearing at the panel's bottom edge.

**Restructure** (`island.css`):

```
.island            background: transparent  (was #000)
.notch-spacer      background: #000         (the band; ears stay #000)
.panel-wrap        background: var(--panel-bg); border-radius: 0 0 16px 16px
```

`--panel-bg` by tier, on `:root[data-glass=…]`:

| Tier | `--panel-bg` | Extra |
| --- | --- | --- |
| `native`, `vibrancy` | `var(--panel-scrim)` | none — the material is real |
| `css` | `rgba(11, 11, 13, 0.82)` | one **static** specular rim: `box-shadow: inset 0 1px 0 rgba(255,255,255,.12), inset 0 -1px 0 rgba(255,255,255,.04)` |

The rim is static and never animates; it is the CSS tier's one nod to the
glass look. Reduced transparency forces the `css` tier with an opaque
`--panel-bg`. Increased contrast does the same with `#000`.

## 2.6 Guidance amendment

`.impeccable.md` gains one line: **materials are not decoration.** Glass is a
surface the panel is made of; the ban on gradients and glows *on rows, cards,
and controls* stands.

---

# Stage 3 — Live activities

## 3.1 Wing priority — `renderer/wing-priority.ts`

The collapsed wings can now show six things. One pure function decides, tested
against a table:

```
needsYou > working agents (Pac feast) > transient live activity (≤ 3.5s)
        > persistent low battery > weather ambient > empty
```

Transient activities: `battery-plugged`, `battery-unplugged`, `battery-low`
(crossing 20% / 10%), `focus-on`, `focus-off`. A transient never interrupts
an agent that is working or waiting — it is simply not shown. Wing width for
any live activity reuses the weather width (`+104px`).

## 3.2 Battery — `main/power.ts`

No sidecar change. Electron's `powerMonitor` gives instant `on-ac` /
`on-battery`; `pmset -g batt` gives the percentage.

- `parsePmset(stdout)` — pure — handles the observed formats:
  `80%; discharging; 11:02 remaining`, `charging; 1:20 remaining`,
  `charged`, `AC attached; not charging`, `(no estimate)`, and the absence
  of any `InternalBattery` line (desktop Mac → `null`, polling stops).
- Runs on `on-ac`/`on-battery`, on `resume`, then every 60s.
- Publishes `agent-island:power { percent, state, minutesRemaining, event }`
  where `event` is `"plugged" | "unplugged" | null` for that push only.
- Renderer: plugged → 3.5s live activity: a bolt whose fill bar scales in
  (`scaleX`) on the left wing, the percentage on the right; unplugged → the
  same without the bolt. Below 20% on battery → persistent small red battery
  in the right wing while idle (it replaces the temperature when weather is
  on). A battery item joins the panel footer.
- No sound, no haptic: macOS already chimes on plug-in.

Setting `battery` (default `true`).

## 3.3 Agent resource meter — `main/proc-stats.ts` + PID plumbing

**PIDs.** The hook bridge scripts run in a shell whose parent *is* the agent:

- `claudeBridgeScript()` (SessionStart) adds `-H "X-Agent-Pid: ${PPID}"`.
- Cursor `bridgeScript()` adds the same. Its parent is Cursor's hook runner
  (an extension-host child), so the measured tree is Cursor's agent tooling,
  not the IDE. Kept as best effort; if manual testing shows it as noise,
  Cursor rows show no meter.
- `routes-claude.ts` `terminalMeta()` and `routes-cursor.ts` read
  `x-agent-pid`, accept `/^\d{1,7}$/`, store `meta.pid`. The daemon's meta
  accumulation carries it to every later snapshot; no schema change (`meta`
  is `z.record(z.unknown())`).
- Codex has no hook. `rollout-reader.ts` `attach()` runs
  `lsof -t <file>` once (best effort, ~30ms); if empty, `pgrep -x codex` is
  used only when it returns exactly one PID. Result goes into the
  `session_started` event's `_meta.pid`. Unresolvable → no meter.

**Sampling.** While the panel is interactive, the setting is on, and at least
one visible session has a `pid`: every 2s, one `ps -axo pid,ppid,%cpu,rss`.

- `parsePs(stdout)` and `subtreeTotals(rows, rootPid)` — pure — sum `%cpu`
  and `rss` over each root's descendant tree (cycle-guarded), returning
  `{ cpu, rssMb, procs }`. A root that no longer exists yields `null`, so a
  reused PID after the agent exits does not attribute a stranger's load.
- Publishes `agent-island:proc-stats { [sessionKey]: totals | null }`.
  Nothing runs while collapsed.

**Rendering.** `SessionRow` appends `34% · 1.2 GB` to the context line,
tabular numerals, tinted toward `--waiting` above 150% CPU and `--failed`
above 300%. The footer shows the total across visible sessions. Sessions
without a PID show nothing, not a dash.

Setting `procStats` (default `true`).

## 3.4 Focus — deep links + a Shortcuts automation

The app cannot read Focus state. A Shortcuts automation can tell it.

**Deep links** — `main/deep-link.ts`. `app.setAsDefaultProtocolClient(
"agent-island")` in packaged builds (`electron-builder.yml` gains
`protocols: [{ name: Agent Island, schemes: [agent-island] }]`); dev logs
that links are unavailable. `app.on("open-url")` → `parseDeepLink(url)` —
pure, tested — accepts exactly:

| URL | Action |
| --- | --- |
| `agent-island://focus/on?name=Work` | Focus active, named |
| `agent-island://focus/off` | Focus inactive |
| `agent-island://toggle` | pin/unpin the panel |
| `agent-island://settings` | open Settings |

Anything else is ignored with one log line. The scheme is reachable by any
local app; the worst it can do is mute sounds or open a window, which is the
same exposure as the existing tray toggle.

**State** — `main/focus.ts`: `{ active, name, since }`, not persisted (a
fresh launch starts un-focused; the "turns on" automation re-fires next
time). Broadcast as `agent-island:focus`.

**Effects** while `focus.active && settings.respectFocus`:

- Sounds: none.
- Haptics: interaction patterns only (`tick`, `commit`); no notification
  rhythms.
- Visual pulses, auto-expand for approvals and questions, and VoiceOver
  announcements are **unchanged** — a blocked agent must still be seen.
- Footer chip `☾ Work`; clicking it clears the state (covers a missed
  "off"). When idle, a small `☾` sits before the count in the right wing.
- `focus-on` / `focus-off` show as 2s transient live activities.

**Setup UX** — Settings → Live activities → "Focus": status line ("Focus:
Work, since 14:02 · via Shortcuts" or "waiting for the first signal"), an
**Open Shortcuts** button, the two URLs with copy buttons, and the steps:
Shortcuts → Automation → New → Focus → choose the Focus → *When turning on*
→ Run immediately → add **Open URLs** with the "on" link; repeat with *When
turning off* and the "off" link. One pair per Focus you use. On macOS before
26 the row explains that Shortcuts automations need macOS 26; the links still
work if anything else opens them. **Verify during Stage 3, before building
the UX:** that macOS 26 Shortcuts offers the Focus trigger with an "Open URLs"
action and that it fires our handler without a confirmation prompt.

Setting `respectFocus` (default `true`).

---

## Settings summary

| Key | Type | Default | Section |
| --- | --- | --- | --- |
| `openWith` | `"hover" \| "swipe"` | `hover` | Appearance |
| `glass` | boolean | `true` | Appearance |
| `battery` | boolean | `true` | Live activities |
| `procStats` | boolean | `true` | Live activities |
| `respectFocus` | boolean | `true` | Live activities |

Settings state additionally exposes `glassSupport`, `focus`, and
`deepLinksRegistered`. `settings.tsx` is already 553 lines and gains two
sections; the existing `Row`/`Toggle` components are reused, and a
`Segmented` control is added for "Open with". If the file passes ~700 lines,
split sections into files — not before.

## Files

**New:** `renderer/motion.ts` (+test), `renderer/gesture.ts` (+test),
`renderer/wing-priority.ts` (+test), `renderer/LiveActivity.tsx`,
`renderer/StatusFooter.tsx` (one footer row rendering usage, battery, the
Focus chip, and the resource total; `UsageFooter.tsx` folds into it), `main/glass.ts` (+test), `main/power.ts`
(+test), `main/proc-stats.ts` (+test), `main/focus.ts`, `main/deep-link.ts`
(+test).

**Modified:** `native/AgentIslandNative.swift`, `main/index.ts`,
`main/windows/notch-window.ts`, `main/settings.ts`, `main/zero-config.ts`,
`preload/index.ts`, `renderer/App.tsx`, `renderer/SessionRow.tsx`, `renderer/settings.tsx`, `styles/island.css`,
`styles/tokens.css`, `styles/settings.css`, `electron-builder.yml`,
`packages/daemon/src/server/routes-claude.ts`, `routes-cursor.ts`,
`packages/daemon/src/adapters/codex/rollout-reader.ts`, `.impeccable.md`,
`README.md` (features list only; privacy section unchanged — nothing new is
transmitted), `docs/STATUS.md`.

## Testing

Pure functions are extracted so vitest covers them without Electron:

- spring sampling: monotone-ish, ends at exactly 1, settle time bounded,
  reduced-motion variant is a step (1.1)
- wheel accumulator: threshold, window expiry, lock-out, both directions (1.2)
- `glassFrame` math including the collapsed `null` case (2.4)
- `parsePmset` against the five observed formats and the desktop case (3.2)
- `parsePs` + `subtreeTotals` including a cycle and a missing root (3.3)
- `x-agent-pid` acceptance/rejection in both routes (3.3)
- `parseDeepLink` accept table and rejects (3.4)
- wing priority table (3.1)

Manual, per stage:

- **1** Open/close on hover and in swipe mode with a trackpad; rubber band
  tracks fingers; Reduce Motion → instant; no black-band jitter.
- **2** The spike (2.2) first. Then: glass ordering holds across Spaces and
  over a full-screen app; Reduce Transparency and Increase Contrast switch it
  off live; `glass hide` on lock; no tearing at the bottom edge during the
  spring; Activity Monitor energy while collapsed equals `main`.
- **3** Plug/unplug shows the moment and yields to a working agent; low
  battery persists while idle; CPU meter tracks a `pnpm test` run in a Claude
  session and disappears when the session ends; Shortcuts automation flips
  the footer chip both ways; `agent-island://toggle` from Terminal via `open`.

## Non-goals

Now Playing / media HUD (MediaRemote fragility), volume/brightness HUD
replacement, file shelf, calendar, camera mirror, multi-display glass (the
island itself is primary-display only), native-animated glass (contingency
only), reading Focus state directly (needs Full Disk Access), pet
spritesheets, GPU re-enablement.

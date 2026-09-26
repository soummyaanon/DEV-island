# Native Island — Rewrite the App in Swift — Plan

_Written 2026-09-26, after v1.9.0. Status: phases 0–3 built in `apps/mac/` (2026-09-26); see the parity checklist at the end. Direction confirmed: the same look, built natively, with every 1.x feature working as it did._

**Goal:** Replace the Electron app (`packages/app`) with a native macOS app written in Swift, with the same features, the same look and the same zero-config setup, and a much smaller footprint. Ship it as Agent Island 2.0 only when it matches 1.x feature for feature.

**Why:**

- **Footprint.** Electron runs Chromium (a renderer, a GPU process and helpers) for a 290 × 37 pt black strip. A native app should idle at a fraction of the memory and wake-ups, and battery life is one of the things this app shows.
- **Fidelity.** Getting the notch pixel-perfect in Electron takes workarounds: measuring the notch via JXA, `window-pin.node`, click-through by reporting rects, and a separate Swift process for glass. In AppKit these are direct APIs.
- **Motion.** SwiftUI springs and Core Animation (`CAShapeLayer`, `CAEmitterLayer`) do natively what the CSS does by hand: spring easings baked into `linear()`, and SVG dash tricks for the charging current.
- **One native process.** The Swift sidecar (`native/AgentIslandNative.swift`: haptics, glass, voice, Apple Intelligence, location, power) already holds the hard native parts. They move in rather than being rewritten.

**Non-goals:** No new features during the rewrite. No change to the hook formats that Claude Code, Codex and Cursor already use. No accounts or network services.

---

## What exists today

| Piece | Size | Fate |
| --- | --- | --- |
| Island UI: `renderer/*` (App, sessions, approval and question cards, assistant bar, crews and sprites, weather, status footer, battery and charging) | ~6,000 lines of TSX + ~4,000 lines of CSS | **Rewrite** in SwiftUI + Core Animation |
| Settings + onboarding windows (`settings.tsx`, `onboarding.tsx`) | ~1,300 lines of TSX + CSS | **Rewrite** in SwiftUI (`Settings` scene) |
| Electron main (`main/*`): notch window, power, weather, focus, jump-back, zero-config hooks, updates, tray, settings store, proc stats, greeting | ~5,000 lines of TS | **Port** to Swift, module by module |
| Swift sidecar: haptics, glass, voice, speech, Apple Intelligence, location, power watch | 1,700 lines of Swift | **Absorb** into the app target, dropping the stdin/stdout protocol |
| Daemon (`packages/daemon`): HTTP + WebSocket on `127.0.0.1:7433`, Claude, Codex and Cursor adapters, held approvals, pending questions, usage | ~2,500 lines of TS, runs under Electron's Node (`utilityProcess.fork`) | **Decision below.** Kept as-is through the transition |
| `packages/shared` types (`SessionSnapshot`, pending question, …) | small | **Mirror** as Swift `Codable` models |

The renderer↔main contract lives in `preload/index.ts` (about 55 calls: `getSessions`/`onSessions`, `approve`, `answer`, `jump`, `getPower`/`onPower`, `askAssistant`, `startVoice`, `haptic`, `setInteractive`, …). This is the parity checklist. Every call becomes a Swift method or `@Observable` property, or is deleted because the window no longer needs it (`reportIslandRect`, `setInteractive`, `winClose`).

## The big decision: the daemon

A Swift app has no Node to run `dist/main.cjs`. The options:

1. **Port the daemon to Swift** (recommended, done last). It's about 2,500 lines of HTTP routes, a WebSocket stream, a Codex rollout tailer and pure mappers. Swift can do it with Network.framework or a small embedded server (Hummingbird / SwiftNIO). The routes, token auth and wire formats stay identical, so the hooks already installed on users' machines keep working. The vitest suites (Claude routes, Codex mapper, Cursor mapper: 71 tests) become the spec, ported to XCTest cases.
2. **Bundle a standalone Node binary** with the app. It's quick, but adds ~40–90 MB and a second runtime to sign and update, which undoes much of the point.
3. **Keep the daemon as a separate install.** No: zero-config is a core promise.

**Plan:** use option 1, as the final phase. Until then the Swift app is a *client*: it connects to the daemon that the installed Electron app (or `pnpm dev`) already runs on `:7433`. That keeps the risky part (hooks, approvals) untouched while the UI is rebuilt.

---

## Architecture (target)

```
AgentIsland.app (Swift, one process)
├─ IslandPanel         NSPanel over the notch: borderless, non-activating,
│                      .statusBar level, canJoinAllSpaces + stationary +
│                      fullScreenAuxiliary. Click-through: global + local
│                      mouse monitors hit-test the island's silhouette and
│                      flip ignoresMouseEvents (replaces setInteractive IPC;
│                      a transparent window alone still eats clicks).
├─ NotchGeometry       NSScreen.safeAreaInsets + auxiliaryTopLeft/RightArea
│                      (replaces the JXA probe); follows display changes.
├─ Views (SwiftUI)     IslandShape (ears r10, corners 12/16, same path as
│                      IslandGlow.islandOutline), wings, panel, cards,
│                      crews, weather, footer, assistant bar.
├─ Effects (CA)        ChargeCurrent: CAShapeLayer strokeStart/End current,
│                      crackle as 7 seeded jittered paths swapped discretely,
│                      rim along the outline. Sparks stayed SwiftUI (radial
│                      rays, not particles). Edge glows per event.
├─ Model (@Observable) Sessions, usage, power, focus, weather, settings,
│                      assistant state. One source of truth, main actor.
├─ DaemonClient        URLSessionWebSocketTask → ws://127.0.0.1:7433/stream,
│                      REST for /sessions, /usage, POST /approvals/:id,
│                      /questions/:id. Token from ~/.agent-island.
├─ Services            Power (IOKit + ProcessInfo, already written), Weather,
│                      Focus (deep links), JumpBack (AX/AppleScript),
│                      ZeroConfig (hook install into ~/.claude, Codex, Cursor),
│                      Updates, ProcStats, Greeting.
├─ Native (absorbed)   Haptics, Glass, Voice/Speech, FoundationModels
│                      assistant, Location. Straight function calls now.
└─ Daemon (phase 7)    Swift port of packages/daemon, same wire format.
```

Rules that carry over from 1.x:

- **The black band never moves.** It stays pixel-aligned with the hardware notch, and only the wings and panel animate.
- **Nothing animates unseen.** Pause all layers and timers while locked or asleep, or when the island is covered (the `.app.paused` rule today).
- **Reduce Motion:** every effect has a still or single-fade fallback. **Increase Contrast:** borders instead of blooms.
- Wing priority stays one pure function (`wing-priority.ts` → `WingPriority.swift`), ported along with its tests.
- Settings stay in the same file and keys (`settings.json`, `settingsVersion`), so 1.x → 2.0 keeps preferences.

**Stack:** Swift 6 (tools 6.2, Approachable Concurrency, main actor by default in the app target), SwiftUI + AppKit, macOS 14+ deployment target (Observation), macOS 26 SDK for FoundationModels and SpeechAnalyzer (weak-linked, as today). SwiftPM executable, `arm64`, bundled by `apps/mac/scripts/bundle.sh`. Tests in Swift Testing. Keep `pnpm`, which still builds the daemon until phase 7.

**Learned in phases 0–2:**

- **It builds with the Command Line Tools alone.** SwiftUI's own macros (`@State`, `@Entry`, `#Preview`) are the exception: their plugin ships only with Xcode. So views hold no `@State`: state lives in `@Observable` models, and one-shot motion uses `keyframeAnimator`. With Xcode, `@State` works again, but the rule keeps the view logic testable anyway.
- **Plain AppKit entry point** (`main.swift`), not a SwiftUI `App`: a scene-less `App` gets an empty window from SwiftUI. Settings (phase 6) will host SwiftUI in an `NSWindow` itself.
- **Pure logic goes in `IslandCore`**, a nonisolated library with no AppKit. The app target holds only the wiring.

---

## Phases

Each phase ends with something runnable next to the Electron app. Electron stays the shipping app until phase 8.

### Phase 0: Skeleton (small)
- [x] `apps/mac/` Swift package, bundle id `com.agentisland.app.next` so it can run beside 1.x (`…native` is already the 1.x sidecar's id); 2.0 ships as `com.agentisland.app`
- [x] App lifecycle: accessory policy (no Dock icon), single instance, login item (right-click menu)
- [x] CI job: `scripts/test.sh` + `scripts/bundle.sh` on the macos-26 runner, next to the existing CI

### Phase 1: Notch shell (medium)
- [x] `IslandPanel` + `NotchMetrics` (real notch width, no-notch fallback, display changes); reads a 185×32 notch on a 16" MacBook Pro
- [x] `IslandShape` with ears and corners; collapsed ↔ expanded with native springs (same stiffness/damping as `motion.ts`)
- [x] Hover-to-open and two-finger swipe (`WheelGesture` ported with its tests; natural scrolling from `isDirectionInvertedFromDevice`); `openWith` read from 1.x's `settings.json`
- [x] Hit-testing so clicks outside the island pass through to the menu bar
- **Done when:** a black island sits on the notch, opens and closes, and never steals clicks. *Built; hover, swipe, click-through, Spaces and full-screen still need a check by hand (1.x draws above it, so quit 1.x first).*

### Phase 2: Battery and charging (small, it's the first win)
- [x] Move `Power` (IOKit source + Low Power Mode) in from the sidecar; `pmset` for percent and Energy Mode, keeping `parsePmset`/`reconcile`/`sourceEvent` behaviour and their tests (all ported; reads are serialized so a slow poll can't land after a charger moment)
- [x] Battery ring view; charging moment in both wings (bolt ring left, % right)
- [x] `ChargeCurrent`: current in from the ears, bolt strike, sparks, fill; reverse on unplug; green, amber and cyan per Energy Mode; rim follows the outline. Reduce Motion: a rim fade only. Increase Contrast: no blooms.
- **Done when:** plug and unplug play the full moments, matching 1.9.0 side by side. *Moments fire and play (debug trigger in `apps/mac/README.md`); the visual side-by-side is still to do.*

### Phase 3: Sessions (large, the core)
- [x] `Codable` models mirroring `packages/shared` (`IslandCore/Wire.swift`); `DaemonClient` over `URLSessionWebSocketTask`, reconnecting with backoff (1.5 s doubling to 15 s), token header sent
- [x] Wings: agent orbs, work crew, idle crew (hide and seek), idle bot, counts (with the working pulse), moments (done/failed), resting bare island; 1.x's width rules per wing
- [x] Expanded panel: bubbles (compact) or rows (detailed) from `sessionView`, offline state, status footer (usage rings with agent marks, battery). Focus and totals: phase 5
- [x] Jump back (`JumpTarget` decides, `JumpBack` does it): exact iTerm2 tab, the project's own VS Code/Cursor window, terminal apps; logged to `~/.agent-island/app.log`
- [x] Edge glows per event: done, failed, question, attention (approve: phase 4; hello: phase 5)
- [x] Robots and orbs drawn natively from `bot-avatars`' own outlines and colours (`SVGPath` parses the library's path data); motion approximates its rig. A pixel-exact port of its matcap shading stays on the 2.1 list
- **Done when:** daily use with Claude Code, Codex and Cursor looks and behaves like 1.x. *Checked end to end against the real daemon with scripted events (working, permission, done, failed); daily use and jump-back clicks still to do by hand.*

### Phase 4: Approvals and questions (medium, highest stakes)
- [x] Approval card (allow/deny, held request), question card (single and multi-select); ⌘Y/⌘N and ⌘1–9 verified against both daemons
- [x] Keyboard and VoiceOver focus trap (⌃⌥⌘I reach-in), announcer (port `a11y.ts` behaviour)
- **Done when:** every approval and question path in the 1.x tests works end to end against the daemon

### Phase 5: Ambient (medium)
- [x] Weather service + scenes (the CSS scenes become SwiftUI/CA scenes); audited scene by scene against weather.css: crescent geometry, ray order, gradient reach, rainbow order/origin/remount replay, per-segment easing, the opening bolt, Reduce Motion stills and Increase Contrast caps
- [x] Focus via Shortcuts deep links, respect-Focus muting
- [x] Sounds (themes, overrides, custom files; synthesised sets rendered by `SoundScore`), haptics (direct calls)
- [x] Greeting (written by Apple Intelligence, verified), update check, per-session resource meter

### Phase 6: Assistant, voice, settings (medium)
- [x] Assistant bar on FoundationModels, in-process (manual `GenerationSchema`, no macros), web answers, shortcuts. The field wears `border-beam`'s own pulse-inner and loading line, ported from its generated CSS (`FieldBeam`, `BeamMotion`)
- [x] Voice in and spoken replies (SpeechAnalyzer / SFSpeechRecognizer fallback; AVSpeechSynthesizer)
- [x] Settings window and onboarding in SwiftUI; same `settings.json`, written byte for byte in 1.x's key order
- [x] Zero-config hook installer, keeping the same safe-merge rules as `zero-config.ts` (gated by `ZeroConfigPolicy`)

### Phase 7: Daemon in Swift (large)
- [x] HTTP + WS server on `127.0.0.1:7433` (Network.framework, hand-written WebSocket), same routes (`/events`, `/events/:agent/:hook`, `/approvals/:id`, `/questions/:id`, `/stream`, `/sessions`, `/usage`, `/health`) and same token auth. Held approval (⌘Y → allow), held question (⌘2 → `updatedInput.answers`) and streaming verified with real hooks
- [x] Claude, Cursor and Codex adapters
- [x] Port the rest of the 71 daemon tests (Swift Testing) against the same 1.x fixtures: 43 more in DaemonParityTests, no behaviour differences. Not portable as unit tests: the Codex watcher's scan/recency and the held-question timeout (app-target timing)
- [x] Motion parity audit (list/wing, battery/charge, greeting/assistant/cards, onboarding/settings): CSS mount animations (row-in, count-roll, sprite-pop, work-bot-in, quota-draw, greet-rise) replay on appear via `Entrance`; count-pulse, hover states, field pill, send key, edge-spark easing/pause/contrast, charger flares and crackle, onboarding chrome and choreography, s-page-in
- [x] Greeting bots' `whirl` and `jumpEvery` (bot-avatars 0.1.1): the ring around the every-third-hop spin; `jumpEvery` is idle-only in the package, so it's inert on the working greeting bots, as in 1.x
- [x] Runs in-process on the main actor; reuses an external daemon when `/health` already answers, like `daemon-manager.ts`
- **Done when:** an unchanged user machine (old hooks) works with only the Swift app installed

### Phase 8: Ship 2.0
- [x] Migration: same settings file, same hook scripts, remove `/Applications/Agent Island.app` 1.x cleanly. 2.0 ships as `Agent Island.app` with 1.x's id `com.agentisland.app`, so 1.x's own updater swaps it in place (verified against the built DMG). First launch stops a leftover 1.x daemon (Electron utility process) and tidies Chromium's files out of the shared userData, once (`MigrationRunner`)
- [x] DMG via the existing release workflow: `apps/mac/scripts/dmg.sh` (bundle.sh ship + the shared `scripts/dmg/assemble.sh`), 3.7 MB; tag-message notes kept; optional Developer ID + notarisation from secrets, ad-hoc otherwise as 1.x
- [ ] Soak: a week of daily use with Electron removed before tagging `v2.0.0`

---

## Risks

| Risk | Mitigation |
| --- | --- |
| Approvals break, and an agent blocks | Daemon untouched until phase 7; then run both daemons against shared fixtures before switching |
| Scope creep ("while we're here…") | Parity checklist = the preload API list; new ideas go to a 2.1 list |
| Two apps to maintain for months | 1.x only gets fixes during the rewrite; no new 1.x features |
| Notch edge cases (external displays, no-notch Macs, full-screen apps, Spaces) | Phase 1 covers them before anything is built on top |
| Signing, notarisation and TCC prompts reset (Accessibility, mic, speech, location) under a new bundle id | Decide the final bundle id in phase 0; document the one-time re-grant in 2.0 notes |

## Open questions

- ~~**Xcode project or SwiftPM?**~~ SwiftPM plus a bundle script: it builds on a machine with only the Command Line Tools, and CI stays one command. Revisit if entitlements or asset catalogs get painful (phase 5–6).
- **Minimum macOS:** 14 (Observation, modern SwiftUI) vs today's 12. Who is still on 12–13?
- **Daemon in-process or a separate helper?** In-process is simpler; a helper survives UI crashes, so approvals never hang. Leaning toward a helper.
- ~~**Repo layout:**~~ `apps/mac/` in this repo, so the daemon tests stay the shared spec.
- **Which display?** Like 1.x, the primary one. If an external display is primary, a MacBook's notch goes unused. Decide before 2.0.

## First step

Phase 0 + 1 + 2 as one milestone: a native notch shell with the battery ring and the full charging/unplug moments, running beside 1.9.0. It exercises the hardest window work (panel, geometry, click-through) and ends with something visibly better than today.

## Parity checklist

Every 1.x feature, from the renderer↔main API (`preload/index.ts`) and `App.tsx`. ✅ built in 2.0, then the phase that owns the rest. Nothing ships in 2.0 until every row is ✅.

| Area | Feature | 2.0 |
| --- | --- | --- |
| Shell | Notch-hugging island, ears, corners, band never moves | ✅ |
| Shell | Every Space, over full-screen apps, stationary under Show Desktop / Stage Manager | ✅ |
| Shell | Click-through outside the island's shape | ✅ |
| Shell | Hover to open; swipe mode (swipe down / click opens, swipe up parks it closed); rubber band; natural scrolling | ✅ |
| Shell | Display changes re-measure the notch and re-centre; width ceiling per display | ✅ |
| Shell | Content-sized open width (min … display ceiling) | ✅ |
| Shell | Pause everything while locked, asleep or covered | ✅ |
| Shell | Reduce Motion and Increase Contrast fallbacks | ✅ |
| Shell | Text size (`textSize`) | Phase 6 |
| Shell | Pin open from the global shortcut (`onToggle`) | Phase 4 |
| Shell | Glass panel (native / vibrancy), Reduce Transparency | Phase 6 |
| Battery | Idle ring with %, charging glow, low blink | ✅ |
| Battery | Charger moments: current, bolt, sparks, fill/drain, Energy Mode colours | ✅ |
| Battery | Low-battery moment and wing | ✅ |
| Battery | Footer battery (idle only) | ✅ |
| Sessions | Live stream, sorting, offline state | ✅ |
| Sessions | Wing priority (attention > moment > charger > working > activity > low > weather) | ✅ |
| Sessions | Orbs per agent kind, work crew +n, idle crew hide and seek, idle bot, moment bow | ✅ |
| Sessions | Bubbles / rows; project, elapsed, activity orb, host · model · mode | ✅ |
| Sessions | Per-session resource meter and footer total (`procStats`) | Phase 5 |
| Sessions | Usage rings (5 h / weekly …) with agent marks and reset times | ✅ |
| Sessions | Jump back to terminal / editor window | ✅ |
| Sessions | Edge glows: done, failed, question, attention | ✅ |
| Sessions | Forced open when an agent needs you | ✅ |
| Approvals | Approval card (allow/deny, plan review), approve chime + glow | Phase 4 |
| Approvals | Question card (single, multi-select), answer via hook or terminal fallback | Phase 4 |
| Approvals | Prompt bar (terminal keystrokes, Cursor Composer), Accessibility hint | Phase 4 |
| Approvals | VoiceOver reach-in shortcut, focus trap, announcer | Phase 4 |
| Ambient | Sounds: themes, per-event overrides, imported files, respect Focus | Phase 5 |
| Ambient | Haptics | Phase 5 |
| Ambient | Weather: wing scene and card, location, units, stale | Phase 5 |
| Ambient | Focus via Shortcuts deep links: chip, clear, on/off moments, mute | Phase 5 |
| Ambient | Hello greeting (on-device line), edge bloom, crew dance | Phase 5 |
| Ambient | Update check, update chip, install | Phase 5 |
| Assistant | Ask bar on Apple Intelligence (and basic mode), bot crew and lines, web answers, timers, shortcuts, island glow | Phase 6 |
| Assistant | Voice in, spoken replies, stop speaking | Phase 6 |
| Settings | Settings window (every pref), onboarding, tray option, login item with approval state | Phase 6 (login item ✅) |
| Settings | Zero-config hook installer, sound import, open Shortcuts | Phase 6 |
| Controls | Footer keys: sound, assistant, prompt, settings, quit | Phase 4–6 (quit ✅) |
| Daemon | Swift daemon, same routes and tests | Phase 7 |

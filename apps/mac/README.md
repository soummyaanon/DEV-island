# Agent Island (native)

The Swift rewrite of the Electron app, per
[the plan](../../docs/superpowers/plans/2026-09-26-swift-native-island.md).
It runs beside 1.x as **Agent Island Next** (`com.agentisland.app.next`).

So far, phases 0–3: the notch shell, the battery, and sessions. See the
plan's parity checklist for what's left.

Sessions come from the daemon on `127.0.0.1:7433`, which 1.x runs. Without
1.x, start it from the repo: `cd packages/daemon && npx tsx src/main.ts`.

```sh
./scripts/test.sh                 # Swift Testing suites (IslandCore)
./scripts/bundle.sh debug --open  # build build/Agent Island Next.app and launch it
```

Right-click the island for Open at Login and Quit. In a debug build you can
play the charger moment (plug, then unplug, alternately) from the menu or a terminal:

```sh
swift - <<'EOF'
import Foundation
DistributedNotificationCenter.default().postNotificationName(
  .init("com.agentisland.app.next.simulateCharge"), object: nil, userInfo: nil, deliverImmediately: true)
EOF
```

1.x draws above this app, so quit 1.x to see this one.

## Quick access

The notch stays minimal; things appear when they're happening:

| Happening | Wings (closed) | Open island |
| --- | --- | --- |
| Zoom / Google Meet call | camera + call time | mute, camera, leave |
| Timer or Pomodoro | ring + time left | pause, +1 min, skip, stop |
| Music playing | artwork + equaliser | artwork, track, progress, controls |
| Browser in front | — | tab title, back, forward, reload, copy link |
| Files dragged at the notch | — | split targets: Files · AirDrop · the running agent (pastes the paths) |
| Meeting in ≤10 min | — | the event, with a Join button |
| Menu bar set to hide | the time (at rest) | — |

Every tool is a left/right split with round keys. Everything else is a **sideways two-finger swipe** away (or click the two dots
in the open island): Agents (Claude Code and Codex tokens today, sessions,
limits, an interactive 7-day line chart and top projects, from their local logs), Controls (volume and output, brightness, Wi-Fi,
Bluetooth devices, AirDrop, Focus, displays with resolution/main/mirroring,
battery), Files (the shelf, drag out or AirDrop), Clipboard (text, links,
images and files; secrets and password managers skipped; memory only),
Today (a month calendar beside the picked day's events, reminders and to-dos), Timers, Widgets (weather, stocks, unit
converter), Prompter (teleprompter under the camera) and Ask (the on-device
assistant, which can also start Pomodoros, add to-dos, control music and
convert units). Each can be switched off in Settings → Quick access.

Links for Shortcuts or launchers: `agent-island://tools/clipboard` (any tab:
controls, shelf, clipboard, agenda, timers, widgets, prompter),
`agent-island://timer?minutes=10&label=Tea`, `agent-island://pomodoro`.

Permissions are asked only when a feature first needs them: Automation (Music,
Spotify, browsers), Accessibility (meeting controls, Safari/Firefox navigation,
media keys), Calendar & Reminders (from the Today tab's Allow), Bluetooth.

In a debug build, `AgentIsland --render-preview <folder>` draws every page to
PNGs for checking layout.

## Layout

- `Sources/IslandCore`: pure logic, no AppKit, and nonisolated. It holds pmset
  parsing and the charger rules, the island outline (ears, corners, crackle),
  the swipe detector, notch sizing, and a read-only view of 1.x's `settings.json`.
  All of it is tested.
- `Sources/IslandCore/Features`: quick access's pure rules (wing priority,
  timers, the unit converter, clipboard privacy, call links and browsers,
  stocks, to-dos, the tools' tabs), all tested.
- `Sources/AgentIsland/Features`: the services behind them (Now Playing,
  meetings, browser, shelf, clipboard, EventKit, system controls), and
  `Views/Hub` their cards, wings and tabs.
- `Sources/AgentIsland`: the app, main actor by default. It holds the panel and
  pointer tracking (`IslandController`), the `@Observable` model, the power
  service (IOKit + `pmset`), the SwiftUI views, and the Core Animation charge
  current.

## Toolchain notes

- It builds with the Command Line Tools alone (no Xcode). The one limitation:
  SwiftUI's own macros (`@State`, `@Entry`, `#Preview`) need Xcode's plugin, so
  views here hold no `@State`. State lives in `@Observable` models, and one-shot
  motion uses `keyframeAnimator`.
- `scripts/test.sh` adds the Swift Testing macro plugin path, which SwiftPM
  misses under the Command Line Tools.
- Logs: `/usr/bin/log show --last 5m --predicate 'subsystem == "com.agentisland.app.next"'`.
  Plain `log` is a zsh builtin.

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

## Layout

- `Sources/IslandCore`: pure logic, no AppKit, and nonisolated. It holds pmset
  parsing and the charger rules, the island outline (ears, corners, crackle),
  the swipe detector, notch sizing, and a read-only view of 1.x's `settings.json`.
  All of it is tested.
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

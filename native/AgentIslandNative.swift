import AppKit
import CoreLocation
import Foundation

// Agent Island's native sidecar — the few AppKit surfaces Electron doesn't
// expose. One long-lived process, newline-delimited text on stdin/stdout:
//
//   → ping                                ← pong
//   → haptic levelChange,55,levelChange   ← ok
//   → location                            ← loc 22.53 88.37  |  loc-error denied
//   → glass caps                          ← glass native | glass vibrancy
//   → glass show x y w h radius belowId   ← ok | err <reason>
//   → glass hide                          ← ok
//   → quit                                (exits)
//
// Long-lived rather than spawned per call because haptics need sub-10ms
// latency; an `osascript` round trip costs 150ms+ and a process spawn. Closing
// our stdin is the shutdown signal.
//
// Threading: stdin is read on a background thread and commands are dispatched
// to the main queue, so the MAIN thread can run a run loop. CoreLocation
// delivers its delegate callbacks through one and would never answer without
// it — this is why the reader isn't simply the main loop.
//
// Every caller treats this binary's absence as a normal state, so nothing here
// needs to be defensive about being unavailable — only about bad input.

/// The complete set macOS offers. There is no waveform control and no
/// intensity, so a recognisable "feel" comes from count and spacing alone —
/// which is why the protocol takes a rhythm rather than a single pattern.
let feedbackPatterns: [String: NSHapticFeedbackManager.FeedbackPattern] = [
  "generic": .generic,
  "alignment": .alignment,
  "levelChange": .levelChange,
]

/// One step of a rhythm: a pattern, then how long to wait before the next.
private struct Step {
  let pattern: NSHapticFeedbackManager.FeedbackPattern
  let gapMs: Int
}

/// Longest gap we'll honour between two taps. A rhythm that outlasts the
/// gesture that triggered it stops reading as feedback and starts reading as a
/// malfunction.
private let maxGapMs = 500

private struct RhythmError: Error {
  let reason: String
}

/// Parse an alternating `pattern,gap,pattern,...` spec. Resolved in full
/// before anything is performed, so a typo is a clean no-op with a useful
/// error rather than half a rhythm played against the user's hand.
private func parseRhythm(_ spec: String) -> Result<[Step], RhythmError> {
  let parts = spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
  guard !parts.isEmpty, !(parts.count == 1 && parts[0].isEmpty) else {
    return .failure(RhythmError(reason: "empty-rhythm"))
  }

  var steps: [Step] = []
  var index = 0
  while index < parts.count {
    guard let pattern = feedbackPatterns[parts[index]] else {
      return .failure(RhythmError(reason: "unknown-pattern \(parts[index])"))
    }
    // A trailing number is this step's gap; its absence ends the rhythm.
    var gap = 0
    if index + 1 < parts.count, let ms = Int(parts[index + 1]) {
      gap = min(max(0, ms), maxGapMs)
      index += 2
    } else {
      index += 1
    }
    steps.append(Step(pattern: pattern, gapMs: gap))
  }
  return .success(steps)
}

private func performRhythm(_ spec: String) -> String {
  let steps: [Step]
  switch parseRhythm(spec) {
  case .failure(let error): return "err \(error.reason)"
  case .success(let parsed): steps = parsed
  }

  let performer = NSHapticFeedbackManager.defaultPerformer
  var offset = 0
  for step in steps {
    if offset == 0 {
      performer.perform(step.pattern, performanceTime: .now)
    } else {
      // A global queue, deliberately: the main thread is parked in readLine
      // with no run loop, so anything scheduled onto it would never fire.
      DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(offset)) {
        performer.perform(step.pattern, performanceTime: .now)
      }
    }
    offset += step.gapMs
  }
  return "ok"
}

private func respond(_ line: String) {
  print(line)
  // stdout is a pipe here, so it's block-buffered — without this the parent
  // waits on a reply that's sitting in our buffer.
  fflush(stdout)
}

// MARK: - Location

/// One-shot location fix.
///
/// Coordinates are rounded to two decimals (~1km) HERE, before they ever reach
/// the pipe — weather is a city-scale question, so the precise fix is never
/// needed and never leaves this process. Any refusal, any delay, any failure
/// comes back as `loc-error`; the parent has a timezone-based fallback and must
/// never be left waiting.
private final class LocationFix: NSObject, CLLocationManagerDelegate {
  private let manager = CLLocationManager()
  private var answered = false
  private var timeout: DispatchWorkItem?

  /// Long enough for a cold GPS/Wi-Fi fix, short enough not to look hung.
  private let timeoutSeconds = 8.0

  func start() {
    manager.delegate = self
    // Kilometre accuracy: cheaper, faster, and all the precision we'd keep.
    manager.desiredAccuracy = kCLLocationAccuracyKilometer

    let work = DispatchWorkItem { [weak self] in self?.finish("loc-error timeout") }
    timeout = work
    DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: work)

    switch manager.authorizationStatus {
    case .notDetermined:
      // Prompts; the answer arrives via locationManagerDidChangeAuthorization.
      manager.requestWhenInUseAuthorization()
    case .denied, .restricted:
      finish("loc-error denied")
    default:
      manager.requestLocation()
    }
  }

  private func finish(_ reply: String) {
    guard !answered else { return }
    answered = true
    timeout?.cancel()
    timeout = nil
    respond(reply)
    // Break the retain cycle with the manager now that we're done.
    manager.delegate = nil
    pendingFix = nil
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    switch manager.authorizationStatus {
    case .notDetermined: break // still waiting on the user
    case .denied, .restricted: finish("loc-error denied")
    default: manager.requestLocation()
    }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let where_ = locations.last else {
      finish("loc-error empty")
      return
    }
    let lat = (where_.coordinate.latitude * 100).rounded() / 100
    let lon = (where_.coordinate.longitude * 100).rounded() / 100
    finish("loc \(lat) \(lon)")
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    // Spaces would break the parent's line parsing.
    let reason = error.localizedDescription.replacingOccurrences(of: " ", with: "-")
    finish("loc-error \(reason)")
  }
}

/// Held while a fix is in flight — a CLLocationManager whose delegate is
/// deallocated simply never answers.
private var pendingFix: LocationFix?

private func requestLocation() {
  guard CLLocationManager.locationServicesEnabled() else {
    respond("loc-error services-off")
    return
  }
  if pendingFix != nil {
    respond("loc-error busy")
    return
  }
  let fix = LocationFix()
  pendingFix = fix
  fix.start()
}


// MARK: - Glass

/// The Liquid Glass sheet under the island's expanded panel.
///
/// Electron's web view can't refract the wallpaper — `backdrop-filter` in a
/// transparent window only sees the page — so this process owns one
/// borderless, click-through panel holding the real material and keeps it
/// ordered directly BELOW the Electron overlay. The parent tells us the frame
/// (Electron screen points: primary display, top-left origin, y down) every
/// time the panel moves; we snap to it immediately, no animation of our own,
/// so the glass never drifts from the CSS spring it follows.
private final class GlassPanel {
  let panel: NSPanel
  private let effect: NSView
  let tier: String
  private var belowWindowId: Int = 0

  init() {
    // NSGlassEffectView is looked up by name so this file still compiles
    // against an older SDK (CI runs macos-14); KVC configures it.
    if let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
      let view = glassClass.init(frame: .zero)
      view.setValue(NSNumber(value: 16.0), forKey: "cornerRadius")
      // Dark glass, not frosted grey: a heavy black tint leaves only a hint of
      // the wallpaper's light and colour bleeding through at the edges.
      view.setValue(NSColor.black.withAlphaComponent(0.82), forKey: "tintColor")
      effect = view
      tier = "native"
    } else {
      let view = NSVisualEffectView(frame: .zero)
      view.material = .hudWindow
      view.blendingMode = .behindWindow
      view.state = .active
      view.wantsLayer = true
      view.layer?.cornerRadius = 16
      view.layer?.masksToBounds = true
      effect = view
      tier = "vibrancy"
    }

    panel = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    // Same level Electron uses for "screen-saver"; ordering below the overlay
    // keeps the glass beneath the web content at that level.
    panel.level = .screenSaver
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient,
    ]
    panel.contentView = effect

    // Space switches can reshuffle ordering; put the glass back under the island.
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.reassertOrder() }
  }

  func show(x: Double, y: Double, width: Double, height: Double, radius: Double, belowId: Int) {
    guard let primary = NSScreen.screens.first else { return }
    // Electron: primary top-left origin, y down. AppKit: primary bottom-left, y up.
    let frame = NSRect(x: x, y: primary.frame.height - y - height, width: width, height: height)
    setRadius(radius)
    belowWindowId = belowId
    panel.setFrame(frame, display: true)
    if !panel.isVisible { panel.orderFrontRegardless() }
    reassertOrder()
  }

  func hide() {
    panel.orderOut(nil)
  }

  private func setRadius(_ radius: Double) {
    if tier == "native" {
      effect.setValue(NSNumber(value: radius), forKey: "cornerRadius")
    } else {
      effect.layer?.cornerRadius = CGFloat(radius)
    }
  }

  private func reassertOrder() {
    guard panel.isVisible else { return }
    if belowWindowId > 0 {
      panel.order(.below, relativeTo: belowWindowId)
    }
  }
}

private var glassPanel: GlassPanel?

private func glassCaps() -> String {
  NSClassFromString("NSGlassEffectView") != nil ? "glass native" : "glass vibrancy"
}

private func handleGlass(_ argument: String) -> String {
  let parts = argument.split(separator: " ").map(String.init)
  guard let sub = parts.first else { return "err glass-missing-subcommand" }
  switch sub {
  case "caps":
    return glassCaps()
  case "hide":
    glassPanel?.hide()
    return "ok"
  case "show":
    // glass show x y w h radius belowId
    guard parts.count >= 7,
      let x = Double(parts[1]), let y = Double(parts[2]),
      let w = Double(parts[3]), let h = Double(parts[4]),
      let radius = Double(parts[5]), let below = Int(parts[6])
    else { return "err glass-bad-args" }
    guard w > 0, h > 0 else { return "err glass-empty" }
    if glassPanel == nil { glassPanel = GlassPanel() }
    glassPanel?.show(x: x, y: y, width: w, height: h, radius: radius, belowId: below)
    return "ok"
  default:
    return "err glass-unknown \(sub)"
  }
}

// MARK: - Command loop

private func handle(_ input: String) {
  let split = input.firstIndex(of: " ")
  let command = split.map { String(input[input.startIndex..<$0]) } ?? input
  let argument = split.map { String(input[input.index(after: $0)...]) } ?? ""

  switch command {
  case "ping": respond("pong")
  case "haptic": respond(performRhythm(argument))
  // Answers later, out of band — the only asynchronous command.
  case "location": requestLocation()
  case "glass": respond(handleGlass(argument))
  case "quit": exit(0)
  default: respond("err unknown-command \(command)")
  }
}

// Reader on its own thread so the main thread is free to run a run loop for
// CoreLocation. Commands hop back to main, so all state above is touched from
// exactly one thread and needs no locking.
let reader = Thread {
  while let line = readLine(strippingNewline: true) {
    let input = line.trimmingCharacters(in: .whitespaces)
    if input.isEmpty { continue }
    DispatchQueue.main.async { handle(input) }
  }
  // stdin closed: the parent is gone or shutting us down.
  DispatchQueue.main.async { exit(0) }
}
reader.stackSize = 1 << 19
reader.start()

// An NSApplication, not a bare run loop: the glass panel is a real window, and
// AppKit only draws windows for a process that has one. Accessory policy keeps
// us out of the Dock and the ⌘-Tab switcher. CoreLocation's delegate callbacks
// still arrive on this main loop.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.run()

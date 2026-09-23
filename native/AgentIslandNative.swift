import AVFoundation
import AppKit
import CoreLocation
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(Speech)
import Speech
#endif

// Agent Island's native sidecar — the few AppKit surfaces Electron doesn't
// expose. One long-lived process, newline-delimited text on stdin/stdout:
//
//   → ping                                ← pong
//   → haptic levelChange,55,levelChange   ← ok
//   → location                            ← loc 22.53 88.37  |  loc-error denied
//   → glass caps                          ← glass native | glass vibrancy
//   → glass show x y w h radius belowId   ← ok | err <reason>
//   → glass hide                          ← ok
//   → ai caps                             ← ai available | ai basic <why the model can't>
//   → ai ask <id> <b64 json>              ← ai delta <id> <b64 text>… ai done <id>
//                                           | ai tool <id> <name> <b64 step>
//                                           | ai action <id> <b64 json> | ai error <id> <reason>
//   → ai cancel <id>                      ← (the stream ends with ai error <id> cancelled)
//   → ai mode basic|auto                  ← ai available | ai basic <reason>
//   → ai reset                            ← ok
//   → voice start <id>                    ← voice level <id> <0-1>… voice partial <id> <b64>…
//                                           voice final <id> <b64> | voice error <id> <reason>
//   → voice stop <id>                     ← (finishes early; the final follows)
//   → speak <b64 text> | speak stop       ← speak done
//   → speak voice                         ← voice-name <identifier> (Speaker's pick)
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
      view.setValue(NSColor.black.withAlphaComponent(0.9), forKey: "tintColor")
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
    // Dark glass regardless of the system appearance: in the light appearance
    // the material lifts toward white and no tint gets it back to black.
    panel.appearance = NSAppearance(named: .darkAqua)
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

// MARK: - Apple Intelligence

/// The on-device model (Foundation Models, macOS 26) behind the island's
/// "Ask" bar — a Siri-sized assistant that knows what your agents are doing.
///
/// Nothing leaves the Mac: the parent sends the question plus a short plain-
/// text snapshot of the sessions, and the reply streams back as cumulative
/// base64 text so newlines and spaces survive the line protocol. The model can
/// call two tools; neither acts on its own. `openSession` asks the parent to
/// jump to a terminal (harmless, instant), `draftAgentPrompt` only proposes a
/// message — the user confirms it in the island before anything is typed.
///
/// `#if canImport` keeps this file building on older SDKs (CI's macos-14), and
/// the build script weak-links the framework so the binary still launches on
/// macOS 12–15, where `ai caps` simply answers unavailable.

private func b64(_ text: String) -> String {
  Data(text.utf8).base64EncodedString()
}

private func unb64(_ text: String) -> String? {
  Data(base64Encoded: text).flatMap { String(data: $0, encoding: .utf8) }
}

private func emitAction(_ id: String, _ payload: [String: String]) {
  guard let data = try? JSONSerialization.data(withJSONObject: payload),
    let json = String(data: data, encoding: .utf8)
  else { return }
  DispatchQueue.main.async { respond("ai action \(id) \(b64(json))") }
}

/// A tool started: the island shows the step ("Opening Safari…") and the orb
/// switches to the tool's own animation while it runs.
private func emitTool(_ id: String, _ name: String, _ detail: String) {
  DispatchQueue.main.async { respond("ai tool \(id) \(name) \(b64(detail))") }
}

/// Find an installed app by name, case-insensitively, in the usual places.
private func findApplication(_ name: String) -> URL? {
  let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
  let fm = FileManager.default
  let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
               "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
  var fuzzy: URL?
  for root in roots {
    guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
    for item in items where item.hasSuffix(".app") {
      let base = String(item.dropLast(4)).lowercased()
      let url = URL(fileURLWithPath: root).appendingPathComponent(item)
      if base == wanted { return url }
      // Fuzzy only on a whole-word prefix ("visual studio" → "Visual Studio
      // Code"), never an arbitrary substring that happens to match.
      if fuzzy == nil, base.hasPrefix(wanted + " ") || base.hasPrefix(wanted) && wanted.count >= 4 {
        fuzzy = url
      }
    }
  }
  return fuzzy
}

/// `shortcuts list`, cached for the session — it's a subprocess and slow-ish.
private var shortcutNames: [String]?

private func listShortcuts() -> [String] {
  if let cached = shortcutNames { return cached }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
  process.arguments = ["list"]
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = FileHandle.nullDevice
  do { try process.run() } catch { return [] }
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  let names = String(data: data, encoding: .utf8)?
    .split(separator: "\n").map { String($0) }.filter { !$0.isEmpty } ?? []
  shortcutNames = names
  return names
}

#if canImport(FoundationModels)

/// Tools reach the request that invoked them through this, so an action is
/// tagged with the id of the question that caused it.
@available(macOS 26.0, *)
private final class RequestBox: @unchecked Sendable {
  var id = ""
  /// The latest session snapshot, for getAgentSessions.
  var context = ""
  /// The user's own words, so tools with side effects can check they were asked.
  var prompt = ""

  /// Did the user actually ask for this? Guards tools the model is prone to
  /// reach for uninvited (a web search that opens a browser tab, reading the
  /// clipboard).
  func mentions(_ words: [String]) -> Bool {
    let p = prompt.lowercased()
    return words.contains { p.contains($0) }
  }
}

@available(macOS 26.0, *)
private struct OpenSessionTool: Tool {
  let box: RequestBox
  let name = "openSession"
  let description =
    "Bring one coding-agent session's terminal or editor to the front. Use when the user asks to open, show, go to or jump to a project."
  var parameters: GenerationSchema {
    GenerationSchema(
      type: GeneratedContent.self,
      properties: [
        GenerationSchema.Property(
          name: "project", description: "The session's project folder name, exactly as listed", type: String.self)
      ])
  }
  func call(arguments: GeneratedContent) async throws -> String {
    let project = (try? arguments.value(String.self, forProperty: "project")) ?? ""
    emitAction(box.id, ["kind": "open", "project": project])
    return "Brought \(project) to the front."
  }
}

@available(macOS 26.0, *)
private struct DraftAgentPromptTool: Tool {
  let box: RequestBox
  let name = "draftAgentPrompt"
  let description =
    "Draft a message to send to one coding agent (Claude Code, Codex or Cursor). Use when the user wants to tell, ask or instruct an agent. The user reviews and confirms it before it is sent."
  var parameters: GenerationSchema {
    GenerationSchema(
      type: GeneratedContent.self,
      properties: [
        GenerationSchema.Property(
          name: "project", description: "The session's project folder name, exactly as listed", type: String.self),
        GenerationSchema.Property(
          name: "message", description: "The message for the agent, in the user's words", type: String.self),
      ])
  }
  func call(arguments: GeneratedContent) async throws -> String {
    let project = (try? arguments.value(String.self, forProperty: "project")) ?? ""
    let message = (try? arguments.value(String.self, forProperty: "message")) ?? ""
    emitAction(box.id, ["kind": "draft", "project": project, "message": message])
    return "Drafted the message for \(project); the user will confirm before it is sent."
  }
}

// MARK: Agentic tools
//
// What makes the assistant act, not just answer. Tools that are harmless and
// instantly reversible (open an app or a page, copy text, change the volume,
// start a timer) run straight away. Anything that could do real work on the
// user's behalf — running one of their Shortcuts, messaging an agent — only
// ever PROPOSES: the island shows it and waits for the user's click.

@available(macOS 26.0, *)
private func stringArg(_ args: GeneratedContent, _ key: String) -> String {
  ((try? args.value(String.self, forProperty: key)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

@available(macOS 26.0, *)
private func schema(_ props: [(String, String, Any.Type)]) -> GenerationSchema {
  GenerationSchema(
    type: GeneratedContent.self,
    properties: props.map { name, description, type in
      if type == Int.self {
        return GenerationSchema.Property(name: name, description: description, type: Int.self)
      }
      return GenerationSchema.Property(name: name, description: description, type: String.self)
    })
}

@available(macOS 26.0, *)
private struct OpenAppTool: Tool {
  let box: RequestBox
  let name = "openApp"
  let description = "Open (launch or bring forward) an application on this Mac by its name, e.g. Safari, Notes, Music, Xcode."
  var parameters: GenerationSchema { schema([("name", "The application's name", String.self)]) }
  func call(arguments: GeneratedContent) async throws -> String {
    let app = stringArg(arguments, "name")
    emitTool(box.id, "openApp", "Opening \(app)")
    guard let url = findApplication(app) else { return "No app called \(app) is installed." }
    await MainActor.run {
      NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
    return "Opened \(url.deletingPathExtension().lastPathComponent)."
  }
}

@available(macOS 26.0, *)
private struct OpenWebsiteTool: Tool {
  let box: RequestBox
  let name = "openWebsite"
  let description = "Open a web page in the default browser. Use for a specific site or link."
  var parameters: GenerationSchema { schema([("url", "The address, e.g. github.com or https://apple.com", String.self)]) }
  func call(arguments: GeneratedContent) async throws -> String {
    var raw = stringArg(arguments, "url")
    if !raw.contains("://") { raw = "https://" + raw }
    // Web pages only: never file://, custom schemes or anything that could launch a handler.
    guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
      scheme == "https" || scheme == "http", url.host != nil
    else { return "That isn't a web address I can open." }
    emitTool(box.id, "openWebsite", "Opening \(url.host ?? raw)")
    _ = await MainActor.run { NSWorkspace.shared.open(url) }
    return "Opened \(url.absoluteString)."
  }
}

@available(macOS 26.0, *)
private struct SearchWebTool: Tool {
  let box: RequestBox
  let name = "searchWeb"
  let description = "Search the web in the default browser. Use for current events, facts you don't know, or when the user asks to look something up."
  var parameters: GenerationSchema { schema([("query", "What to search for", String.self)]) }
  func call(arguments: GeneratedContent) async throws -> String {
    let query = stringArg(arguments, "query")
    guard box.mentions(["search", "look up", "lookup", "google", "online", "on the web", "browse", "latest", "news", "find out"]) else {
      return "Not searched: the user didn't ask for a web search. Answer from your own knowledge instead."
    }
    emitTool(box.id, "searchWeb", "Searching “\(query)”")
    var parts = URLComponents(string: "https://www.google.com/search")!
    parts.queryItems = [URLQueryItem(name: "q", value: query)]
    guard let url = parts.url else { return "Couldn't search for that." }
    _ = await MainActor.run { NSWorkspace.shared.open(url) }
    return "Opened a web search for \(query) in the browser."
  }
}

@available(macOS 26.0, *)
private struct ReadClipboardTool: Tool {
  let box: RequestBox
  let name = "readClipboard"
  let description =
    "Read the text on the clipboard. ONLY when the user explicitly mentions the clipboard or something they copied or pasted; never for greetings or other questions."
  var parameters: GenerationSchema { schema([]) }
  func call(arguments: GeneratedContent) async throws -> String {
    guard box.mentions(["clipboard", "copied", "copy", "paste", "pasted"]) else {
      return "Not read: the user didn't mention the clipboard. Answer the question directly."
    }
    emitTool(box.id, "readClipboard", "Reading the clipboard")
    let text = await MainActor.run { NSPasteboard.general.string(forType: .string) } ?? ""
    if text.isEmpty { return "The clipboard has no text." }
    // The on-device context window is small; a long copy is cut, and says so.
    return text.count > 3000 ? String(text.prefix(3000)) + "\n[truncated]" : text
  }
}

@available(macOS 26.0, *)
private struct CopyToClipboardTool: Tool {
  let box: RequestBox
  let name = "copyToClipboard"
  let description = "Put text on the clipboard so the user can paste it. Use when asked to copy something, or after writing a draft the user wants to paste."
  var parameters: GenerationSchema { schema([("text", "The exact text to copy", String.self)]) }
  func call(arguments: GeneratedContent) async throws -> String {
    let text = (try? arguments.value(String.self, forProperty: "text")) ?? ""
    emitTool(box.id, "copyToClipboard", "Copying to the clipboard")
    await MainActor.run {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    }
    return "Copied."
  }
}

@available(macOS 26.0, *)
private struct SetVolumeTool: Tool {
  let box: RequestBox
  let name = "setVolume"
  let description = "Set the Mac's output volume, 0 to 100. 0 mutes."
  var parameters: GenerationSchema { schema([("percent", "Volume from 0 to 100", Int.self)]) }
  func call(arguments: GeneratedContent) async throws -> String {
    let percent = max(0, min(100, (try? arguments.value(Int.self, forProperty: "percent")) ?? 50))
    emitTool(box.id, "setVolume", "Volume \(percent)%")
    // Standard Additions: no Automation permission needed for this one.
    let ok = await MainActor.run { () -> Bool in
      var error: NSDictionary?
      NSAppleScript(source: "set volume output volume \(percent)")?.executeAndReturnError(&error)
      return error == nil
    }
    return ok ? "Volume set to \(percent)%." : "Couldn't change the volume."
  }
}

@available(macOS 26.0, *)
private struct StartTimerTool: Tool {
  let box: RequestBox
  let name = "startTimer"
  let description = "Start a countdown timer; the island alerts the user when it ends. Use for 'remind me in 10 minutes' or 'set a timer'."
  var parameters: GenerationSchema {
    schema([("minutes", "How many minutes, 1 to 720", Int.self), ("label", "What it's for, or empty", String.self)])
  }
  func call(arguments: GeneratedContent) async throws -> String {
    let minutes = max(1, min(720, (try? arguments.value(Int.self, forProperty: "minutes")) ?? 5))
    let label = stringArg(arguments, "label")
    emitTool(box.id, "startTimer", "Timer · \(minutes) min")
    emitAction(box.id, ["kind": "timer", "minutes": String(minutes), "label": label])
    return "Started a \(minutes)-minute timer\(label.isEmpty ? "" : " for \(label)")."
  }
}

@available(macOS 26.0, *)
private struct RunShortcutTool: Tool {
  let box: RequestBox
  let name = "runShortcut"
  let description =
    "Run one of the user's Shortcuts (the Shortcuts app) by name. This is how to do things like turning on Focus, sending messages, home automation, or anything the user has a shortcut for. The user confirms before it runs."
  var parameters: GenerationSchema { schema([("name", "The shortcut's name", String.self)]) }
  func call(arguments: GeneratedContent) async throws -> String {
    let wanted = stringArg(arguments, "name")
    emitTool(box.id, "runShortcut", "Finding the “\(wanted)” shortcut")
    let names = listShortcuts()
    let match = names.first { $0.lowercased() == wanted.lowercased() }
      ?? names.first { $0.lowercased().contains(wanted.lowercased()) }
    guard let match else {
      let some = names.prefix(12).joined(separator: ", ")
      return names.isEmpty
        ? "The user has no Shortcuts."
        : "No shortcut called \(wanted). Some of theirs: \(some)."
    }
    emitAction(box.id, ["kind": "shortcut", "name": match])
    return "Asked the user to confirm running the \(match) shortcut."
  }
}

@available(macOS 26.0, *)
private struct ListShortcutsTool: Tool {
  let box: RequestBox
  let name = "listShortcuts"
  let description = "List the names of the user's Shortcuts, to find one that fits what they asked."
  var parameters: GenerationSchema { schema([]) }
  func call(arguments: GeneratedContent) async throws -> String {
    emitTool(box.id, "listShortcuts", "Looking through your Shortcuts")
    let names = listShortcuts()
    return names.isEmpty ? "The user has no Shortcuts." : names.prefix(60).joined(separator: "\n")
  }
}

@available(macOS 26.0, *)
private struct AgentSessionsTool: Tool {
  let box: RequestBox
  let name = "getAgentSessions"
  let description =
    "Get the user's coding-agent sessions (Claude Code, Codex, Cursor) right now: project, state and current activity. Call this for ANY question about their agents or sessions."
  var parameters: GenerationSchema { schema([]) }
  func call(arguments: GeneratedContent) async throws -> String {
    emitTool(box.id, "getAgentSessions", "Checking your agents")
    return box.context.isEmpty ? "No agent sessions are running." : box.context
  }
}

@available(macOS 26.0, *)
private struct DateTimeTool: Tool {
  let box: RequestBox
  let name = "getDateTime"
  let description = "Get the current local date, time and weekday."
  var parameters: GenerationSchema { schema([]) }
  func call(arguments: GeneratedContent) async throws -> String {
    emitTool(box.id, "getDateTime", "Checking the date")
    return DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .short)
  }
}

/// Belt and braces: drop any "[Background …]" block the model echoes back.
private func stripBackground(_ text: String) -> String {
  guard text.hasPrefix("[") else { return text }
  var rest = Substring(text)
  while rest.hasPrefix("[") {
    guard let close = rest.firstIndex(of: "]") else { return "" }  // still streaming it
    rest = rest[rest.index(after: close)...].drop(while: { $0.isWhitespace })
  }
  return String(rest)
}

private let aiInstructions = """
  You are the assistant inside Agent Island, the Dynamic Island on the user's Mac — an agent \
  like Siri that can act, not only answer. You are a capable general assistant: answer \
  questions, explain, brainstorm, do quick maths, translate, and draft or rewrite text. When \
  the user asks you to DO something, use your tools rather than telling them how: openApp, \
  openWebsite, searchWeb, readClipboard, copyToClipboard, setVolume, startTimer, \
  listShortcuts and runShortcut for anything else the user has a shortcut for. You also know \
  the user's coding agents (Claude Code, Codex, Cursor) through getAgentSessions. Use openSession to jump to a \
  project and draftAgentPrompt to tell or ask an agent something. You may chain several tools \
  for one request. For anything about the user's agents or sessions, call getAgentSessions \
  first and answer from it; never invent sessions. For the date or time, call getDateTime; \
  never search for it. Only use searchWeb when the user asks to look something up or needs \
  current information you don't have. Only read the clipboard when the user talks about it. For \
  greetings and small talk, just reply. Never claim you did something a tool didn't report. Write plain text \
  without markdown headings; after acting, say what you did in one short sentence.
  """

@available(macOS 26.0, *)
private final class Assistant {
  private let box = RequestBox()
  private var session: LanguageModelSession?
  private var task: Task<Void, Never>?
  private var currentId = ""

  private func freshSession() -> LanguageModelSession {
    LanguageModelSession(
      tools: [
        AgentSessionsTool(box: box), DateTimeTool(box: box),
        OpenSessionTool(box: box), DraftAgentPromptTool(box: box), OpenAppTool(box: box),
        OpenWebsiteTool(box: box), SearchWebTool(box: box), ReadClipboardTool(box: box),
        CopyToClipboardTool(box: box), SetVolumeTool(box: box), StartTimerTool(box: box),
        ListShortcutsTool(box: box), RunShortcutTool(box: box),
      ],
      instructions: aiInstructions)
  }

  func reset() {
    task?.cancel()
    session = nil
  }

  func cancel(_ id: String) {
    if id == currentId { task?.cancel() }
  }

  func ask(id: String, prompt: String, context: String) {
    // One answer at a time: a new question supersedes the one in flight.
    task?.cancel()
    currentId = id
    box.id = id
    // Plain commands ("open Safari", "timer 5 minutes", "volume 30") don't
    // need the model: the command reader does them instantly and exactly,
    // and the model is kept for everything that needs understanding.
    if basicCommand(id: id, prompt: prompt, context: context) { return }
    if session == nil || session?.isResponding == true { session = freshSession() }
    // The date and the sessions are tools (getDateTime, getAgentSessions), not
    // text in the question: the small on-device model parroted any background
    // it was handed straight back into its answer.
    box.context = context
    box.prompt = prompt
    let full = prompt
    task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.stream(id: id, prompt: full, original: prompt, context: context, attempt: 1)
    }
  }

  /// Longest the model may go without producing anything before it's stopped.
  private let stallSeconds: UInt64 = 25

  @MainActor
  private func stream(id: String, prompt: String, original: String, context: String, attempt: Int) async {
    guard let session else { return }
    var last = ""
    var lastActivity = Date()
    var stalled = false
    // Watchdog: a hung generation (it happens) must not leave the orb
    // spinning forever.
    let watchdog = Task { @MainActor in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if Date().timeIntervalSince(lastActivity) > Double(stallSeconds) {
          stalled = true
          self.task?.cancel()
          return
        }
      }
    }
    defer { watchdog.cancel() }
    do {
      for try await snapshot in session.streamResponse(to: prompt) {
        if Task.isCancelled { break }
        lastActivity = Date()
        let text = stripBackground(snapshot.content)
        if text != last {
          last = text
          respond("ai delta \(id) \(b64(text))")
        }
      }
      if stalled {
        respond("ai error \(id) timeout")
      } else {
        respond(Task.isCancelled ? "ai error \(id) cancelled" : "ai done \(id)")
      }
    } catch LanguageModelSession.GenerationError.guardrailViolation {
      respond("ai error \(id) guardrail")
    } catch {
      if stalled { return respond("ai error \(id) timeout") }
      if Task.isCancelled { return respond("ai error \(id) cancelled") }
      // Anything else — a full context window, a model hiccup, a tool that
      // threw: start a fresh session and try once more; then let the command
      // reader have a go; only then admit defeat.
      self.session = freshSession()
      if attempt == 1, last.isEmpty {
        await stream(id: id, prompt: prompt, original: original, context: context, attempt: 2)
      } else if last.isEmpty, basicCommand(id: id, prompt: original, context: context) {
        return
      } else if !last.isEmpty {
        respond("ai done \(id)")
      } else {
        let reason = String(describing: error).contains("exceededContextWindowSize") ? "context-full" : "model-failed"
        respond("ai error \(id) \(reason)")
      }
    }
  }
}

/// `Any?` because a global can't carry `@available` in a script-mode file.
private var assistantBox: Any?
@available(macOS 26.0, *)
private var assistant: Assistant? {
  get { assistantBox as? Assistant }
  set { assistantBox = newValue }
}

@available(macOS 26.0, *)
private func modelCaps() -> String {
  switch SystemLanguageModel.default.availability {
  case .available:
    return "ai available"
  case .unavailable(.deviceNotEligible):
    return "ai unavailable device-not-eligible"
  case .unavailable(.appleIntelligenceNotEnabled):
    return "ai unavailable not-enabled"
  case .unavailable(.modelNotReady):
    return "ai unavailable model-not-ready"
  case .unavailable:
    return "ai unavailable other"
  }
}

#endif


// MARK: Basic assistant (no Apple Intelligence)
//
// Macs without Apple Intelligence — older macOS, or the feature off or not
// supported — still get the island's everyday actions. A small, literal
// command reader covers them with the same tools and the same protocol; only
// open-ended answers need the model, and it says so plainly.

private func basicReply(_ id: String, _ text: String) {
  respond("ai delta \(id) \(b64(text))")
  respond("ai done \(id)")
}

private func openURL(_ url: URL) { NSWorkspace.shared.open(url) }

private func setSystemVolume(_ percent: Int) -> Bool {
  var error: NSDictionary?
  NSAppleScript(source: "set volume output volume \(percent)")?.executeAndReturnError(&error)
  return error == nil
}

/// Read one plain command. Returns false when it isn't one we know.
private func basicCommand(id: String, prompt: String, context: String) -> Bool {
  var q = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
  for lead in ["hey siri ", "please ", "can you ", "could you ", "would you ", "i want to ", "go ahead and "] {
    if q.hasPrefix(lead) { q = String(q.dropFirst(lead.count)) }
  }
  if q.hasSuffix(" please") { q = String(q.dropLast(7)) }
  func match(_ pattern: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
      let m = re.firstMatch(in: q, range: NSRange(q.startIndex..., in: q))
    else { return nil }
    return (0..<m.numberOfRanges).map { i in
      Range(m.range(at: i), in: q).map { String(q[$0]) } ?? ""
    }
  }

  if let m = match(#"^(?:set (?:a )?)?timer (?:for )?(\d+) ?(m|min|mins|minute|minutes|h|hr|hour|hours)(?: (?:for|to) (.+))?$"#)
    ?? match(#"^remind me in (\d+) ?(m|min|mins|minute|minutes|h|hr|hour|hours)(?: to (.+))?$"#)
  {
    let n = Int(m[1]) ?? 5
    let minutes = max(1, min(720, m[2].hasPrefix("h") ? n * 60 : n))
    emitTool(id, "startTimer", "Timer · \(minutes) min")
    emitAction(id, ["kind": "timer", "minutes": String(minutes), "label": m[3]])
    basicReply(id, "Started a \(minutes)-minute timer\(m[3].isEmpty ? "" : " for \(m[3])").")
    return true
  }
  if let m = match(#"^(?:set (?:the )?)?volume (?:to )?(\d+)%?$"#) {
    let v = max(0, min(100, Int(m[1]) ?? 50))
    emitTool(id, "setVolume", "Volume \(v)%")
    basicReply(id, setSystemVolume(v) ? "Volume set to \(v)%." : "Couldn't change the volume.")
    return true
  }
  if match(#"^(?:mute|mute (?:the )?(?:sound|volume))$"#) != nil {
    emitTool(id, "setVolume", "Volume 0%")
    basicReply(id, setSystemVolume(0) ? "Muted." : "Couldn't change the volume.")
    return true
  }
  if let m = match(#"^(?:search(?: the web)?(?: for)?|google|look up) (.+)$"#) {
    emitTool(id, "searchWeb", "Searching “\(m[1])”")
    var parts = URLComponents(string: "https://www.google.com/search")!
    parts.queryItems = [URLQueryItem(name: "q", value: m[1])]
    if let url = parts.url { openURL(url) }
    basicReply(id, "Searching the web for \(m[1]).")
    return true
  }
  if let m = match(#"^run (?:the |my )?(?:shortcut )?(.+?)(?: shortcut)?$"#) {
    let wanted = m[1]
    let names = listShortcuts()
    if let name = names.first(where: { $0.lowercased() == wanted }) ?? names.first(where: { $0.lowercased().contains(wanted) }) {
      emitTool(id, "runShortcut", "Finding the “\(name)” shortcut")
      emitAction(id, ["kind": "shortcut", "name": name])
      basicReply(id, "Ready to run \(name) — press Run.")
      return true
    }
  }
  if let m = match(#"^(?:open|launch|start|go to|show) (.+)$"#),
    m[1].split(separator: " ").count <= 4
  {
    // Short names only: "open the report and summarise it" is a request for
    // the model, not an app called "the report and summarise it".
    let target = m[1].hasPrefix("the ") ? String(m[1].dropFirst(4)) : m[1]
    // A session in the snapshot ("- website (Claude Code): …") wins over an app.
    for line in context.split(separator: "\n") {
      guard line.hasPrefix("- "), let paren = line.range(of: " (") else { continue }
      let project = String(line[line.index(line.startIndex, offsetBy: 2)..<paren.lowerBound])
      if project.lowercased() == target || target == "\(project.lowercased()) session" {
        emitTool(id, "openSession", "Opening \(project)")
        emitAction(id, ["kind": "open", "project": project])
        basicReply(id, "Opened \(project).")
        return true
      }
    }
    if target.contains("."), !target.contains(" "),
      let url = URL(string: target.contains("://") ? target : "https://\(target)"),
      url.scheme == "https" || url.scheme == "http", url.host != nil
    {
      emitTool(id, "openWebsite", "Opening \(url.host ?? target)")
      openURL(url)
      basicReply(id, "Opened \(url.host ?? target).")
      return true
    }
    if let app = findApplication(target) {
      let name = app.deletingPathExtension().lastPathComponent
      emitTool(id, "openApp", "Opening \(name)")
      NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
      basicReply(id, "Opened \(name).")
      return true
    }
  }
  if match(#"^(?:what(?:'s| is) the )?(?:time|date|day)(?: is it)?(?: today| now)?$"#) != nil
    || match(#"^what (?:time|day|date) is it(?: today| now)?$"#) != nil
  {
    let now = DateFormatter.localizedString(from: Date(), dateStyle: .full, timeStyle: .short)
    basicReply(id, "It's \(now).")
    return true
  }
  return false
}

private func basicAssistant(id: String, prompt: String, context: String) {
  if basicCommand(id: id, prompt: prompt, context: context) { return }
  basicReply(
    id,
    "I can open apps, sites and sessions, search the web, set timers and the volume, and run your Shortcuts here. Answering questions needs Apple Intelligence (macOS 26 on a supported Mac).")
}

/// `ai available` (the on-device model answers) or `ai basic <reason>` (the
/// command reader above does, and says why the model can't).
/// Set by `ai mode basic` (the user switched Apple Intelligence off in
/// Settings): commands still work, nothing goes to the model.
private var forceBasic = ProcessInfo.processInfo.environment["AGENT_ISLAND_FORCE_BASIC"] == "1"

private func aiCaps() -> String {
  if forceBasic { return "ai basic off" }
  #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
      let caps = modelCaps()
      return caps == "ai available" ? caps : caps.replacingOccurrences(of: "ai unavailable", with: "ai basic")
    }
    return "ai basic os"
  #else
    return "ai basic sdk"
  #endif
}

private func handleAI(_ argument: String) {
  let parts = argument.split(separator: " ", maxSplits: 2).map(String.init)
  guard let sub = parts.first else { return respond("err ai-missing-subcommand") }
  switch sub {
  case "caps":
    respond(aiCaps())
  case "mode":
    forceBasic = parts.count > 1 && parts[1] == "basic"
    respond(aiCaps())
  case "reset":
    #if canImport(FoundationModels)
      if #available(macOS 26.0, *) { assistant?.reset() }
    #endif
    respond("ok")
  case "cancel":
    #if canImport(FoundationModels)
      if #available(macOS 26.0, *), parts.count > 1 { assistant?.cancel(parts[1]) }
    #endif
  case "ask":
    guard parts.count == 3, let json = unb64(parts[2]),
      let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
      let prompt = object["prompt"] as? String
    else { return respond("ai error \(parts.count > 1 ? parts[1] : "-") bad-args") }
    let context = object["context"] as? String ?? ""
    #if canImport(FoundationModels)
      if !forceBasic, #available(macOS 26.0, *), modelCaps() == "ai available" {
        if assistant == nil { assistant = Assistant() }
        assistant?.ask(id: parts[1], prompt: prompt, context: context)
        return
      }
    #endif
    basicAssistant(id: parts[1], prompt: prompt, context: context)
  default:
    respond("err ai-unknown \(sub)")
  }
}

// MARK: - Voice

/// Voice mode: hear a question, then say the answer. All on-device.
///
/// Listening is AVAudioEngine → SpeechAnalyzer/SpeechTranscriber (macOS 26):
/// the new on-device transcriber, which needs only the microphone — unlike
/// SFSpeechRecognizer it asks for no speech-recognition grant, so there's no
/// second permission prompt and nothing to crash on in a bare helper. Partial
/// text streams back as the user speaks; a second and a half of quiet after
/// speech (or `voice stop`, or 30 seconds) ends the turn and sends the final.
///
/// Speaking uses Siri's voice (see Speaker).

/// Speaks like the user's Siri. It reads Siri's own voice setting and picks
/// the closest voice an app may use (see bestVoice) — no setting, no choosing.
/// The Mac's "system voice" setting isn't used: it's often unset (an empty
/// default), which spoke nothing at all.
private final class Speaker: NSObject, NSSpeechSynthesizerDelegate {
  private let synth: NSSpeechSynthesizer
  override init() {
    synth = Speaker.bestVoice().flatMap { NSSpeechSynthesizer(voice: $0) } ?? NSSpeechSynthesizer()
    super.init()
    synth.delegate = self
  }

  /// What Siri itself speaks with (Settings → Siri → Voice): a name like
  /// "riya", a language like "en-IN", and a gender (1 male, 2 female).
  static func siriVoicePreference() -> (name: String, language: String, gender: Int)? {
    guard
      let voice = CFPreferencesCopyAppValue("Output Voice" as CFString, "com.apple.assistant.backedup" as CFString)
        as? [String: Any]
    else { return nil }
    return (
      (voice["Name"] as? String ?? "").lowercased(),
      (voice["Language"] as? String ?? "").replacingOccurrences(of: "-", with: "_"),
      voice["Gender"] as? Int ?? 0
    )
  }

  /// Siri's own voices live in Siri's private assets, out of reach of apps —
  /// so this finds the installed voice that sounds most like the user's Siri:
  /// Siri's exact voice if it's ever installed for speech, else one of the
  /// same gender, language and region (Riya → Tara), else the best voice in
  /// the user's language.
  static func bestVoice() -> NSSpeechSynthesizer.VoiceName? {
    let siri = siriVoicePreference()
    let wanted = siri?.language.isEmpty == false ? siri!.language : Locale.current.identifier
    let wantedParts = wanted.split(separator: "_").map(String.init)
    let language = wantedParts.first ?? "en"
    let region = wantedParts.count > 1 ? wantedParts[1] : (Locale.current.regionCode ?? "")
    let wantedGender: NSSpeechSynthesizer.VoiceGender? =
      siri?.gender == 2 ? .female : siri?.gender == 1 ? .male : nil
    var best: (voice: NSSpeechSynthesizer.VoiceName, score: Int)?
    for voice in NSSpeechSynthesizer.availableVoices {
      let attrs = NSSpeechSynthesizer.attributes(forVoice: voice)
      let id = (attrs[.localeIdentifier] as? String ?? "").replacingOccurrences(of: "-", with: "_")
      let parts = id.split(separator: "_").map(String.init)
      guard parts.first == language else { continue }
      let raw = voice.rawValue.lowercased()
      let name = (attrs[.name] as? String ?? "").lowercased()
      let gender = (attrs[.gender] as? String).map { NSSpeechSynthesizer.VoiceGender(rawValue: $0) }
      // Novelty voices (Bells, Zarvox…) are never Siri.
      if raw.hasPrefix("com.apple.speech.synthesis.voice.") { continue }
      var score = 1
      if let siriName = siri?.name, !siriName.isEmpty, name.hasPrefix(siriName) || raw.contains(".\(siriName)") {
        score += 500  // Siri's own voice, if Apple ever exposes it
      }
      if let wantedGender, gender == wantedGender { score += 100 }
      if parts.count > 1, parts[1] == region { score += 40 }
      let demo = (attrs[.demoText] as? String ?? "").lowercased()
      if demo.contains("siri") { score += 15 }
      if raw.hasSuffix(".premium") { score += 10 } else if raw.hasSuffix(".enhanced") { score += 6 }
      if !raw.contains(".compact.") && !raw.contains(".super-compact.") { score += 3 }
      if best == nil || score > best!.score { best = (voice, score) }
    }
    return best?.voice
  }

  func say(_ text: String) {
    synth.stopSpeaking()
    synth.startSpeaking(text)
  }
  func stop() { synth.stopSpeaking() }
  func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
    respond("speak done")
  }
}

private let speaker = Speaker()

private func handleSpeak(_ argument: String) {
  if argument == "voice" {
    return respond("voice-name \(Speaker.bestVoice()?.rawValue ?? "default")")
  }
  if argument == "stop" {
    speaker.stop()
    return
  }
  guard let text = unb64(argument), !text.isEmpty else { return respond("err speak-bad-args") }
  speaker.say(text)
}

#if canImport(Speech)

// SpeechAnalyzer/SpeechTranscriber exist only in the macOS 26 SDK; Speech
// itself is in every SDK. FoundationModels is the compile-time marker for the
// 26 SDK, so an older toolchain (CI's) still builds everything else.
#if canImport(FoundationModels)
@available(macOS 26.0, *)
private final class Listener {
  let id: String
  private let engine = AVAudioEngine()
  private var analyzer: SpeechAnalyzer?
  private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
  private var finished = false
  private var heardSpeech = false
  private var lastLoud = Date()
  private let started = Date()
  private var watchdog: Timer?
  private var finalText = ""
  private var volatileText = ""

  /// Below this RMS is quiet; past `silenceAfter` of quiet after speech, stop.
  private let quietLevel: Float = 0.012
  private let silenceAfter: TimeInterval = 1.5
  private let maxDuration: TimeInterval = 30

  init(id: String) { self.id = id }

  func start() async {
    // The mic prompt is attributed to the responsible app (Agent Island).
    let granted = await AVCaptureDevice.requestAccess(for: .audio)
    guard granted else { return fail("mic-denied") }

    let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
    let transcriber = SpeechTranscriber(
      locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
    do {
      // First use downloads the on-device model; later it's instant.
      if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        respond("voice status \(id) downloading")
        try await install.downloadAndInstall()
      }
    } catch { return fail("model-unavailable") }

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    self.analyzer = analyzer
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
      return fail("no-format")
    }
    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    inputContinuation = continuation

    // Results: volatile text replaces itself; finals accumulate.
    Task { [weak self] in
      do {
        for try await result in transcriber.results {
          guard let self else { return }
          let text = String(result.text.characters)
          await MainActor.run {
            if result.isFinal {
              self.finalText += text
              self.volatileText = ""
            } else {
              self.volatileText = text
            }
            respond("voice partial \(self.id) \(b64(self.finalText + self.volatileText))")
          }
        }
      } catch {}
    }

    do {
      try await analyzer.start(inputSequence: stream)
    } catch { return fail("analyzer") }

    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.channelCount > 0, let converter = AVAudioConverter(from: inputFormat, to: format) else {
      return fail("no-microphone")
    }
    input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
      guard let self else { return }
      self.meter(buffer)
      let ratio = format.sampleRate / inputFormat.sampleRate
      let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
      guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
      var fed = false
      var error: NSError?
      converter.convert(to: out, error: &error) { _, status in
        if fed {
          status.pointee = .noDataNow
          return nil
        }
        fed = true
        status.pointee = .haveData
        return buffer
      }
      if error == nil, out.frameLength > 0 { self.inputContinuation?.yield(AnalyzerInput(buffer: out)) }
    }
    do {
      try engine.start()
    } catch { return fail("mic-start") }
    respond("voice listening \(id)")
    watchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
  }

  private func meter(_ buffer: AVAudioPCMBuffer) {
    guard let data = buffer.floatChannelData?[0] else { return }
    let n = Int(buffer.frameLength)
    if n == 0 { return }
    var sum: Float = 0
    for i in 0..<n { sum += data[i] * data[i] }
    let rms = (sum / Float(n)).squareRoot()
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if rms > self.quietLevel {
        self.heardSpeech = true
        self.lastLoud = Date()
      }
      // A 0–1 level for the orb; speech RMS rarely passes ~0.2.
      respond("voice level \(self.id) \(String(format: "%.2f", min(1, rms * 6)))")
    }
  }

  private func tick() {
    let now = Date()
    if now.timeIntervalSince(started) > maxDuration
      || (heardSpeech && now.timeIntervalSince(lastLoud) > silenceAfter)
    {
      stop()
    }
  }

  func stop() {
    guard !finished else { return }
    finished = true
    watchdog?.invalidate()
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    inputContinuation?.finish()
    Task { [weak self] in
      guard let self else { return }
      try? await self.analyzer?.finalizeAndFinishThroughEndOfInput()
      await MainActor.run {
        let text = (self.finalText + self.volatileText).trimmingCharacters(in: .whitespacesAndNewlines)
        respond("voice final \(self.id) \(b64(text))")
        if activeListener === self { activeListener = nil }
      }
    }
  }

  func fail(_ reason: String) {
    finished = true
    watchdog?.invalidate()
    if engine.isRunning {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
    inputContinuation?.finish()
    respond("voice error \(id) \(reason)")
    if activeListener === self { activeListener = nil }
  }
}


#endif

/// macOS 12–15: the older SFSpeechRecognizer, kept on-device where the Mac
/// supports it. Unlike SpeechAnalyzer it needs the Speech Recognition grant as
/// well as the microphone (a second prompt), and a usage description in the
/// responsible app — both are declared in the packaged app.
private final class LegacyListener {
  let id: String
  private let engine = AVAudioEngine()
  private let recognizer = SFSpeechRecognizer()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var finished = false
  private var heardSpeech = false
  private var lastLoud = Date()
  private let started = Date()
  private var watchdog: Timer?
  private var text = ""

  init(id: String) { self.id = id }

  func start() {
    SFSpeechRecognizer.requestAuthorization { status in
      DispatchQueue.main.async {
        guard status == .authorized else { return self.fail("speech-denied") }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
          DispatchQueue.main.async { granted ? self.begin() : self.fail("mic-denied") }
        }
      }
    }
  }

  private func begin() {
    guard let recognizer, recognizer.isAvailable else { return fail("model-unavailable") }
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
    self.request = request
    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      DispatchQueue.main.async {
        guard let self else { return }
        if let result {
          self.text = result.bestTranscription.formattedString
          respond("voice partial \(self.id) \(b64(self.text))")
          if result.isFinal { self.finish() }
        } else if error != nil, !self.finished {
          self.finish()
        }
      }
    }
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.channelCount > 0 else { return fail("no-microphone") }
    input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
      self?.request?.append(buffer)
      guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
      var sum: Float = 0
      for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
      let rms = (sum / Float(buffer.frameLength)).squareRoot()
      DispatchQueue.main.async {
        guard let self else { return }
        if rms > 0.012 {
          self.heardSpeech = true
          self.lastLoud = Date()
        }
        respond("voice level \(self.id) \(String(format: "%.2f", min(1, rms * 6)))")
      }
    }
    do { try engine.start() } catch { return fail("mic-start") }
    respond("voice listening \(id)")
    watchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      guard let self else { return }
      let now = Date()
      if now.timeIntervalSince(self.started) > 30 || (self.heardSpeech && now.timeIntervalSince(self.lastLoud) > 1.5) {
        self.stop()
      }
    }
  }

  func stop() {
    guard !finished else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    request?.endAudio()
    // The recognizer delivers a final result shortly after endAudio; if it
    // doesn't, finish with what we have.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.finish() }
  }

  private func finish() {
    guard !finished else { return }
    finished = true
    watchdog?.invalidate()
    if engine.isRunning {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
    task?.cancel()
    respond("voice final \(id) \(b64(text.trimmingCharacters(in: .whitespacesAndNewlines)))")
    if legacyListener === self { legacyListener = nil }
  }

  func fail(_ reason: String) {
    finished = true
    watchdog?.invalidate()
    if engine.isRunning {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
    task?.cancel()
    respond("voice error \(id) \(reason)")
    if legacyListener === self { legacyListener = nil }
  }
}

private var legacyListener: LegacyListener?

#if canImport(FoundationModels)
/// `AnyObject?` because a global can't carry `@available` in a script-mode file.
private var activeListenerBox: AnyObject?
@available(macOS 26.0, *)
private var activeListener: Listener? {
  get { activeListenerBox as? Listener }
  set { activeListenerBox = newValue }
}
#endif

#endif

private func handleVoice(_ argument: String) {
  let parts = argument.split(separator: " ").map(String.init)
  guard parts.count == 2 else { return respond("err voice-bad-args") }
  let (sub, id) = (parts[0], parts[1])
  #if canImport(Speech)
    switch sub {
    case "start":
      speaker.stop()
      #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
          activeListener?.fail("superseded")
          let listener = Listener(id: id)
          activeListener = listener
          Task { await listener.start() }
          return
        }
      #endif
      legacyListener?.fail("superseded")
      let listener = LegacyListener(id: id)
      legacyListener = listener
      listener.start()
    case "stop":
      #if canImport(FoundationModels)
        if #available(macOS 26.0, *), activeListener?.id == id { activeListener?.stop() }
      #endif
      if legacyListener?.id == id { legacyListener?.stop() }
    default:
      respond("err voice-unknown \(sub)")
    }
  #else
    respond("voice error \(id) sdk")
  #endif
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
  // Streams its reply out of band, like location.
  case "ai": handleAI(argument)
  case "voice": handleVoice(argument)
  case "speak": handleSpeak(argument)
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

import AppKit
import AVFoundation
import IslandCore

/// Sounds: the synthesized themes, rendered once per score and played on an
/// audio engine; the anime pack and your own imports as files. Best-effort:
/// no device, no sound, no error.
final class SoundPlayer {
  private let engine = AVAudioEngine()
  private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
  private var nodes: [AVAudioPlayerNode] = []
  private var rendered: [String: AVAudioPCMBuffer] = [:]
  private var files: [AVAudioPlayer] = []

  /// Plays `event` per the settings: an imported file, else the theme's sound.
  func play(_ event: SoundEvent, settings: IslandSettings) {
    guard settings.sounds else { return }
    if let path = settings.customSounds[event], FileManager.default.fileExists(atPath: path) {
      playFile(URL(filePath: path), volume: 0.6)
    } else {
      preview(event, theme: settings.theme(for: event))
    }
  }

  /// One theme's sound for one event (Settings ▶).
  func preview(_ event: SoundEvent, theme: SoundTheme) {
    if theme == .anime {
      let (name, volume) = SoundScore.file(event)
      if let url = Self.bundled(name) { playFile(url, volume: Float(volume)) }
      return
    }
    guard let buffer = buffer(theme, event) else { return }
    // A node per sound so overlapping events don't cut each other off. The
    // node must reach the output before the engine starts, or it throws.
    let node = nodes.first { !$0.isPlaying } ?? {
      let node = AVAudioPlayerNode()
      engine.attach(node)
      engine.connect(node, to: engine.mainMixerNode, format: format)
      nodes.append(node)
      return node
    }()
    do {
      if !engine.isRunning { try engine.start() }
    } catch {
      Log.app.error("audio engine: \(error.localizedDescription, privacy: .public)")
      return
    }
    node.scheduleBuffer(buffer)
    node.play()
  }

  func playFile(_ url: URL, volume: Float) {
    guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
    player.volume = volume
    player.play()
    files.removeAll { !$0.isPlaying }
    files.append(player)
  }

  private func buffer(_ theme: SoundTheme, _ event: SoundEvent) -> AVAudioPCMBuffer? {
    let key = "\(theme.rawValue).\(event.rawValue)"
    if let cached = rendered[key] { return cached }
    guard let score = SoundScore.score(theme, event) else { return nil }
    let samples = score.render(rate: format.sampleRate)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
      buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
    }
    rendered[key] = buffer
    return buffer
  }

  /// A bundled sound: in the app's Resources, or the repo when run unbundled.
  static func bundled(_ name: String) -> URL? {
    if let url = Bundle.main.url(forResource: name, withExtension: "mp3", subdirectory: "Sounds") { return url }
    let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appending(components: "Resources", "Sounds", "\(name).mp3")
    return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
  }
}

/// Trackpad haptics: a batch collapses to its most urgent rhythm, rhythms
/// keep a quarter second apart, and a Focus lets only your own taps through.
final class HapticPlayer {
  var enabled = true
  /// A Focus is on.
  var quiet = false
  private var batch: [Haptic] = []
  private var flushing = false
  private var lastFired = Date.distantPast

  func play(_ haptic: Haptic) {
    guard enabled, !quiet || haptic.isInteraction else { return }
    batch.append(haptic)
    guard !flushing else { return }
    flushing = true
    // Next turn of the run loop: a whole snapshot's transitions become one pulse.
    Task { @MainActor in
      flushing = false
      let winner = Haptic.winner(batch)
      batch.removeAll()
      guard let winner, Date.now.timeIntervalSince(lastFired) >= Haptic.minimumGap else { return }
      lastFired = .now
      await perform(winner)
    }
  }

  private func perform(_ haptic: Haptic) async {
    let performer = NSHapticFeedbackManager.defaultPerformer
    for (tap, gap) in haptic.rhythm {
      let pattern: NSHapticFeedbackManager.FeedbackPattern = switch tap {
      case .generic: .generic
      case .alignment: .alignment
      case .levelChange: .levelChange
      }
      performer.perform(pattern, performanceTime: .now)
      if gap > 0 { try? await Task.sleep(for: .milliseconds(gap)) }
    }
  }
}

/// What an update sounds and feels like, per 1.x: a done chime, a question
/// chime, a needs-you ping (sound quiet under a Focus); haptics for all four,
/// failure included.
@MainActor
func feedback(for transitions: [SessionTransition], settings: IslandSettings, focus: MacFocus, sounds: SoundPlayer, haptics: HapticPlayer) {
  let muted = settings.respectFocus && focus.active
  for transition in transitions {
    let kinds = transition.kinds
    if !muted {
      if kinds.contains(.done) { sounds.play(.success, settings: settings) }
      if kinds.contains(.question) {
        sounds.play(.question, settings: settings)
      } else if kinds.contains(.attention) {
        sounds.play(.attention, settings: settings)
      }
    }
    if kinds.contains(.done) { haptics.play(.success) }
    if kinds.contains(.failed) { haptics.play(.failure) }
    if kinds.contains(.question) { haptics.play(.inquiry) }
    if kinds.contains(.attention) { haptics.play(.attention) }
  }
}

/// `ps -axo pid,ppid,%cpu,rss`, off the main actor.
nonisolated enum PS {
  @concurrent
  static func read() async -> String {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/ps")
    process.arguments = ["-axo", "pid,ppid,%cpu,rss"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
  }
}

/// The menu-bar icon's menu: toggle the island, sounds, login, quit. Rebuilt
/// each time it opens, so the checkmarks are always current.
final class TrayMenu: NSObject, NSMenuDelegate {
  let menu = NSMenu(title: "Agent Island")
  private let model: IslandModel
  private var actions: [() -> Void] = []

  init(model: IslandModel) {
    self.model = model
    super.init()
    menu.delegate = self
    rebuild()
  }

  func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

  private func rebuild() {
    menu.removeAllItems()
    actions.removeAll()
    let title = NSMenuItem(title: "Agent Island", action: nil, keyEquivalent: "")
    title.isEnabled = false
    menu.addItem(title)
    menu.addItem(.separator())
    add("Toggle Island") { [weak self] in self?.model.pinned.toggle() }
    add("Sound Effects", on: model.settings.sounds) { [weak self] in self?.model.changeSettings { $0.sounds.toggle() } }
    if LoginItem.isAvailable {
      add("Open at Login", on: LoginItem.isEnabled) { LoginItem.isEnabled.toggle() }
    }
    menu.addItem(.separator())
    add("Quit Agent Island") { NSApp.terminate(nil) }
  }

  private func add(_ title: String, on: Bool? = nil, _ action: @escaping () -> Void) {
    let item = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: "")
    item.target = self
    item.tag = actions.count
    if let on { item.state = on ? .on : .off }
    actions.append(action)
    menu.addItem(item)
  }

  @objc private func fire(_ sender: NSMenuItem) {
    if actions.indices.contains(sender.tag) { actions[sender.tag]() }
  }
}

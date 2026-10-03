import AppKit
import Foundation
import Observation

/// What's playing, for the wings and the media card.
///
/// Music and Spotify announce every change over distributed notifications, so
/// nothing polls; their artwork and controls go over AppleScript (asked once,
/// Automation). Anything else (a browser, Podcasts) is tried through the
/// system's MediaRemote where macOS still allows it, with the keyboard's
/// media keys as the last resort.
@Observable
final class NowPlayingService {
  struct Track: Equatable {
    enum Source: Equatable {
      case music, spotify, system(bundle: String?)

      var bundleId: String? {
        switch self {
        case .music: "com.apple.Music"
        case .spotify: "com.spotify.client"
        case let .system(bundle): bundle
        }
      }
    }

    var title: String
    var artist: String
    var album: String
    var source: Source
    var playing: Bool
    /// Seconds; nil when unknown.
    var duration: TimeInterval?
    /// Where it was at `positionAt`.
    var position: TimeInterval?
    var positionAt = Date.now

    /// Where it is now, extrapolated while playing.
    func elapsed(at now: Date) -> TimeInterval? {
      guard let position else { return nil }
      let moved = playing ? now.timeIntervalSince(positionAt) : 0
      return min(duration ?? .infinity, position + moved)
    }
  }

  private(set) var track: Track?
  private(set) var artwork: NSImage?
  /// Tinted from the artwork, for the wings' equaliser.
  private(set) var accent: NSColor?

  var isPlaying: Bool { track?.playing == true }

  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var artworkKey = ""
  @ObservationIgnored private var queried = false
  @ObservationIgnored private let remote = MediaRemote()

  func start() {
    guard observers.isEmpty else { return }
    let center = DistributedNotificationCenter.default()
    observers.append(center.addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] note in
      let info = note.userInfo.map(Self.strings) ?? [:]
      MainActor.assumeIsolated { self?.received(info, source: .music) }
    })
    observers.append(center.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] note in
      let info = note.userInfo.map(Self.strings) ?? [:]
      MainActor.assumeIsolated { self?.received(info, source: .spotify) }
    })
    remote.onChange = { [weak self] in self?.readSystem() }
    remote.start()
    readSystem()
  }

  func stop() {
    for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) }
    observers.removeAll()
    remote.stop()
    track = nil
    artwork = nil
  }

  /// Music or Spotify already playing before launch says nothing until the
  /// next change; the first time the island opens, ask them once.
  func catchUp() {
    guard !queried, track == nil, !observers.isEmpty else { return }
    queried = true
    for source in [Track.Source.music, .spotify] where Self.isRunning(source.bundleId) {
      let app = source == .music ? "Music" : "Spotify"
      let durationScale = source == .music ? "1" : "1000"
      Task {
        let out = await Osascript.run("""
          tell application "\(app)"
          if player state is stopped then return ""
          set t to current track
          return (player state as string) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & ((duration of t) / \(durationScale) as string) & linefeed & (player position as string)
          end tell
          """)
        guard let out, !out.isEmpty else { return }
        let lines = out.components(separatedBy: "\n")
        guard lines.count >= 6, self.track == nil else { return }
        self.apply(Track(
          title: lines[1], artist: lines[2], album: lines[3], source: source, playing: lines[0] == "playing",
          duration: Double(lines[4].replacingOccurrences(of: ",", with: ".")),
          position: Double(lines[5].replacingOccurrences(of: ",", with: "."))
        ))
      }
    }
  }

  // MARK: Controls

  func playPause() { send(.playPause) }
  func next() { send(.next) }
  func previous() { send(.previous) }

  private enum Command { case playPause, next, previous }

  private func send(_ command: Command) {
    switch track?.source {
    case .music?, .spotify?:
      let app = track?.source == .music ? "Music" : "Spotify"
      let verb = switch command {
      case .playPause: "playpause"
      case .next: "next track"
      case .previous: "previous track"
      }
      Osascript.send("tell application \"\(app)\" to \(verb)")
      // The app's notification confirms; flip now so the button answers at once.
      if command == .playPause, var current = track {
        current.position = current.elapsed(at: .now)
        current.positionAt = .now
        current.playing.toggle()
        track = current
      }
    default:
      let sent = switch command {
      case .playPause: remote.send(.togglePlayPause)
      case .next: remote.send(.nextTrack)
      case .previous: remote.send(.previousTrack)
      }
      if !sent {
        KeyPoster.media(command == .playPause ? .play : command == .next ? .next : .previous)
      }
      Task {
        try? await Task.sleep(for: .milliseconds(400))
        readSystem()
      }
    }
  }

  /// Opens the playing app.
  func openSource() {
    guard let id = track?.source.bundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
  }

  // MARK: Updates

  private nonisolated static func strings(_ info: [AnyHashable: Any]) -> [String: String] {
    var out: [String: String] = [:]
    for (key, value) in info {
      guard let key = key as? String else { continue }
      if let string = value as? String { out[key] = string } else if let number = value as? NSNumber { out[key] = number.stringValue }
    }
    return out
  }

  private func received(_ info: [String: String], source: Track.Source) {
    let state = info["Player State"] ?? ""
    if state == "Stopped" || info["Name"] == nil {
      if track?.source == source { clear() }
      return
    }
    let duration: TimeInterval? = switch source {
    case .music: info["Total Time"].flatMap(Double.init).map { $0 / 1000 }
    default: info["Duration"].flatMap(Double.init).map { $0 / 1000 }
    }
    let position = source == .spotify ? info["Playback Position"].flatMap(Double.init) : nil
    var next = Track(
      title: info["Name"] ?? "", artist: info["Artist"] ?? "", album: info["Album"] ?? "", source: source,
      playing: state == "Playing", duration: duration, position: position
    )
    // Music doesn't send the position: carry it over for the same song.
    if source == .music, let current = track, current.title == next.title, current.artist == next.artist {
      next.position = current.elapsed(at: .now)
    } else if source == .music {
      next.position = 0
    }
    apply(next)
    if source == .music { fetchMusicPosition() }
  }

  private func apply(_ next: Track) {
    // Another player pausing never hides the one that's playing.
    if let current = track, current.playing, current.source != next.source, !next.playing { return }
    track = next
    let key = "\(next.source)|\(next.title)|\(next.album)"
    guard key != artworkKey else { return }
    artworkKey = key
    artwork = nil
    accent = nil
    fetchArtwork(for: next, key: key)
  }

  private func clear() {
    track = nil
    artwork = nil
    accent = nil
    artworkKey = ""
  }

  private func fetchMusicPosition() {
    Task {
      guard let out = await Osascript.run("tell application \"Music\" to player position as string"),
        let seconds = Double(out.replacingOccurrences(of: ",", with: ".")), var current = track, current.source == .music
      else { return }
      current.position = seconds
      current.positionAt = .now
      track = current
    }
  }

  private func fetchArtwork(for track: Track, key: String) {
    switch track.source {
    case .music:
      // Music writes the artwork's bytes to a temporary file, out of process,
      // so a first-time Automation prompt never holds up the island.
      Task {
        try? await Task.sleep(for: .milliseconds(150))
        guard artworkKey == key else { return }
        let file = FileManager.default.temporaryDirectory.appending(path: "island-artwork-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let wrote = await Osascript.run("""
          tell application "Music"
          if (count of artworks of current track) is 0 then return "none"
          set d to raw data of artwork 1 of current track
          end tell
          set f to open for access (POSIX file "\(file.path)") with write permission
          write d to f
          close access f
          return "ok"
          """)
        guard wrote == "ok", let data = try? Data(contentsOf: file), let image = NSImage(data: data) else { return }
        setArtwork(image, key: key)
      }
    case .spotify:
      Task {
        guard let out = await Osascript.run("tell application \"Spotify\" to artwork url of current track"),
          let url = URL(string: out), url.scheme == "https",
          let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data)
        else { return }
        setArtwork(image, key: key)
      }
    case .system:
      break
    }
  }

  private func setArtwork(_ image: NSImage, key: String) {
    guard artworkKey == key else { return }
    artwork = image
    accent = image.averageColor
  }

  private func readSystem() {
    remote.read { [weak self] info in
      guard let self else { return }
      // Music and Spotify speak for themselves; MediaRemote covers the rest.
      if let source = track?.source, source == .music || source == .spotify, track?.playing == true { return }
      guard let info, !info.title.isEmpty else {
        if case .system? = track?.source { clear() }
        return
      }
      apply(Track(
        title: info.title, artist: info.artist, album: info.album, source: .system(bundle: info.bundle), playing: info.playing,
        duration: info.duration, position: info.elapsed
      ))
      if let data = info.artwork, let image = NSImage(data: data) {
        artwork = image
        accent = image.averageColor
      }
    }
  }

  private static func isRunning(_ bundleId: String?) -> Bool {
    guard let bundleId else { return false }
    return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
  }
}

/// The private MediaRemote framework, looked up at run time. Since macOS 15.4
/// it answers only Apple's own apps, so every call here may come back empty;
/// that's fine, the island just knows less.
final class MediaRemote {
  struct Info {
    var title = ""
    var artist = ""
    var album = ""
    var duration: TimeInterval?
    var elapsed: TimeInterval?
    var playing = false
    var artwork: Data?
    var bundle: String?
  }

  enum Command: UInt32 {
    case play = 0, pause = 1, togglePlayPause = 2, nextTrack = 4, previousTrack = 5
  }

  var onChange: () -> Void = {}

  private typealias GetInfo = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
  private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool
  private typealias Register = @convention(c) (DispatchQueue) -> Void

  private let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY)
  private var observer: NSObjectProtocol?

  private func symbol<T>(_ name: String, as type: T.Type) -> T? {
    guard let handle, let pointer = dlsym(handle, name) else { return nil }
    return unsafeBitCast(pointer, to: type)
  }

  func start() {
    guard observer == nil, let register = symbol("MRMediaRemoteRegisterForNowPlayingNotifications", as: Register.self) else { return }
    register(.main)
    observer = NotificationCenter.default.addObserver(
      forName: .init("kMRMediaRemoteNowPlayingInfoDidChangeNotification"), object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.onChange() }
    }
  }

  func stop() {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
  }

  func read(_ done: @escaping (Info?) -> Void) {
    guard let get = symbol("MRMediaRemoteGetNowPlayingInfo", as: GetInfo.self) else { return done(nil) }
    get(.main) { dictionary in
      let raw = (dictionary as? [String: Any]) ?? [:]
      var info = Info()
      info.title = raw["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
      info.artist = raw["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
      info.album = raw["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
      info.duration = raw["kMRMediaRemoteNowPlayingInfoDuration"] as? Double
      info.elapsed = raw["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double
      info.playing = (raw["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0) > 0
      info.artwork = raw["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
      let result = raw.isEmpty ? nil : info
      MainActor.assumeIsolated { done(result) }
    }
  }

  func send(_ command: Command) -> Bool {
    guard let send = symbol("MRMediaRemoteSendCommand", as: SendCommand.self) else { return false }
    return send(command.rawValue, nil)
  }
}

extension NSImage {
  /// The image's mean colour, lifted so it reads on black.
  var averageColor: NSColor? {
    guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    var pixel = [UInt8](repeating: 0, count: 4)
    guard let context = CGContext(
      data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .medium
    context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let color = NSColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
    guard let hsb = color.usingColorSpace(.deviceRGB) else { return color }
    return NSColor(hue: hsb.hueComponent, saturation: min(1, hsb.saturationComponent * 1.2 + 0.1), brightness: max(0.75, hsb.brightnessComponent), alpha: 1)
  }
}

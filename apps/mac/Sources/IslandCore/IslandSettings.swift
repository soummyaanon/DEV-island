import Foundation

/// Every preference, in 1.x's `settings.json` (same file, same keys, same
/// defaults and migrations), so 1.x → 2.0 keeps them, and so both can share
/// the file while they run side by side.
public struct IslandSettings: Equatable, Sendable {
  /// Bumped when a stored field's meaning changes (see `init(json:)`).
  public static let version = 3

  /// How the collapsed island opens.
  public enum OpenWith: String, Sendable, CaseIterable {
    /// A two-finger swipe down or a click; grazing the top of the screen doesn't.
    case swipe
    /// The classic: resting the pointer on the island.
    case hover
  }

  /// How sessions show in the open island.
  public enum SessionView: String, Sendable, CaseIterable {
    /// Robot bubbles with the project name.
    case compact
    /// Full rows with activity, model and meter.
    case detailed
  }

  public enum TextSize: String, Sendable, CaseIterable {
    case standard = "default", large, larger

    /// The type scale it applies.
    public var scale: Double {
      switch self {
      case .standard: 1
      case .large: 1.15
      case .larger: 1.3
      }
    }
  }

  public enum TemperatureUnit: String, Sendable, CaseIterable {
    case auto, c, f
  }

  public var agents: Set<AgentKind> = Set(AgentKind.allCases)
  public var sounds = true
  public var soundTheme: SoundTheme = .eightBit
  /// Per-event theme; absent follows `soundTheme`.
  public var soundOverrides: [SoundEvent: SoundTheme] = [:]
  /// Per-event imported audio files (absolute paths); a file wins over any theme.
  public var customSounds: [SoundEvent: String] = [:]
  /// The imports' original names, for Settings.
  public var customSoundNames: [SoundEvent: String] = [:]
  /// Menu-bar icon (off by default: the island is the app).
  public var tray = false
  /// Anonymous GitHub Releases version check.
  public var updateCheck = true
  public var haptics = true
  public var textSize: TextSize = .standard
  /// Local weather: off by default, since it's a network request.
  public var weather = false
  /// "lat, lon"; empty falls back to the timezone's city.
  public var weatherLocation = ""
  public var weatherUnits: TemperatureUnit = .auto
  public var openWith: OpenWith = .swipe
  public var sessionView: SessionView = .compact
  /// A translucent glass panel instead of the solid black body.
  public var glass = false
  public var battery = true
  /// Per-session CPU and memory, sampled only while the panel is open.
  public var procStats = true
  /// Mute sounds and notification haptics while a Focus is on.
  public var respectFocus = true
  /// The Ask bar at all.
  public var assistant = true
  /// Apple Intelligence's on-device model; off means commands only.
  public var assistantModel = true
  /// The mic in the Ask bar.
  public var voice = true
  public var speakReplies = true
  /// The glow while the assistant is open.
  public var edgeGlow = true
  /// Say hello at launch and after time away.
  public var greeting = true

  // Quick access: each module can be switched off in Settings. Written to the
  // file only when changed from its default, so 1.x's file stays byte-identical.

  /// Claude Code and Codex activity, read from their local logs.
  public var agentStats = true
  /// Time, volume, brightness, Wi-Fi, Bluetooth, AirDrop, Focus, battery, displays.
  public var quickControls = true
  /// Drop files on the notch to park them; drag them back out or AirDrop them.
  public var shelf = true
  /// Recent copied text and images, in memory only; secrets are skipped.
  public var clipboardHistory = true
  /// Artwork, track and controls for whatever is playing.
  public var nowPlaying = true
  /// Zoom and Google Meet: a call timer, mute, camera and leave.
  public var meetings = true
  /// Back, forward and reload for the browser in front.
  public var browserControls = true
  /// Calendar events, reminders and the island's own to-dos.
  public var agenda = true
  /// Countdowns and Pomodoro.
  public var timers = true
  /// Weather, stocks and the unit converter.
  public var widgets = true
  /// Stock quotes: a network request, so off until asked for.
  public var stocks = false
  public var stockSymbols = "AAPL, MSFT, ^GSPC"
  public var teleprompter = true
  /// The time in the wings while the menu bar is hidden.
  public var menuBarClock = true
  /// A Shortcut the Focus control runs; blank opens Focus settings.
  public var focusShortcut = ""

  /// Keys this build doesn't know, kept so saving never drops them.
  var unknown: [String: JSONValue] = [:]

  public init() {}

  public init(openWith: OpenWith = .swipe, battery: Bool = true, sessionView: SessionView = .compact) {
    self.openWith = openWith
    self.battery = battery
    self.sessionView = sessionView
  }

  /// 1.x's own folder (Electron's userData for "@agent-island/app"), where it
  /// keeps settings, the onboarded flag, the weather cache and imported
  /// sounds. 2.0 shares it, so an upgrade keeps everything.
  public static var userData: URL {
    URL.applicationSupportDirectory.appending(components: "@agent-island", "app")
  }

  /// `~/Library/Application Support/@agent-island/app/settings.json`.
  public static var defaultURL: URL {
    userData.appending(path: "settings.json")
  }

  static let known: Set<String> = [
    "settingsVersion", "agents", "sounds", "soundTheme", "soundOverrides", "customSounds", "customSoundNames",
    "tray", "updateCheck", "haptics", "textSize", "weather", "weatherLocation", "weatherUnits", "openWith",
    "sessionView", "glass", "battery", "procStats", "respectFocus", "assistant", "assistantModel", "voice",
    "speakReplies", "edgeGlow", "greeting",
    "agentStats", "quickControls", "shelf", "clipboardHistory", "nowPlaying", "meetings", "browserControls", "agenda", "timers",
    "widgets", "stocks", "stockSymbols", "teleprompter", "menuBarClock", "focusShortcut",
  ]

  /// Merges a stored file over the defaults with 1.x's rules: bad values fall
  /// back, and two migrations. v1 → v2: a v1 file's `openWith` was only ever
  /// the old default, so it resets. v2 → v3: `glass` used to default on, so a
  /// v2 file's value resets to off. A missing or corrupt file is the defaults.
  public init(json data: Data?) {
    self.init()
    guard let data, let stored = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return }
    unknown = stored.filter { !Self.known.contains($0.key) }
    let version = stored["settingsVersion"]?.number.map(Int.init) ?? 1

    func bool(_ key: String, _ value: inout Bool) {
      if case let .bool(stored)? = stored[key] { value = stored }
    }
    func pick<E: RawRepresentable<String>>(_ key: String, _ value: inout E) {
      if let raw = stored[key]?.string, let parsed = E(rawValue: raw) { value = parsed }
    }
    func map<V>(_ key: String, _ parse: (JSONValue) -> V?) -> [SoundEvent: V] {
      guard case let .object(entries)? = stored[key] else { return [:] }
      return entries.reduce(into: [:]) { out, entry in
        if let event = SoundEvent(rawValue: entry.key), let value = parse(entry.value) { out[event] = value }
      }
    }

    if case let .object(entries)? = stored["agents"] {
      for kind in AgentKind.allCases where entries[kind.rawValue] == .bool(false) {
        agents.remove(kind)
      }
    }
    bool("sounds", &sounds)
    pick("soundTheme", &soundTheme)
    soundOverrides = map("soundOverrides") { $0.string.flatMap(SoundTheme.init(rawValue:)) }
    customSounds = map("customSounds") { $0.string }
    customSoundNames = map("customSoundNames") { $0.string }
    bool("tray", &tray)
    bool("updateCheck", &updateCheck)
    bool("haptics", &haptics)
    pick("textSize", &textSize)
    bool("weather", &weather)
    if let location = stored["weatherLocation"]?.string { weatherLocation = location }
    pick("weatherUnits", &weatherUnits)
    if version >= 2 { pick("openWith", &openWith) }
    pick("sessionView", &sessionView)
    if version >= 3 { bool("glass", &glass) }
    bool("battery", &battery)
    bool("procStats", &procStats)
    bool("respectFocus", &respectFocus)
    bool("assistant", &assistant)
    bool("assistantModel", &assistantModel)
    bool("voice", &voice)
    bool("speakReplies", &speakReplies)
    bool("edgeGlow", &edgeGlow)
    bool("greeting", &greeting)
    bool("agentStats", &agentStats)
    bool("quickControls", &quickControls)
    bool("shelf", &shelf)
    bool("clipboardHistory", &clipboardHistory)
    bool("nowPlaying", &nowPlaying)
    bool("meetings", &meetings)
    bool("browserControls", &browserControls)
    bool("agenda", &agenda)
    bool("timers", &timers)
    bool("widgets", &widgets)
    bool("stocks", &stocks)
    if let symbols = stored["stockSymbols"]?.string { stockSymbols = symbols }
    bool("teleprompter", &teleprompter)
    bool("menuBarClock", &menuBarClock)
    if let shortcut = stored["focusShortcut"]?.string { focusShortcut = shortcut }
  }

  /// The quick-access keys that differ from their defaults, in a fixed order.
  private var quickAccessEntries: [(key: String, value: OrderedJSON)] {
    let defaults = IslandSettings()
    var out: [(key: String, value: OrderedJSON)] = []
    func bool(_ key: String, _ path: KeyPath<IslandSettings, Bool>) {
      if self[keyPath: path] != defaults[keyPath: path] { out.append((key, .bool(self[keyPath: path]))) }
    }
    func string(_ key: String, _ path: KeyPath<IslandSettings, String>) {
      if self[keyPath: path] != defaults[keyPath: path] { out.append((key, .string(self[keyPath: path]))) }
    }
    bool("agentStats", \.agentStats)
    bool("quickControls", \.quickControls)
    bool("shelf", \.shelf)
    bool("clipboardHistory", \.clipboardHistory)
    bool("nowPlaying", \.nowPlaying)
    bool("meetings", \.meetings)
    bool("browserControls", \.browserControls)
    bool("agenda", \.agenda)
    bool("timers", \.timers)
    bool("widgets", \.widgets)
    bool("stocks", \.stocks)
    string("stockSymbols", \.stockSymbols)
    bool("teleprompter", \.teleprompter)
    bool("menuBarClock", \.menuBarClock)
    string("focusShortcut", \.focusShortcut)
    return out
  }

  /// The file's contents, exactly as 1.x writes it: its key order
  /// (`{...DEFAULT_SETTINGS, ...stored}`), then any keys it doesn't know, in
  /// `JSON.stringify(settings, null, 2)` form.
  public func json() -> Data {
    func events(_ map: [SoundEvent: String]) -> OrderedJSON {
      .object(SoundEvent.allCases.compactMap { event in map[event].map { (event.rawValue, OrderedJSON.string($0)) } })
    }
    var entries: [(key: String, value: OrderedJSON)] = [
      ("settingsVersion", .number(String(Self.version))),
      ("agents", .object(AgentKind.allCases.map { ($0.rawValue, .bool(agents.contains($0))) })),
      ("sounds", .bool(sounds)),
      ("soundTheme", .string(soundTheme.rawValue)),
      ("soundOverrides", events(soundOverrides.mapValues(\.rawValue))),
      ("customSounds", events(customSounds)),
      ("customSoundNames", events(customSoundNames)),
      ("tray", .bool(tray)),
      ("updateCheck", .bool(updateCheck)),
      ("haptics", .bool(haptics)),
      ("textSize", .string(textSize.rawValue)),
      ("weather", .bool(weather)),
      ("weatherLocation", .string(weatherLocation)),
      ("weatherUnits", .string(weatherUnits.rawValue)),
      ("openWith", .string(openWith.rawValue)),
      ("sessionView", .string(sessionView.rawValue)),
      ("glass", .bool(glass)),
      ("battery", .bool(battery)),
      ("procStats", .bool(procStats)),
      ("respectFocus", .bool(respectFocus)),
      ("assistant", .bool(assistant)),
      ("assistantModel", .bool(assistantModel)),
      ("voice", .bool(voice)),
      ("speakReplies", .bool(speakReplies)),
      ("edgeGlow", .bool(edgeGlow)),
      ("greeting", .bool(greeting)),
    ]
    entries += quickAccessEntries
    for (key, value) in unknown.sorted(by: { $0.key < $1.key }) {
      entries.append((key, OrderedJSON(value)))
    }
    return Data((OrderedJSON.object(entries).serialized() + "\n").utf8)
  }

  public static func load(from url: URL = defaultURL) -> IslandSettings {
    IslandSettings(json: try? Data(contentsOf: url))
  }

  /// Writes the whole file atomically.
  public func save(to url: URL = defaultURL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try json().write(to: url, options: .atomic)
  }
}

extension OrderedJSON {
  init(_ value: JSONValue) {
    switch value {
    case let .string(text): self = .string(text)
    case let .number(number): self = .number(number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number))
    case let .bool(flag): self = .bool(flag)
    case let .object(entries): self = .object(entries.sorted { $0.key < $1.key }.map { ($0.key, OrderedJSON($0.value)) })
    case let .array(items): self = .array(items.map(OrderedJSON.init))
    case .null: self = .null
    }
  }
}

extension JSONValue {
  public var number: Double? {
    if case let .number(value) = self { value } else { nil }
  }
}

// MARK: - Sounds

public enum SoundTheme: String, Sendable, CaseIterable {
  case eightBit = "8bit", arcade, soft, glass, marimba, zen, anime

  public var label: String {
    switch self {
    case .eightBit: "8-bit"
    case .arcade: "Arcade"
    case .soft: "Soft"
    case .glass: "Glass"
    case .marimba: "Marimba"
    case .zen: "Zen"
    case .anime: "Anime"
    }
  }

  public var blurb: String {
    switch self {
    case .eightBit: "Chiptune blips and arpeggios."
    case .arcade: "Coins, klaxons and power-ups."
    case .soft: "Gentle sine chimes."
    case .glass: "Bright crystal pings with a shimmer."
    case .marimba: "Warm wooden taps."
    case .zen: "Low singing bowls that ring out."
    case .anime: "The bundled voice pack."
    }
  }
}

public enum SoundEvent: String, Sendable, CaseIterable {
  case success, attention, question, approve

  public var label: String {
    switch self {
    case .success: "Done"
    case .attention: "Needs you"
    case .question: "Question"
    case .approve: "You allow"
    }
  }
}

extension IslandSettings {
  /// The theme `event` plays: its override, else the base theme.
  public func theme(for event: SoundEvent) -> SoundTheme {
    soundOverrides[event] ?? soundTheme
  }
}

import Foundation

// MARK: - Haptics

/// Trackpad haptics, one rhythm per event class (1.x's haptics.ts). macOS
/// offers three taps and no intensity control, so a pattern's feel comes only
/// from how many taps and how far apart.
public enum Haptic: String, Sendable, CaseIterable {
  /// A session finished.
  case success
  /// Something needs you.
  case attention
  /// An agent asked a question.
  case inquiry
  /// A session failed.
  case failure
  /// You approved or denied: a decision landed.
  case commit
  /// The lightest: a row click, a control press.
  case tick
  /// Ambient, never alerting (weather refresh).
  case whisper
  /// Ambient but heavy (thunder arriving).
  case rumble

  public enum Tap: String, Sendable { case generic, alignment, levelChange }

  /// Taps and the gaps (ms) between them. `failure`'s tight double reads as
  /// "wrong"; only `rumble`'s slow spacing sets it apart from `attention`.
  public var rhythm: [(tap: Tap, gapAfter: Int)] {
    switch self {
    case .success: [(.levelChange, 55), (.levelChange, 0)]
    case .attention: [(.generic, 90), (.generic, 90), (.generic, 0)]
    case .inquiry: [(.alignment, 70), (.levelChange, 0)]
    case .failure: [(.generic, 40), (.generic, 0)]
    case .commit: [(.levelChange, 0)]
    case .tick, .whisper: [(.alignment, 0)]
    case .rumble: [(.generic, 140), (.generic, 140), (.generic, 0)]
    }
  }

  /// Higher wins when several land together.
  public var priority: Int {
    switch self {
    case .failure: 70
    case .attention: 60
    case .inquiry: 50
    case .rumble: 45
    case .success: 40
    case .commit: 30
    case .tick: 20
    case .whisper: 10
    }
  }

  /// Taps you caused yourself; the only ones that get through a Focus.
  public var isInteraction: Bool { self == .tick || self == .commit }

  /// Two rhythms never land closer than this: ten sessions finishing at once
  /// must be one pulse, not a machine-gunned trackpad.
  public static let minimumGap: TimeInterval = 0.25

  /// The winner of a batch.
  public static func winner(_ batch: some Sequence<Haptic>) -> Haptic? {
    batch.max { $0.priority < $1.priority }
  }
}

// MARK: - Deep links

/// `agent-island://` links. Focus can't be read (no public API), but a
/// Shortcuts automation can open a URL when a Focus turns on or off.
public enum DeepLink: Equatable, Sendable {
  case focus(active: Bool, name: String?)
  case toggle
  case settings
  /// agent-island://tools/clipboard: open the island on a tool (or the tools page).
  case tools(String?)
  /// agent-island://timer?minutes=5&label=Tea
  case timer(minutes: Double, label: String)
  /// agent-island://pomodoro
  case pomodoro

  public static let scheme = "agent-island"

  /// The two links a Focus automation needs, for Settings to show and copy.
  public static let focusOn = "agent-island://focus/on?name=Work"
  public static let focusOff = "agent-island://focus/off"

  public init?(_ url: URL) {
    guard url.scheme?.lowercased() == Self.scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    let host = (components.host ?? "").lowercased()
    var path = components.path.lowercased()
    while path.hasSuffix("/") { path.removeLast() }
    switch (host, path) {
    case ("focus", "/on"), ("focus", "/off"):
      let raw = components.queryItems?.first { $0.name == "name" }?.value?.trimmingCharacters(in: .whitespaces) ?? ""
      self = .focus(active: path == "/on", name: raw.isEmpty ? nil : String(raw.prefix(40)))
    case ("toggle", ""):
      self = .toggle
    case ("settings", ""):
      self = .settings
    case ("tools", _):
      let tab = path.split(separator: "/").first.map(String.init)
      self = .tools(tab)
    case ("timer", ""):
      let query = components.queryItems ?? []
      let minutes = query.first { $0.name == "minutes" }?.value.flatMap(Double.init) ?? 5
      guard minutes > 0, minutes <= 24 * 60 else { return nil }
      let label = query.first { $0.name == "label" }?.value ?? ""
      self = .timer(minutes: minutes, label: String(label.prefix(40)))
    case ("pomodoro", ""):
      self = .pomodoro
    default:
      return nil
    }
  }
}

/// Focus as a Shortcuts automation last told us. Not persisted: a fresh
/// launch starts unfocused and the automation fires again next time.
public struct MacFocus: Equatable, Sendable {
  public var active: Bool
  public var name: String?

  public init(active: Bool = false, name: String? = nil) {
    self.active = active
    self.name = active ? name : nil
  }
}

// MARK: - Resource meter

/// What an agent costs right now: CPU and memory over its whole process tree
/// (1.x's proc-stats.ts), from one `ps -axo pid,ppid,%cpu,rss`.
public struct ProcTotals: Equatable, Sendable {
  /// Percent of one core, summed: 250 is two and a half cores.
  public var cpu: Int
  public var rssMB: Int
  public var processes: Int

  public init(cpu: Int, rssMB: Int, processes: Int) {
    self.cpu = cpu
    self.rssMB = rssMB
    self.processes = processes
  }

  /// Sampled every two seconds, and only while the panel is open.
  public static let interval: Duration = .seconds(2)

  public struct Row: Equatable, Sendable {
    public var pid: Int
    public var ppid: Int
    public var cpu: Double
    public var rssKB: Double
  }

  /// Parses `ps -axo pid,ppid,%cpu,rss`; the header and bad lines are skipped.
  public static func parse(_ output: String) -> [Row] {
    output.split(separator: "\n").compactMap { line in
      let parts = line.split(whereSeparator: \.isWhitespace)
      guard parts.count >= 4, let pid = Int(parts[0]), let ppid = Int(parts[1]),
        let cpu = Double(parts[2]), let rss = Double(parts[3])
      else { return nil }
      return Row(pid: pid, ppid: ppid, cpu: cpu, rssKB: rss)
    }
  }

  /// A root's whole descendant tree. Nil when the root is gone, so a reused
  /// PID never pins a stranger's load on a session.
  public static func subtree(_ rows: [Row], root: Int) -> ProcTotals? {
    let byPid = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    let children = Dictionary(grouping: rows, by: \.ppid)
    guard byPid[root] != nil else { return nil }
    var seen: Set<Int> = []
    var stack = [root]
    var cpu = 0.0
    var rss = 0.0
    while let pid = stack.popLast() {
      guard seen.insert(pid).inserted, let row = byPid[pid] else { continue }
      cpu += row.cpu
      rss += row.rssKB
      stack.append(contentsOf: children[pid, default: []].map(\.pid))
    }
    return ProcTotals(cpu: Int(cpu.rounded()), rssMB: Int((rss / 1024).rounded()), processes: seen.count)
  }

  /// Past a core and a half it's worth a glance; past three, probably a runaway.
  public enum Heat: Sendable { case cool, hot, burning }

  public var heat: Heat { cpu >= 300 ? .burning : cpu >= 150 ? .hot : .cool }
}

// MARK: - Tray

public enum TrayTitle {
  /// " 🏝", " 🏝 3" while agents work, " 🏝 ⚠ 1" when one needs you.
  public static func title(_ sessions: [SessionSnapshot]) -> String {
    let attention = sessions.filter(\.requiresAction).count
    let active = sessions.filter { $0.state == .working || $0.state == .starting }.count
    if attention > 0 { return " 🏝 ⚠ \(attention)" }
    if active > 0 { return " 🏝 \(active)" }
    return " 🏝"
  }
}

// MARK: - Updates

public enum Updates {
  /// Releases live in a separate public repo, so this anonymous check works.
  public static let latestRelease = URL(string: "https://api.github.com/repos/soummyaanon/DEV-island-releases/releases/latest")!
  /// GitHub redirects straight to the newest DMG; the asset name never changes.
  public static let directDownload = URL(string: "https://github.com/soummyaanon/DEV-island-releases/releases/latest/download/Agent-Island.dmg")!
  public static let every: Duration = .seconds(60 * 60)

  /// "v0.2.0" beats "0.1.0": numeric, tolerant of a v prefix.
  public static func isNewer(_ latest: String, than current: String) -> Bool {
    func parts(_ v: String) -> [Int] {
      v.replacing(/^[vV]/, with: "").split(separator: ".").map { Int($0) ?? 0 }
    }
    let (next, now) = (parts(latest), parts(current))
    for i in 0..<3 {
      let (a, b) = (i < next.count ? next[i] : 0, i < now.count ? now[i] : 0)
      if a != b { return a > b }
    }
    return false
  }

  /// The detached installer: wait for the app to quit, stage the new bundle,
  /// swap it in only if the copy succeeded, relaunch.
  public static func installerScript(dmg: String, app: String, appName: String = "Agent Island.app") -> String {
    func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    return """
      #!/bin/zsh
      APP=\(quote(app))
      DMG=\(quote(dmg))
      for i in {1..30}; do
        pgrep -f "$APP/Contents/MacOS/" >/dev/null || break
        sleep 0.5
      done
      MNT=$(hdiutil attach "$DMG" -nobrowse -noautoopen | awk -F'\\t' '/\\/Volumes\\//{print $3}' | tail -1)
      NEW="$MNT/\(appName)"
      if [ -d "$NEW" ]; then
        rm -rf "$APP.new"
        if ditto "$NEW" "$APP.new"; then
          rm -rf "$APP"
          mv "$APP.new" "$APP"
          xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
        fi
      fi
      hdiutil detach "$MNT" -quiet 2>/dev/null || hdiutil detach "$MNT" -force -quiet 2>/dev/null || true
      rm -f "$DMG"
      open "$APP"

      """
  }
}

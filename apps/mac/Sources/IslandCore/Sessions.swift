import Foundation

// What the island shows about sessions: the pure rules from 1.x's
// agent-avatar.tsx, wing-priority.ts, SessionRow.tsx, a11y.ts, WorkCrew.tsx,
// IdleCrew.tsx and App.tsx, kept here so they stay tested.

/// What a session's robot is doing.
public enum AvatarState: Sendable {
  /// Awake: looks around, blinks.
  case idle
  /// Hops while its agent works.
  case working
  /// Dozes once quiet for `sleepAfter`.
  case sleeping
}

/// Which of the thinking orb's nine animations fits what a session is doing.
public enum OrbState: String, Sendable, CaseIterable {
  case working, searching, solving, listening, connecting, weaving, composing, breathing, shaping
}

extension SessionSnapshot {
  /// A quiet session falls asleep after this long.
  public static let sleepAfter: TimeInterval = 10 * 60

  /// The folder the agent runs in, by name.
  public var projectName: String {
    cwd.split(separator: "/").last.map(String.init) ?? cwd
  }

  /// Working, starting, or waiting on you: it counts as active.
  public var isActive: Bool {
    state == .working || state == .starting || state == .waitingForApproval
  }

  /// Busy enough for a thinking orb instead of a static line.
  public var isThinking: Bool { isActive }

  /// Needs the human: an action flag or a held approval.
  public var needsAction: Bool { requiresAction || pendingApproval != nil }

  public func metaString(_ key: String) -> String? {
    guard let value = meta[key]?.string, !value.isEmpty else { return nil }
    return value
  }

  public func avatarState(now: Date) -> AvatarState {
    if state == .working || state == .starting { return .working }
    if state == .waitingForApproval || pendingQuestion != nil { return .idle }
    return now.timeIntervalSince(updatedAt) > Self.sleepAfter ? .sleeping : .idle
  }

  /// The lifecycle first, then the activity line; the first rule that matches wins.
  public var orbState: OrbState {
    if state == .starting { return .connecting }
    if state == .waitingForApproval || pendingQuestion != nil { return .listening }
    let rules: [(Regex<Substring>, OrbState)] = [
      (/\b(?:search|grep|glob|find|looking|web|fetch|query)/, .searching),
      (/\b(?:edit|writ|patch|creat|updat|refactor|rename|apply)/, .composing),
      // Planning plaits (weaving); reasoning solves.
      (/\b(?:plan|outlin|strateg)/, .weaving),
      (/\b(?:think|reason|consider|analy[sz]|debug)/, .solving),
      (/\b(?:read|open|view|explor|scan|inspect|list)/, .searching),
      (/\b(?:connect|mcp|start|load|launch|install)/, .connecting),
      (/\b(?:run|bash|test|build|exec|compil|lint|deploy)/, .working),
      (/\b(?:ask|question|prompt|wait)/, .listening),
    ]
    for (pattern, orb) in rules where title.contains(pattern.ignoresCase()) {
      return orb
    }
    // Busy with something unnamed: never "breathing", which reads as stalled.
    return .working
  }

  /// A stable 0–1 offset (FNV-1a of the key), so robots don't blink in unison.
  public var seed: Double { Self.seed(key) }

  public static func seed(_ text: String) -> Double {
    var hash: UInt32 = 2_166_136_261
    for unit in text.utf16 {
      hash ^= UInt32(unit)
      hash = hash &* 16_777_619
    }
    return Double(hash) / 4_294_967_295
  }

  /// "5s", "12m", "1h 4m" since the session started.
  public func elapsed(now: Date) -> String {
    let total = max(0, Int(now.timeIntervalSince(startedAt)))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    if minutes > 0 { return "\(minutes)m" }
    return "\(total)s"
  }

  /// Where the session lives, from its host app's bundle id or TERM_PROGRAM;
  /// empty when unknown. Never guessed from the agent.
  public var hostLabel: String {
    if let bundleId = metaString("app_bundle_id") {
      let known: [String: String] = [
        "com.todesktop.230313mzl4w4u92": "cursor",
        "com.microsoft.VSCode": "vscode",
        "com.googlecode.iterm2": "iterm",
        "com.apple.Terminal": "terminal",
        "dev.warp.Warp-Stable": "warp",
        "com.mitchellh.ghostty": "ghostty",
        "com.github.wez.wezterm": "wezterm",
      ]
      return known[bundleId] ?? (bundleId.split(separator: ".").last.map { $0.lowercased() } ?? "")
    }
    return switch metaString("term_program") {
    case "iTerm.app": "iterm"
    case "Apple_Terminal": "terminal"
    case "vscode": "vscode"
    default: ""
    }
  }

  /// "claude · cursor · claude-opus-4-6 · plan": the agent, the host when it
  /// isn't obvious, the model, and the permission mode.
  public var contextLine: String {
    let agentName = agent.shortName
    let host = hostLabel
    let modes: [String: String] = [
      "default": "default", "plan": "plan", "acceptEdits": "accept", "auto": "auto",
      "dontAsk": "dont ask", "bypassPermissions": "bypass",
      "agent": "agent", "ask": "ask", "edit": "edit",
    ]
    var parts = [agentName]
    if !host.isEmpty && host != agentName { parts.append(host) }
    if let model = metaString("model") { parts.append(model) }
    if let mode = metaString("permission_mode") { parts.append(modes[mode] ?? mode) }
    return parts.joined(separator: " · ")
  }

  /// What VoiceOver reads for a row: project and state first, the two things a
  /// listener needs before deciding to keep listening.
  public func spokenDescription(now: Date) -> String {
    let stateWords: [SessionState: String] = [
      .working: "working", .starting: "starting", .waitingForApproval: "waiting for you",
      .done: "finished", .failed: "failed", .idle: "idle",
    ]
    return [projectName, stateWords[state] ?? state.rawValue, title, elapsed(now: now)]
      .filter { !$0.isEmpty }
      .joined(separator: ", ")
  }
}

extension AgentKind {
  /// "claude", "codex", "cursor".
  public var shortName: String {
    switch self {
    case .claudeCode: "claude"
    case .codex: "codex"
    case .cursor: "cursor"
    }
  }
}

// MARK: - The list

public enum SessionList {
  /// Attention first, then the most active, then the most recently updated.
  public static func sorted(_ sessions: some Sequence<SessionSnapshot>) -> [SessionSnapshot] {
    let order: [SessionState: Int] = [
      .waitingForApproval: 0, .working: 1, .starting: 2, .idle: 3, .failed: 4, .done: 5,
    ]
    return sessions.sorted { a, b in
      let byState = (order[a.state] ?? 9) - (order[b.state] ?? 9)
      if byState != 0 { return byState < 0 }
      return a.updatedAt > b.updatedAt
    }
  }

  /// Rows in the detailed view, and bubbles in the compact one.
  public static let maxRows = 5
  public static let maxBubbles = 8
}

/// One thinking orb in the left wing per agent kind that's actively running,
/// tinted in its colour (amber when it waits on you) and animated for what its
/// most urgent session is doing.
public struct WingOrb: Equatable, Sendable {
  public var agent: AgentKind
  public var state: OrbState
  /// Waiting on you: the orb takes the waiting colour instead of the agent's.
  public var waiting: Bool

  public init(agent: AgentKind, state: OrbState, waiting: Bool) {
    self.agent = agent
    self.state = state
    self.waiting = waiting
  }

  public static func shown(active: [SessionSnapshot]) -> [WingOrb] {
    AgentKind.allCases.compactMap { kind in
      let mine = active.filter { $0.agent == kind }
      guard let lead = mine.first(where: { $0.state == .waitingForApproval }) ?? mine.first else { return nil }
      return WingOrb(agent: kind, state: lead.orbState, waiting: lead.state == .waitingForApproval)
    }
  }
}

// MARK: - Wings

/// What the collapsed wings show: one winner, in strict order. An agent that
/// needs you or works beats ambience; a live activity never interrupts an
/// agent — except the charger going in or out, which you did and expect to
/// see. An agent's own moment (it just finished or failed) interrupts the
/// others' work for a few seconds: that IS the notification.
public enum WingContent: Sendable {
  case attention, moment, working, activity, lowBattery, weather, empty

  public struct Inputs: Sendable {
    public var needsYou = 0
    public var active = 0
    public var moment = false
    public var activity = false
    public var powerMoment = false
    public var lowBattery = false
    public var weather = false

    public init(
      needsYou: Int = 0, active: Int = 0, moment: Bool = false, activity: Bool = false,
      powerMoment: Bool = false, lowBattery: Bool = false, weather: Bool = false
    ) {
      self.needsYou = needsYou
      self.active = active
      self.moment = moment
      self.activity = activity
      self.powerMoment = powerMoment
      self.lowBattery = lowBattery
      self.weather = weather
    }
  }

  public init(_ i: Inputs) {
    self =
      if i.needsYou > 0 { .attention }
      else if i.moment { .moment }
      else if i.activity && i.powerMoment { .activity }
      else if i.active > 0 { .working }
      else if i.activity { .activity }
      else if i.lowBattery { .lowBattery }
      else if i.weather { .weather }
      else { .empty }
  }
}

/// The right wing while agents work: a bot per working session, past three
/// folded into "+n".
public struct WorkCrew<Element> {
  public static var maxBots: Int { 3 }
  public var shown: [Element]
  public var more: Int

  public init(_ active: [Element]) {
    shown = Array(active.prefix(Self.maxBots))
    more = max(0, active.count - Self.maxBots)
  }
}

/// The island at rest: three bots run a code review, left to right. The
/// first writes (a `</>` over it as it types), and tosses the commit to the
/// second, who reads it over; it goes on to the third, who approves it with a
/// green tick, and the three hop. Then a breather, and the next change.
public struct CodeReview: Equatable, Sendable {
  /// One round, in seconds.
  public static let round: TimeInterval = 10

  /// The writer is typing.
  public var typing = false
  /// The `</>` over the writer: 0 (gone) to 1 (fully shown).
  public var code = 0.0
  /// The commit in flight or in hand: where it is, in bots from the left
  /// (0…2), and how high it arcs above their heads (0…1).
  public var commit: (at: Double, lift: Double)?
  /// The middle bot is reading it over.
  public var reviewing = false
  /// The tick over the approver: 0 (gone) to 1 (fully shown).
  public var approved = 0.0
  /// Each bot's celebration hop, 0 (grounded) to 1 (top of the hop).
  public var hops = [0.0, 0.0, 0.0]
  /// Where each bot leans, in degrees: toward whoever has the change.
  public var leans = [0.0, 0.0, 0.0]

  public init() {}

  /// The scene `t` seconds into the game (wraps every round).
  public init(at t: TimeInterval) {
    let s = (t.truncatingRemainder(dividingBy: Self.round) + Self.round).truncatingRemainder(dividingBy: Self.round)
    typing = s >= 0.3 && s < 2.4
    code = Self.window(s, in: 0.3, 2.6, fade: 0.25)
    // Toss to the reviewer, read it over, toss to the approver.
    switch s {
    case 2.4 ..< 3.0: commit = (Self.ease((s - 2.4) / 0.6), sin(.pi * (s - 2.4) / 0.6))
    case 3.0 ..< 5.2: commit = (1, 0)
    case 5.2 ..< 5.8: commit = (1 + Self.ease((s - 5.2) / 0.6), sin(.pi * (s - 5.2) / 0.6))
    case 5.8 ..< 6.1: commit = (2, 0)
    default: commit = nil
    }
    reviewing = s >= 3.0 && s < 5.2
    approved = Self.window(s, in: 6.0, 8.4, fade: 0.4)
    for i in 0 ..< 3 {
      let start = 6.3 + 0.09 * Double(i)
      hops[i] = s >= start && s < start + 0.45 ? sin(.pi * (s - start) / 0.45) : 0
    }
    for i in 0 ..< 3 { leans[i] = Self.lean(i, wrapped: s) }
  }

  /// Where bot `i` leans `s` seconds into a round. Everyone turns to the
  /// change: the writer's, then the reviewer's, then the approver's; reading
  /// it over, the reviewer nods slowly side to side.
  static func lean(_ i: Int, wrapped s: Double) -> Double {
    if i == 1, s >= 3.0, s < 5.2 { return 5 * sin(2 * .pi * (s - 3.0) / 1.1) }
    let holder = s < 2.6 ? 0 : s < 5.4 ? 1 : s < 6.3 ? 2 : -1
    guard holder >= 0, i != holder else { return 0 }
    return i < holder ? 7 : -7
  }

  /// How long each change of lean takes to show (ease-in-out).
  public static let leanEase = 0.35

  /// Where bot `i` is seen to lean `t` seconds into the game: each change
  /// eased in over `leanEase` seconds, ease-in-out, blended as SwiftUI blends
  /// an animation retargeted mid-flight (each change added on its own curve),
  /// which comes to the lean's recent past weighted by the curve's slope.
  /// Before the game starts every bot stands straight.
  public static func easedLean(_ i: Int, at t: TimeInterval) -> Double {
    var sum = 0.0
    for (k, weight) in leanWeights.enumerated() {
      let τ = t - (Double(k) + 0.5) / Double(leanWeights.count) * leanEase
      guard τ >= 0 else { continue }
      let s = (τ.truncatingRemainder(dividingBy: round) + round).truncatingRemainder(dividingBy: round)
      sum += weight * lean(i, wrapped: s)
    }
    return sum
  }

  /// The curve's rise over each of 16 equal slices of the ease.
  private static let leanWeights: [Double] = {
    let n = 16
    let curve = CubicBezier.easeInOutCurve
    return (0 ..< n).map { curve.y(at: Double($0 + 1) / Double(n)) - curve.y(at: Double($0) / Double(n)) }
  }()

  public static func == (a: CodeReview, b: CodeReview) -> Bool {
    a.typing == b.typing && a.code == b.code && a.commit?.at == b.commit?.at && a.commit?.lift == b.commit?.lift
      && a.reviewing == b.reviewing && a.approved == b.approved && a.hops == b.hops && a.leans == b.leans
  }

  /// 0 → 1 → 0 over [start, end), fading in and out over `fade` seconds.
  static func window(_ s: Double, in start: Double, _ end: Double, fade: Double) -> Double {
    guard s >= start && s < end else { return 0 }
    return min(1, (s - start) / fade, (end - s) / fade)
  }

  /// Ease-in-out, for the toss.
  static func ease(_ u: Double) -> Double { (1 - cos(.pi * min(1, max(0, u)))) / 2 }
}

// MARK: - Transitions

/// Something that just happened to a session, worth a glow, a sound or a word.
public struct SessionTransition: Equatable, Sendable {
  public enum Kind: Sendable {
    case done, failed, question, attention
  }

  public var key: String
  public var project: String
  /// Everything that happened in this update; `kinds.first` is the one the
  /// edge glow shows (done and failed win over needs-you cues).
  public var kinds: [Kind]

  public var primary: Kind { kinds[0] }
}

/// What the previous snapshot said, per session, to tell what changed.
public struct SessionMarks: Equatable, Sendable {
  struct Mark: Equatable, Sendable {
    var state: SessionState
    var needsAction: Bool
    var hasQuestion: Bool
  }

  var marks: [String: Mark]

  public init(_ sessions: [SessionSnapshot]) {
    marks = Dictionary(
      sessions.map { ($0.key, Mark(state: $0.state, needsAction: $0.needsAction, hasQuestion: $0.pendingQuestion != nil)) },
      uniquingKeysWith: { _, last in last }
    )
  }

  /// Transitions from these marks to `sessions`. A brand-new session is silent
  /// until it changes, so relaunching never replays history.
  public func transitions(to sessions: [SessionSnapshot]) -> [SessionTransition] {
    sessions.compactMap { session in
      guard let was = marks[session.key] else { return nil }
      var kinds: [SessionTransition.Kind] = []
      if session.state != was.state && session.state == .done { kinds.append(.done) }
      if session.state != was.state && session.state == .failed { kinds.append(.failed) }
      if session.pendingQuestion != nil && !was.hasQuestion { kinds.append(.question) }
      if session.needsAction && !was.needsAction { kinds.append(.attention) }
      return kinds.isEmpty ? nil : SessionTransition(key: session.key, project: session.projectName, kinds: kinds)
    }
  }

  /// One spoken sentence for a whole update, not one per session.
  public static func summary(_ transitions: [SessionTransition]) -> (message: String, assertive: Bool)? {
    func count(_ kind: SessionTransition.Kind) -> Int {
      transitions.filter { $0.kinds.contains(kind) }.count
    }
    let (done, failed, questions, actions) = (count(.done), count(.failed), count(.question), count(.attention))
    let total = done + failed + questions + actions
    guard total > 0 else { return nil }
    let only = transitions.last?.project ?? ""
    func subject(_ n: Int, _ verb: String) -> String {
      total == 1 && !only.isEmpty ? "\(only) \(verb)" : "\(n) \(n == 1 ? "session" : "sessions") \(verb)"
    }
    var parts: [String] = []
    if questions > 0 { parts.append(subject(questions, "is asking a question")) }
    if actions > 0 { parts.append(subject(actions, "needs you")) }
    if failed > 0 { parts.append(subject(failed, "failed")) }
    if done > 0 { parts.append(subject(done, "finished")) }
    return (parts.joined(separator: ", "), questions > 0 || actions > 0)
  }
}

// MARK: - Footer

/// The footer's usage rings for one agent: the 5-hour window before the
/// weekly one, then anything else; at most two.
public struct QuotaSummary: Equatable, Sendable {
  public struct Window: Equatable, Sendable {
    public var label: String
    /// "5h", "wk", "day", "mo", "$".
    public var short: String
    /// 0–100, rounded.
    public var used: Int
    /// "claude 5-hour limit: 42% used, resets in 2h 10m · as of just now".
    public var detail: String
  }

  public var agent: AgentKind
  public var windows: [Window]
  public var credits: String?

  public static func from(_ usage: [AgentUsage], now: Date) -> [QuotaSummary] {
    let order = ["5h", "weekly", "daily", "monthly", "spend"]
    let short = ["5h": "5h", "weekly": "wk", "daily": "day", "monthly": "mo", "spend": "$"]
    let names = ["5h": "5-hour", "weekly": "weekly", "daily": "daily", "monthly": "monthly", "spend": "spend"]
    func rank(_ label: String) -> Int { order.firstIndex(of: label) ?? order.count }

    return usage.compactMap { entry in
      let windows = entry.windows.sorted { rank($0.label) < rank($1.label) }.prefix(2)
      guard !windows.isEmpty || entry.credits != nil else { return nil }
      return QuotaSummary(
        agent: entry.agent,
        windows: windows.map { window in
          let used = Int(min(100, max(0, window.usedPercent)).rounded())
          var detail = "\(entry.agent.shortName) \(names[window.label] ?? window.label) limit: \(used)% used"
          if let resets = window.resetsAt { detail += ", resets in \(Format.resetIn(resets, now: now))" }
          detail += " · as of \(Format.age(entry.updatedAt, now: now))"
          return Window(label: window.label, short: short[window.label] ?? window.label, used: used, detail: detail)
        },
        credits: entry.credits
      )
    }
  }
}

public enum Format {
  /// "12m", "2h 10m", "3d 4h" until a Unix-seconds reset.
  public static func resetIn(_ resetsAt: Double, now: Date) -> String {
    let minutes = max(0, Int(((resetsAt - now.timeIntervalSince1970) / 60).rounded()))
    let (d, h, m) = (minutes / 1440, (minutes % 1440) / 60, minutes % 60)
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
  }

  /// "just now", "40s ago", "3m ago".
  public static func age(_ date: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date).rounded()))
    if seconds < 5 { return "just now" }
    if seconds < 60 { return "\(seconds)s ago" }
    return "\(Int((Double(seconds) / 60).rounded()))m ago"
  }

  /// "200 MB", "1.2 GB".
  public static func memory(megabytes: Double) -> String {
    megabytes >= 1024 ? String(format: "%.1f GB", megabytes / 1024) : "\(Int(megabytes)) MB"
  }
}

import Foundation

// The daemon's core (1.x's packages/daemon hub): canonical events, folded into
// per-session state. Same vocabulary and wire format, so hooks already
// installed and 1.x's own UI keep working against it.

/// Every observation maps onto one of these.
public enum EventType: String, Codable, Sendable {
  case sessionStarted = "session_started"
  case taskProgress = "task_progress"
  case toolUse = "tool_use"
  case permissionRequest = "permission_request"
  case notification
  case sessionEnded = "session_ended"
  case error
}

/// What an adapter (or `curl`) sends: the daemon mints the id and time.
public struct EventInput: Equatable, Sendable {
  public var agent: AgentKind
  public var sessionId: String
  public var cwd: String
  public var type: EventType
  public var title: String
  public var detail: [String: JSONValue]
  public var requiresAction: Bool

  public init(agent: AgentKind, sessionId: String, cwd: String, type: EventType, title: String, detail: [String: JSONValue] = [:], requiresAction: Bool = false) {
    self.agent = agent
    self.sessionId = sessionId
    self.cwd = cwd
    self.type = type
    self.title = title
    self.detail = detail
    self.requiresAction = requiresAction
  }

  /// `POST /events`' body, validated like 1.x's zod schema.
  public init?(body: JSONValue) {
    guard case let .object(o) = body,
      let agent = o["agent"]?.string.flatMap(AgentKind.init(rawValue:)),
      let session = o["session_id"]?.string, !session.isEmpty,
      let cwd = o["cwd"]?.string, !cwd.isEmpty,
      let type = o["type"]?.string.flatMap(EventType.init(rawValue:)),
      let title = o["title"]?.string
    else { return nil }
    var detail: [String: JSONValue] = [:]
    if let raw = o["detail"] {
      guard case let .object(d) = raw else { return nil }
      detail = d
    }
    var requires = false
    if let raw = o["requires_action"] {
      guard case let .bool(b) = raw else { return nil }
      requires = b
    }
    self.init(agent: agent, sessionId: session, cwd: cwd, type: type, title: title, detail: detail, requiresAction: requires)
  }

  /// Merges `values` into `detail._meta`.
  public mutating func addMeta(_ values: [String: JSONValue]) {
    guard !values.isEmpty else { return }
    var meta = detail["_meta"]?.object ?? [:]
    meta.merge(values) { _, new in new }
    detail["_meta"] = .object(meta)
  }
}

/// A canonical event after normalisation.
public struct AgentEvent: Equatable, Sendable, Encodable {
  public var id: String
  public var agent: AgentKind
  public var sessionId: String
  public var cwd: String
  public var timestamp: Date
  public var type: EventType
  public var title: String
  public var detail: [String: JSONValue]
  public var requiresAction: Bool

  enum CodingKeys: String, CodingKey {
    case id, agent, cwd, timestamp, type, title, detail
    case sessionId = "session_id"
    case requiresAction = "requires_action"
  }

  public init(_ input: EventInput, id: String = UUID().uuidString.lowercased(), at timestamp: Date = .now) {
    self.id = id
    agent = input.agent
    sessionId = input.sessionId
    cwd = input.cwd
    self.timestamp = timestamp
    type = input.type
    title = input.title
    detail = input.detail
    requiresAction = input.requiresAction
  }
}

extension JSONValue {
  public var object: [String: JSONValue]? {
    if case let .object(value) = self { value } else { nil }
  }

  public var array: [JSONValue]? {
    if case let .array(value) = self { value } else { nil }
  }

  public var bool: Bool? {
    if case let .bool(value) = self { value } else { nil }
  }

  public subscript(key: String) -> JSONValue? { object?[key] }

  /// A non-blank string.
  public var text: String? {
    guard let string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return string
  }

  /// Parses any JSON text.
  public init?(json data: Data) {
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
    self = value
  }
}

/// The session's next state: the registry is the ONLY place that decides it.
public func nextState(_ type: EventType, requiresAction: Bool) -> SessionState {
  switch type {
  case .sessionStarted: .starting
  case .taskProgress, .toolUse: .working
  case .permissionRequest: .waitingForApproval
  case .notification: requiresAction ? .waitingForApproval : .idle
  case .sessionEnded: .done
  case .error: .failed
  }
}

/// Current state per session, keyed `agent:session_id`.
public struct SessionRegistry: Sendable {
  public private(set) var sessions: [String: SessionSnapshot] = [:]
  /// Insertion order, so snapshots list sessions the way 1.x's Map did.
  private var order: [String] = []

  public init() {}

  public static func key(_ agent: AgentKind, _ sessionId: String) -> String { "\(agent.rawValue):\(sessionId)" }

  /// Folds one event into its session. Adapter metadata (`detail._meta`)
  /// persists across events once captured.
  @discardableResult
  public mutating func apply(_ event: AgentEvent) -> SessionSnapshot {
    let key = Self.key(event.agent, event.sessionId)
    let existing = sessions[key]
    var meta = existing?.meta ?? [:]
    if let incoming = event.detail["_meta"]?.object { meta.merge(incoming) { _, new in new } }
    let snapshot = SessionSnapshot(
      key: key, agent: event.agent, sessionId: event.sessionId, cwd: event.cwd,
      state: nextState(event.type, requiresAction: event.requiresAction), title: event.title,
      requiresAction: event.requiresAction, startedAt: existing?.startedAt ?? event.timestamp, updatedAt: event.timestamp,
      lastEventType: event.type.rawValue, eventCount: (existing?.eventCount ?? 0) + 1, meta: meta,
      pendingApproval: existing?.pendingApproval, pendingQuestion: existing?.pendingQuestion
    )
    if existing == nil { order.append(key) }
    sessions[key] = snapshot
    return snapshot
  }

  public mutating func setPendingQuestion(_ agent: AgentKind, _ sessionId: String, _ question: PendingQuestion?, at now: Date) -> SessionSnapshot? {
    let key = Self.key(agent, sessionId)
    guard var session = sessions[key] else { return nil }
    if session.pendingQuestion == nil && question == nil { return session }
    session.pendingQuestion = question
    session.updatedAt = now
    sessions[key] = session
    return session
  }

  public mutating func setPendingApproval(_ agent: AgentKind, _ sessionId: String, _ approval: PendingApproval?, at now: Date) -> SessionSnapshot? {
    let key = Self.key(agent, sessionId)
    guard var session = sessions[key] else { return nil }
    session.pendingApproval = approval
    session.updatedAt = now
    sessions[key] = session
    return session
  }

  @discardableResult
  public mutating func remove(_ key: String) -> Bool {
    order.removeAll { $0 == key }
    return sessions.removeValue(forKey: key) != nil
  }

  /// Drops sessions that are gone: a Claude session whose process exited (a
  /// closed terminal fires no hook), or a finished one quiet for `stale` with
  /// no process to vouch for it. Anything holding an approval or question stays.
  public mutating func prune(isAlive: (Int) -> Bool, now: Date, stale: TimeInterval) -> [String] {
    var removed: [String] = []
    for key in order {
      guard let s = sessions[key], s.pendingApproval == nil, s.pendingQuestion == nil else { continue }
      if s.agent == .claudeCode, let raw = s.meta["pid"]?.string, let pid = Int(raw), pid > 1 {
        if !isAlive(pid) { removed.append(key) }
        continue
      }
      let resting = s.state == .done || s.state == .idle || s.state == .failed
      if resting && now.timeIntervalSince(s.updatedAt) > stale { removed.append(key) }
    }
    for key in removed { remove(key) }
    return removed
  }

  public var list: [SessionSnapshot] { order.compactMap { sessions[$0] } }

  public func get(_ agent: AgentKind, _ sessionId: String) -> SessionSnapshot? { sessions[Self.key(agent, sessionId)] }
}

// MARK: - Wire encoding

extension SessionSnapshot {
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(key, forKey: .key)
    try c.encode(agent, forKey: .agent)
    try c.encode(sessionId, forKey: .sessionId)
    try c.encode(cwd, forKey: .cwd)
    try c.encode(state, forKey: .state)
    try c.encode(title, forKey: .title)
    try c.encode(requiresAction, forKey: .requiresAction)
    try c.encode(startedAt, forKey: .startedAt)
    try c.encode(updatedAt, forKey: .updatedAt)
    try c.encode(lastEventType, forKey: .lastEventType)
    try c.encode(eventCount, forKey: .eventCount)
    try c.encode(meta, forKey: .meta)
    // Explicit nulls: 1.x's UI tells "no approval" by `=== null`.
    try c.encode(pendingApproval, forKey: .pendingApproval)
    try c.encode(pendingQuestion, forKey: .pendingQuestion)
  }
}

extension WireMessage {
  /// The JSON the daemon streams.
  public func encoded() -> Data {
    let encoder = Self.encoder()
    struct Snapshot: Encodable { let type = "snapshot"; let sessions: [SessionSnapshot] }
    struct Event: Encodable { let type = "event"; let event: AgentEvent; let session: SessionSnapshot }
    struct Usage: Encodable { let type = "usage"; let usage: [AgentUsage] }
    struct Ping: Encodable { let type = "ping"; let t: Date }
    switch self {
    case let .snapshot(sessions): return (try? encoder.encode(Snapshot(sessions: sessions))) ?? Data()
    case .event: return Data()
    case let .usage(usage): return (try? encoder.encode(Usage(usage: usage))) ?? Data()
    case .ping: return (try? encoder.encode(Ping(t: .now))) ?? Data()
    case .unknown: return Data()
    }
  }

  public static func event(_ event: AgentEvent, _ session: SessionSnapshot) -> Data {
    struct Event: Encodable { let type = "event"; let event: AgentEvent; let session: SessionSnapshot }
    return (try? encoder().encode(Event(event: event, session: session))) ?? Data()
  }

  /// Dates the way JavaScript's toISOString writes them.
  public static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var c = encoder.singleValueContainer()
      try c.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
    return encoder
  }
}

// MARK: - Helpers shared by the adapters

enum Text {
  /// Whitespace collapsed, capped with an ellipsis.
  static func truncate(_ s: String, _ max: Int) -> String {
    let clean = s.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
    return clean.count > max ? String(clean.prefix(max - 1)) + "…" : clean
  }

  static func basename(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
  }
}

extension Dictionary where Key == String, Value == JSONValue {
  /// Drops absent values, like 1.x's `prune`.
  static func pruned(_ entries: [String: JSONValue?]) -> [String: JSONValue] {
    entries.compactMapValues { $0 }
  }
}

import Foundation

// The daemon's wire format, mirrored from `packages/shared`. The daemon stays
// the source of truth; these only decode what it sends over `GET /stream`.

public enum AgentKind: String, Codable, Sendable, CaseIterable {
  case claudeCode = "claude-code"
  case codex
  case cursor
}

/// A session's lifecycle, as the daemon's registry derives it.
public enum SessionState: String, Codable, Sendable {
  case starting, working, idle, done, failed
  case waitingForApproval = "waiting-for-approval"
}

/// Arbitrary JSON: session `meta`, a tool call's input.
public enum JSONValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let bool = try? container.decode(Bool.self) {
      self = .bool(bool)
    } else if let number = try? container.decode(Double.self) {
      self = .number(number)
    } else if let string = try? container.decode(String.self) {
      self = .string(string)
    } else if let array = try? container.decode([JSONValue].self) {
      self = .array(array)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case let .string(value): try container.encode(value)
    case let .number(value): try container.encode(value)
    case let .bool(value): try container.encode(value)
    case let .object(value): try container.encode(value)
    case let .array(value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  public var string: String? {
    if case let .string(value) = self { value } else { nil }
  }
}

/// A tool call held open, waiting for allow or deny in the notch.
public struct PendingApproval: Codable, Equatable, Sendable {
  public var id: String
  public var toolName: String
  public var toolInput: [String: JSONValue]
  /// Plan or markdown to review (ExitPlanMode).
  public var plan: String?
  public var createdAt: Date

  enum CodingKeys: String, CodingKey {
    case id, plan
    case toolName = "tool_name"
    case toolInput = "tool_input"
    case createdAt = "created_at"
  }

  public init(id: String, toolName: String, toolInput: [String: JSONValue] = [:], plan: String? = nil, createdAt: Date) {
    self.id = id
    self.toolName = toolName
    self.toolInput = toolInput
    self.plan = plan
    self.createdAt = createdAt
  }
}

/// A multiple-choice question an agent is waiting on.
public struct PendingQuestion: Codable, Equatable, Sendable {
  public struct Item: Codable, Equatable, Sendable {
    public var question: String
    /// Labels in order; answers go back as indices.
    public var options: [String]
    public var multiSelect: Bool?

    public init(question: String, options: [String], multiSelect: Bool? = nil) {
      self.question = question
      self.options = options
      self.multiSelect = multiSelect
    }
  }

  public var id: String
  public var questions: [Item]
  public var createdAt: Date

  enum CodingKeys: String, CodingKey {
    case id, questions
    case createdAt = "created_at"
  }

  public init(id: String, questions: [Item], createdAt: Date) {
    self.id = id
    self.questions = questions
    self.createdAt = createdAt
  }
}

/// One session, exactly as the UI renders it.
public struct SessionSnapshot: Codable, Equatable, Sendable, Identifiable {
  public var key: String
  public var agent: AgentKind
  public var sessionId: String
  public var cwd: String
  public var state: SessionState
  /// The latest human-readable activity line.
  public var title: String
  public var requiresAction: Bool
  public var startedAt: Date
  public var updatedAt: Date
  public var lastEventType: String
  public var eventCount: Int
  /// Adapter metadata: terminal, host app, model, permission mode…
  public var meta: [String: JSONValue]
  public var pendingApproval: PendingApproval?
  public var pendingQuestion: PendingQuestion?

  public var id: String { key }

  enum CodingKeys: String, CodingKey {
    case key, agent, cwd, state, title, meta
    case sessionId = "session_id"
    case requiresAction = "requires_action"
    case startedAt = "started_at"
    case updatedAt = "updated_at"
    case lastEventType = "last_event_type"
    case eventCount = "event_count"
    case pendingApproval = "pending_approval"
    case pendingQuestion = "pending_question"
  }

  public init(
    key: String, agent: AgentKind, sessionId: String, cwd: String, state: SessionState, title: String,
    requiresAction: Bool = false, startedAt: Date, updatedAt: Date, lastEventType: String = "tool_use",
    eventCount: Int = 1, meta: [String: JSONValue] = [:], pendingApproval: PendingApproval? = nil,
    pendingQuestion: PendingQuestion? = nil
  ) {
    self.key = key
    self.agent = agent
    self.sessionId = sessionId
    self.cwd = cwd
    self.state = state
    self.title = title
    self.requiresAction = requiresAction
    self.startedAt = startedAt
    self.updatedAt = updatedAt
    self.lastEventType = lastEventType
    self.eventCount = eventCount
    self.meta = meta
    self.pendingApproval = pendingApproval
    self.pendingQuestion = pendingQuestion
  }
}

/// One rate-limit window, such as the 5-hour or weekly cap.
public struct UsageWindow: Codable, Equatable, Sendable {
  public var label: String
  /// 0–100, how much is USED.
  public var usedPercent: Double
  /// Unix seconds when it resets, if known.
  public var resetsAt: Double?

  enum CodingKeys: String, CodingKey {
    case label
    case usedPercent = "used_percent"
    case resetsAt = "resets_at"
  }

  public init(label: String, usedPercent: Double, resetsAt: Double? = nil) {
    self.label = label
    self.usedPercent = usedPercent
    self.resetsAt = resetsAt
  }
}

/// An agent's account-level quota, read from local data.
public struct AgentUsage: Codable, Equatable, Sendable {
  public var agent: AgentKind
  public var plan: String?
  public var windows: [UsageWindow]
  public var credits: String?
  public var updatedAt: Date

  enum CodingKeys: String, CodingKey {
    case agent, plan, windows, credits
    case updatedAt = "updated_at"
  }

  public init(agent: AgentKind, plan: String? = nil, windows: [UsageWindow], credits: String? = nil, updatedAt: Date) {
    self.agent = agent
    self.plan = plan
    self.windows = windows
    self.credits = credits
    self.updatedAt = updatedAt
  }
}

/// Everything the daemon pushes over `GET /stream`.
public enum WireMessage: Equatable, Sendable {
  /// Every session, once, when the stream opens.
  case snapshot([SessionSnapshot])
  /// One ingested event and the session it produced.
  case event(SessionSnapshot)
  case usage([AgentUsage])
  case ping
  /// A message type this build doesn't know: ignored, never fatal.
  case unknown(String)

  private struct Envelope: Decodable {
    let type: String
  }

  private struct Snapshot: Decodable {
    let sessions: [SessionSnapshot]
  }

  private struct Event: Decodable {
    let session: SessionSnapshot
  }

  private struct Usage: Decodable {
    let usage: [AgentUsage]
  }

  public init(json data: Data) throws {
    let decoder = Self.decoder()
    let type = try decoder.decode(Envelope.self, from: data).type
    switch type {
    case "snapshot": self = .snapshot(try decoder.decode(Snapshot.self, from: data).sessions)
    case "event": self = .event(try decoder.decode(Event.self, from: data).session)
    case "usage": self = .usage(try decoder.decode(Usage.self, from: data).usage)
    case "ping": self = .ping
    default: self = .unknown(type)
    }
  }

  /// ISO 8601 timestamps, with or without fractional seconds (zod's `datetime()`).
  public static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let text = try container.decode(String.self)
      if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
        return date
      }
      if let date = try? Date.ISO8601FormatStyle().parse(text) {
        return date
      }
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(text)")
    }
    return decoder
  }
}

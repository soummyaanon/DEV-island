import Foundation

/// What the Ask bar tells the on-device model and shows about itself (1.x's
/// assistant-context.ts).
public enum AssistantContext {
  /// Sessions the model hears about per question; its context is small.
  public static let maxSessions = 8

  /// One line per session, the facts the rows show: no paths beyond the
  /// project, no diffs, no commands. Empty when there are no sessions.
  public static func text(_ sessions: [SessionSnapshot], now: Date) -> String {
    let states: [SessionState: String] = [
      .starting: "starting", .working: "working", .waitingForApproval: "waiting for your approval",
      .idle: "idle", .done: "done", .failed: "failed",
    ]
    return sessions.prefix(maxSessions).map { s in
      let state = s.pendingQuestion != nil ? "asking you a question" : states[s.state] ?? s.state.rawValue
      let title = String(s.title.replacing(/\s+/, with: " ").prefix(80))
      let minutes = max(0, Int((now.timeIntervalSince(s.updatedAt) / 60).rounded()))
      return "- \(s.projectName) (\(s.agent.displayName)): \(state)\(title.isEmpty ? "" : ", \"\(title)\""), updated \(minutes == 0 ? "just now" : "\(minutes) min ago")"
    }.joined(separator: "\n")
  }

  /// The session a tool named: the exact project first, then a prefix.
  public static func session(named project: String, in sessions: [SessionSnapshot]) -> SessionSnapshot? {
    let wanted = project.trimmingCharacters(in: .whitespaces).lowercased()
    guard !wanted.isEmpty else { return nil }
    return sessions.first { $0.projectName.lowercased() == wanted } ?? sessions.first { $0.projectName.lowercased().hasPrefix(wanted) }
  }

  /// Why the Ask bar can't answer, for its tooltip.
  public static func unavailableReason(_ reason: String) -> String {
    switch reason {
    case "not-enabled": "Turn on Apple Intelligence in System Settings to ask questions here"
    case "model-not-ready": "Apple Intelligence is still downloading its model"
    case "device-not-eligible": "This Mac doesn't support Apple Intelligence"
    case "os": "Needs macOS 26 or later"
    default: "Apple Intelligence isn't available"
    }
  }

  public struct Phase: Sendable {
    public var sent = false
    public var settled = false
    public var tool: String?
    public var streaming = false
    public var proposing = false

    public init(sent: Bool = false, settled: Bool = false, tool: String? = nil, streaming: Bool = false, proposing: Bool = false) {
      self.sent = sent
      self.settled = settled
      self.tool = tool
      self.streaming = streaming
      self.proposing = proposing
    }
  }

  /// The orb is the assistant's status: connecting the moment you send,
  /// solving while it thinks, searching or working while a tool runs,
  /// composing as words arrive, shaping while a proposal waits, listening at rest.
  public static func orb(_ phase: Phase) -> OrbState {
    if let tool = phase.tool {
      return ["searchWeb", "listShortcuts", "readClipboard", "runShortcut"].contains(tool) ? .searching : .working
    }
    if phase.streaming { return .composing }
    if phase.sent { return phase.settled ? .solving : .connecting }
    if phase.proposing { return .shaping }
    return .listening
  }

  /// Only http(s) links are ever opened from a web result.
  public static func isWebURL(_ text: String) -> Bool {
    guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return false }
    return (scheme == "https" || scheme == "http") && url.host != nil
  }
}

extension AgentKind {
  /// "Claude Code", "Codex", "Cursor".
  public var displayName: String {
    switch self {
    case .claudeCode: "Claude Code"
    case .codex: "Codex"
    case .cursor: "Cursor"
    }
  }
}

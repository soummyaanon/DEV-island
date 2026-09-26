import Foundation

/// Codex rollout logs (`$CODEX_HOME/sessions/…/rollout-*.jsonl`) → canonical
/// events (1.x's adapters/codex). Read-only: Codex never knows we're there.
public enum CodexAdapter {
  /// Identity gathered while reading one file: `session_meta` names the
  /// session, `turn_context` can move cwd and model per turn.
  public struct Context: Equatable, Sendable {
    public var sessionId: String?
    public var cwd: String?
    /// Carried onto sessions via `detail._meta` (model, permission_mode, pid).
    public var meta: [String: String] = [:]

    public init(fallbackSessionId: String? = nil) {
      sessionId = fallbackSessionId
    }
  }

  /// The session id in a rollout file's name, lowercased.
  public static func sessionId(fromFileName name: String) -> String? {
    name.firstMatch(of: /([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\.jsonl$/).map { String($0.1).lowercased() }
  }

  public static func isRollout(_ name: String) -> Bool { name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") }

  /// One JSONL line; anything but a JSON object is nil.
  public static func parse(_ line: String) -> JSONValue? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, let value = JSONValue(json: Data(trimmed.utf8)), case .object = value else { return nil }
    return value
  }

  static func arguments(_ raw: JSONValue?) -> JSONValue {
    guard let text = raw?.string, let parsed = JSONValue(json: Data(text.utf8)), case .object = parsed else { return .object([:]) }
    return parsed
  }

  /// The question a `request_user_input` call waits on.
  public static func question(_ entry: JSONValue, id: String = UUID().uuidString.lowercased(), at now: Date = .now) -> PendingQuestion? {
    let payload = entry["payload"]
    guard entry["type"]?.string == "response_item", payload?["type"]?.string == "function_call", payload?["name"]?.string == "request_user_input" else { return nil }
    let items = (arguments(payload?["arguments"])["questions"]?.array ?? []).compactMap { q -> PendingQuestion.Item? in
      guard let text = q["question"]?.string else { return nil }
      return PendingQuestion.Item(question: text, options: (q["options"]?.array ?? []).compactMap { $0["label"]?.string })
    }
    return items.isEmpty ? nil : PendingQuestion(id: id, questions: items, createdAt: now)
  }

  static func describeParsedCommand(_ parsed: JSONValue?) -> String {
    let first = parsed?.array?.first
    let name = first?["name"]?.text
    switch first?["type"]?.string {
    case "read": return name.map { "Reading \($0)" } ?? "Reading"
    case "list_files": return "Finding files"
    case "search": return name.map { "Searching \($0)" } ?? "Searching"
    default: return "working…"
    }
  }

  static func toolCall(_ p: JSONValue) -> (type: EventType, title: String, action: Bool)? {
    let name = p["name"]?.text ?? "tool"
    if p["type"]?.string == "function_call" {
      switch name {
      case "exec_command":
        let command = arguments(p["arguments"])["cmd"]?.text
        return (.toolUse, command.map { "Running \(Text.truncate($0, 44))" } ?? "Running command", false)
      case "update_plan": return (.toolUse, "Updating the plan", false)
      case "request_user_input": return (.notification, "Codex asks a question", true)
      // Keystrokes into a command already announced.
      case "write_stdin": return nil
      default: return (.toolUse, name, false)
      }
    }
    switch name {
    case "apply_patch":
      let file = p["input"]?.string?.firstMatch(of: /\*\*\* (?:Update|Add|Delete) File: (.+)/).map { Text.basename(String($0.1).trimmingCharacters(in: .whitespaces)) }
      return (.toolUse, file.map { "Editing \($0)" } ?? "Applying a patch", false)
    case "exec":
      // The JS-harness variant wraps the real command in exec_command({"cmd":"…"}).
      var command = p["input"]?.text
      if let wrapped = command?.firstMatch(of: /"cmd"\s*:\s*("(?:[^"\\]|\\.)*")/),
        let decoded = try? JSONDecoder().decode(String.self, from: Data(wrapped.1.utf8))
      {
        command = decoded
      }
      return (.toolUse, command.map { "Running \(Text.truncate($0, 44))" } ?? "Running command", false)
    default:
      return (.toolUse, name, false)
    }
  }

  /// One entry → one event, or nil for the many kinds we don't surface. Folds
  /// identity into `ctx` first, so even session_meta is stamped right.
  public static func map(_ entry: JSONValue, _ ctx: inout Context) -> EventInput? {
    let p = entry["payload"] ?? .object([:])
    func finish(_ type: EventType, _ title: String, _ detail: [String: JSONValue?] = [:], action: Bool = false) -> EventInput? {
      guard let session = ctx.sessionId else { return nil }
      var d = [String: JSONValue].pruned(detail)
      if !ctx.meta.isEmpty { d["_meta"] = .object(ctx.meta.mapValues(JSONValue.string)) }
      return EventInput(agent: .codex, sessionId: session, cwd: ctx.cwd ?? "(unknown)", type: type, title: title, detail: d, requiresAction: action)
    }
    switch entry["type"]?.string {
    case "session_meta":
      ctx.sessionId = p["session_id"]?.text ?? p["id"]?.text ?? ctx.sessionId
      ctx.cwd = p["cwd"]?.text ?? ctx.cwd
      return finish(.sessionStarted, "session started", ["source": (p["source"]?.text ?? p["originator"]?.text).map(JSONValue.string), "cli_version": p["cli_version"]?.text.map(JSONValue.string)])
    case "turn_context":
      ctx.cwd = p["cwd"]?.text ?? ctx.cwd
      if let model = p["model"]?.text { ctx.meta["model"] = model }
      if let approval = p["approval_policy"]?.text { ctx.meta["permission_mode"] = approval }
      return nil
    case "event_msg":
      switch p["type"]?.string {
      case "task_started": return finish(.taskProgress, "working…")
      case "task_complete":
        let message = p["last_agent_message"]?.text
        return finish(.sessionEnded, message.map { Text.truncate($0, 64) } ?? "finished responding", ["last_agent_message": message.map { .string(Text.truncate($0, 240)) }])
      case "turn_aborted": return finish(.notification, "turn interrupted", ["reason": p["reason"]?.text.map(JSONValue.string)])
      case "error", "stream_error": return finish(.error, Text.truncate(p["message"]?.text ?? "error", 64))
      case "exec_command_end": return finish(.taskProgress, describeParsedCommand(p["parsed_cmd"]), ["exit_code": p["exit_code"]?.number.map(JSONValue.number)])
      case "patch_apply_end":
        let files = p["changes"]?.object.map { Array($0.keys).sorted() } ?? []
        let title = p["success"]?.bool == false ? "patch failed" : "Edited \(files.count) file\(files.count == 1 ? "" : "s")"
        return finish(.taskProgress, title, ["files": files.isEmpty ? nil : .array(files.prefix(5).map { .string(Text.basename($0)) })])
      case "mcp_tool_call_end":
        let server = p["invocation"]?["server"]?.text, tool = p["invocation"]?["tool"]?.text
        return finish(.taskProgress, server.flatMap { s in tool.map { Text.truncate("\(s).\($0)", 44) } } ?? "working…")
      case "web_search_end":
        return finish(.taskProgress, "Searching the web", ["query": p["query"]?.text.map { .string(Text.truncate($0, 80)) }])
      default: return nil
      }
    case "response_item":
      guard ["function_call", "custom_tool_call"].contains(p["type"]?.string ?? ""), let call = toolCall(p) else { return nil }
      return finish(call.type, call.title, ["tool_name": p["name"]?.text.map(JSONValue.string)], action: call.action)
    default:
      return nil
    }
  }

  /// Which process a session is: whoever holds its rollout open, else a lone
  /// `codex`. Ambiguous is nil: no meter beats a wrong one.
  public static func pickPid(lsof: String, pgrep: String) -> Int? {
    let pids = { (text: String) in text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.wholeMatch(of: /\d{1,7}/) != nil } }
    if let held = pids(lsof).first { return Int(held) }
    let lone = pids(pgrep)
    return lone.count == 1 ? Int(lone[0]) : nil
  }

  /// Codex's quota from the newest rollout's last `token_count`: fully local.
  public static func usage(fromRollout content: String, now: Date = .now) -> AgentUsage? {
    for line in content.split(separator: "\n").reversed() where line.contains("rate_limits") {
      guard let parsed = JSONValue(json: Data(line.utf8)) else { continue }
      let payload = parsed["payload"] ?? parsed
      guard payload["type"]?.string == "token_count", let limits = payload["rate_limits"], limits.object != nil else { continue }
      func window(_ w: JSONValue?) -> UsageWindow? {
        guard let used = w?["used_percent"]?.number else { return nil }
        let minutes = w?["window_minutes"]?.number ?? 0
        let label = minutes <= 0 ? "window" : minutes <= 360 ? "5h" : minutes <= 1440 ? "daily" : minutes <= 20160 ? "weekly" : "monthly"
        return UsageWindow(label: label, usedPercent: used, resetsAt: w?["resets_at"]?.number)
      }
      let balance = limits["credits"]?["balance"]
      let credits: String? = switch balance {
      case let .string(s)?: s
      case let .number(n)?: n == n.rounded() ? String(Int(n)) : String(n)
      default: nil
      }
      return AgentUsage(agent: .codex, plan: limits["plan_type"]?.string, windows: [window(limits["primary"]), window(limits["secondary"])].compactMap(\.self), credits: credits, updatedAt: now)
    }
    return nil
  }

  /// Tails one rollout file: feed it bytes as they're appended.
  public struct Tail: Sendable {
    public var context: Context
    /// Byte just after the last whole line processed.
    public var offset: Int = 0
    /// A request_user_input is unanswered.
    public var questionPending = false

    public init(fileName: String) {
      context = Context(fallbackSessionId: CodexAdapter.sessionId(fromFileName: fileName))
    }

    public enum Output: Equatable, Sendable {
      case ingest(EventInput)
      case question(sessionId: String, PendingQuestion?)
    }

    /// Catch-up on attach: every entry runs through the context so identity
    /// is right, but only session_started and the latest event come out, so
    /// attaching to a long session doesn't replay its history.
    public mutating func attach(_ data: Data) -> [EventInput] {
      guard let lastNewline = data.lastIndex(of: 0x0A) else { return [] }
      offset = lastNewline + 1
      var started: EventInput?
      var latest: EventInput?
      for line in String(decoding: data[..<offset], as: UTF8.self).split(separator: "\n") {
        guard let entry = CodexAdapter.parse(String(line)), let mapped = CodexAdapter.map(entry, &context) else { continue }
        if mapped.type == .sessionStarted { started = mapped } else { latest = mapped }
      }
      if var s = started, let id = context.sessionId { s.sessionId = id; started = s }
      if var l = latest, let cwd = context.cwd { l.cwd = cwd; latest = l }
      return [started, latest].compactMap(\.self)
    }

    /// Bytes appended since `offset`; a trailing partial line waits for the rest.
    public mutating func append(_ data: Data) -> [Output] {
      guard let lastNewline = data.lastIndex(of: 0x0A) else { return [] }
      offset += lastNewline + 1
      var out: [Output] = []
      for line in String(decoding: data[...lastNewline], as: UTF8.self).split(separator: "\n") {
        guard let entry = CodexAdapter.parse(String(line)), let mapped = CodexAdapter.map(entry, &context) else { continue }
        out.append(.ingest(mapped))
        // A question waits until any later activity shows it was answered.
        guard let session = context.sessionId else { continue }
        if let question = CodexAdapter.question(entry) {
          out.append(.question(sessionId: session, question))
          questionPending = true
        } else if questionPending {
          out.append(.question(sessionId: session, nil))
          questionPending = false
        }
      }
      return out
    }
  }
}

extension UsageWindow {
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(label, forKey: .label)
    try c.encode(usedPercent, forKey: .usedPercent)
    try c.encode(resetsAt, forKey: .resetsAt)
  }
}

extension AgentUsage {
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(agent, forKey: .agent)
    try c.encode(plan, forKey: .plan)
    try c.encode(windows, forKey: .windows)
    try c.encode(credits, forKey: .credits)
    try c.encode(updatedAt, forKey: .updatedAt)
  }
}

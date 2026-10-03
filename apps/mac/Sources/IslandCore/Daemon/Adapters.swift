import Foundation

// MARK: - Claude Code

/// Claude Code hook payloads → canonical events (1.x's adapters/claude).
/// Tolerant: every field but `session_id` is optional and unknown ones pass.
public enum ClaudeAdapter {
  static let slugs: [String: String] = [
    "session-start": "SessionStart", "pre-tool": "PreToolUse", "post-tool": "PostToolUse",
    "permission-request": "PermissionRequest", "notification": "Notification", "stop": "Stop", "session-end": "SessionEnd",
  ]

  /// The payload's own event name, else the URL slug.
  public static func eventName(slug: String, payload: JSONValue) -> String {
    payload["hook_event_name"]?.text?.trimmingCharacters(in: .whitespaces) ?? slugs[slug] ?? slug
  }

  /// "Running pnpm test", "Editing index.ts"… from the tool and its input.
  static func describe(_ tool: String?, _ input: JSONValue?) -> String {
    let field = { (key: String) in input?[key]?.string }
    switch tool ?? "tool" {
    case "Bash": return field("command").map { "Running \(Text.truncate($0, 44))" } ?? "Running command"
    case "Read": return field("file_path").map { "Reading \(Text.basename($0))" } ?? "Reading"
    case "Edit", "MultiEdit", "Write": return field("file_path").map { "Editing \(Text.basename($0))" } ?? "Editing"
    case "Grep": return field("pattern").map { "Searching for \(Text.truncate($0, 22))" } ?? "Searching"
    case "Glob": return "Finding files"
    case "Task": return "Delegating to a subagent"
    case "WebFetch", "WebSearch": return "Searching the web"
    case "TodoWrite": return "Updating the plan"
    case let other: return other
    }
  }

  /// One hook → one event, or nil for hooks we don't surface. Idle prompts
  /// aren't attention (no later hook would ever clear them); only a
  /// permission ask is.
  public static func map(_ event: String, payload: JSONValue, fallbackCwd: String) -> EventInput? {
    guard let session = payload["session_id"]?.string else { return nil }
    let cwd = payload["cwd"]?.text ?? fallbackCwd
    let tool = payload["tool_name"]?.string
    let input = payload["tool_input"]
    func make(_ type: EventType, _ title: String, _ detail: [String: JSONValue?], action: Bool = false) -> EventInput {
      EventInput(agent: .claudeCode, sessionId: session, cwd: cwd, type: type, title: title, detail: .pruned(detail), requiresAction: action)
    }
    let asks = { make(.notification, "Claude asks a question", ["tool_name": tool.map(JSONValue.string), "tool_input": input], action: true) }
    switch event {
    case "SessionStart":
      let meta = [String: JSONValue].pruned(["model": payload["model"], "permission_mode": payload["permission_mode"]])
      return make(.sessionStarted, "session \(payload["source"]?.string ?? "started")", [
        "source": payload["source"], "model": payload["model"], "session_title": payload["session_title"], "_meta": .object(meta),
      ])
    case "PreToolUse":
      if tool == "AskUserQuestion" { return asks() }
      return make(.toolUse, describe(tool, input), ["tool_name": tool.map(JSONValue.string), "tool_input": input])
    case "PostToolUse":
      return make(.taskProgress, "working…", ["tool_name": tool.map(JSONValue.string), "tool_response": payload["tool_response"]])
    case "PermissionRequest":
      if tool == "AskUserQuestion" { return asks() }
      return make(.permissionRequest, "approve \(tool ?? "tool")?", ["tool_name": tool.map(JSONValue.string), "tool_input": input], action: true)
    case "Notification":
      let type = payload["notification_type"]?.string
      let message = payload["message"]?.string
      // A permission prompt or an MCP elicitation (a tool asking you for input)
      // waits on you; an idle prompt doesn't.
      let needs = type.map { $0 == "permission_prompt" || $0 == "elicitation_dialog" } ?? (message?.contains(/(?i)\bpermission\b/) ?? false)
      return make(.notification, message ?? "notification", ["notification_type": type.map(JSONValue.string)], action: needs)
    case "Stop":
      return make(.sessionEnded, "finished responding", ["stop_reason": payload["stop_reason"]])
    default:
      return nil
    }
  }

  /// AskUserQuestion's input as a card: "label — description" when described.
  public static func question(from input: JSONValue?, id: String = UUID().uuidString.lowercased(), at now: Date = .now) -> PendingQuestion? {
    let items = (input?["questions"]?.array ?? []).compactMap { q -> PendingQuestion.Item? in
      guard let text = q["question"]?.string else { return nil }
      let options = (q["options"]?.array ?? []).compactMap { o -> String? in
        guard let label = o["label"]?.string else { return nil }
        guard let description = o["description"]?.text else { return label }
        return "\(label) — \(description)"
      }
      return PendingQuestion.Item(question: text, options: options, multiSelect: q["multiSelect"]?.bool == true ? true : nil)
    }
    return items.isEmpty ? nil : PendingQuestion(id: id, questions: items, createdAt: now)
  }

  public struct Answerable: Equatable, Sendable {
    public var question: String
    /// The raw labels: the hook answer needs them verbatim.
    public var labels: [String]
    public var multi: Bool

    public init(question: String, labels: [String], multi: Bool) {
      self.question = question
      self.labels = labels
      self.multi = multi
    }
  }

  /// Every entry with at least one labelled option, or nil if any isn't.
  public static func answerable(_ input: JSONValue?) -> [Answerable]? {
    let raw = input?["questions"]?.array ?? []
    guard !raw.isEmpty else { return nil }
    var out: [Answerable] = []
    for q in raw {
      guard let text = q["question"]?.string else { return nil }
      let labels = (q["options"]?.array ?? []).compactMap { $0["label"]?.string }
      guard !labels.isEmpty else { return nil }
      out.append(Answerable(question: text, labels: labels, multi: q["multiSelect"]?.bool == true))
    }
    return out
  }

  /// A question's answer as Claude's picker writes it: the label, or picks
  /// joined with ", " for a multi-select. Nil when the picks don't fit.
  public static func answerLabel(_ q: Answerable, picks: [Int]) -> String? {
    let unique = Array(Set(picks)).sorted()
    guard !unique.isEmpty, q.multi || unique.count == 1, unique.allSatisfy(q.labels.indices.contains) else { return nil }
    return unique.map { q.labels[$0] }.joined(separator: ", ")
  }

  /// ExitPlanMode's plan, for review.
  public static func plan(from input: JSONValue?) -> String? { input?["plan"]?.text }

  /// Terminal identity from the hook's headers, for jump-back and the meter.
  /// Uninterpolated ("$VAR") and implausible values are dropped.
  public static func terminalMeta(_ header: (String) -> String?) -> [String: JSONValue] {
    func value(_ name: String) -> String? {
      guard let raw = header(name)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, !raw.hasPrefix("$") else { return nil }
      return raw
    }
    var meta: [String: JSONValue] = [:]
    if let term = value("x-term-program") { meta["term_program"] = .string(term) }
    if let pid = value("x-agent-pid"), pid.wholeMatch(of: /\d{1,7}/) != nil { meta["pid"] = .string(pid) }
    if let iterm = value("x-iterm-session-id") { meta["iterm_session_id"] = .string(iterm) }
    if let session = value("x-term-session-id") { meta["term_session_id"] = .string(session) }
    // Reverse-DNS with a dot: a literal "undleIdentifier" from a broken template isn't one.
    if let bundle = value("x-app-bundle-id"), bundle.wholeMatch(of: /[\w-]+(\.[\w-]+)+/) != nil { meta["app_bundle_id"] = .string(bundle) }
    return meta
  }

  /// The 5-hour and weekly limits from Claude's status line JSON; a window
  /// already reset is dropped.
  public static func usage(from body: JSONValue, now: Date = .now) -> AgentUsage? {
    guard let limits = body["rate_limits"]?.object else { return nil }
    let seconds = now.timeIntervalSince1970.rounded(.down)
    let windows = [("five_hour", "5h"), ("seven_day", "weekly"), ("spend_limit", "spend")].compactMap { key, label -> UsageWindow? in
      guard let used = limits[key]?["used_percentage"]?.number, used.isFinite else { return nil }
      let resets = limits[key]?["resets_at"]?.number
      if let resets, resets <= seconds { return nil }
      return UsageWindow(label: label, usedPercent: max(0, used), resetsAt: resets)
    }
    return windows.isEmpty ? nil : AgentUsage(agent: .claudeCode, windows: windows, updatedAt: now)
  }

  /// Windows whose reset has passed since they were reported, gone.
  public static func fresh(_ usage: AgentUsage, now: Date = .now) -> AgentUsage? {
    let seconds = now.timeIntervalSince1970.rounded(.down)
    var usage = usage
    usage.windows = usage.windows.filter { $0.resetsAt.map { $0 > seconds } ?? true }
    return usage.windows.isEmpty ? nil : usage
  }
}

/// `POST /questions/:id`'s body: indices per question (`selections`), or the
/// older one-index-per-question `options`.
public func parseSelections(_ body: JSONValue?) -> [[Int]]? {
  func index(_ v: JSONValue) -> Int? {
    guard let n = v.number, n >= 0, n == n.rounded() else { return nil }
    return Int(n)
  }
  if let selections = body?["selections"]?.array {
    let parsed = selections.map { ($0.array ?? []).map(index) }
    guard !parsed.isEmpty, parsed.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 != nil } }) else { return nil }
    return parsed.map { $0.compactMap(\.self) }
  }
  if let options = body?["options"]?.array, !options.isEmpty {
    let parsed = options.map(index)
    guard parsed.allSatisfy({ $0 != nil }) else { return nil }
    return parsed.map { [$0!] }
  }
  return nil
}

// MARK: - Cursor

/// Cursor hook payloads → canonical events (1.x's adapters/cursor).
public enum CursorAdapter {
  static let bundleId = "com.todesktop.230313mzl4w4u92"

  public static func eventName(slug: String, payload: JSONValue) -> String {
    payload["hook_event_name"]?.text ?? slug
  }

  /// conversation_id on most hooks; session_id or generation_id otherwise.
  public static func sessionId(_ p: JSONValue) -> String? {
    p["conversation_id"]?.text ?? p["session_id"]?.text ?? p["generation_id"]?.text
  }

  /// tool_input is sometimes a JSON string.
  static func record(_ value: JSONValue?) -> JSONValue? {
    if case .object = value { return value }
    if let text = value?.text, let parsed = JSONValue(json: Data(text.utf8)), case .object = parsed { return parsed }
    return nil
  }

  static func describe(_ tool: String?, _ input: JSONValue?) -> String {
    let field = { (key: String) in input?[key]?.string }
    let t = tool ?? "tool"
    switch t {
    case "Shell": return field("command").map { "Running \(Text.truncate($0, 44))" } ?? "Running command"
    case "Read": return (field("file_path") ?? field("path")).map { "Reading \(Text.basename($0))" } ?? "Reading"
    case "Edit", "Write": return (field("file_path") ?? field("path")).map { "Editing \(Text.basename($0))" } ?? "Editing"
    case "Delete": return (field("file_path") ?? field("path")).map { "Deleting \(Text.basename($0))" } ?? "Deleting"
    case "Grep": return field("pattern").map { "Searching for \(Text.truncate($0, 22))" } ?? "Searching"
    case "Glob": return "Finding files"
    case "Task": return (field("description") ?? field("prompt")).map { "Delegating: \(Text.truncate($0, 36))" } ?? "Delegating to a subagent"
    case "WebFetch", "WebSearch": return "Searching the web"
    case "TodoWrite": return "Updating the plan"
    default:
      return t.hasPrefix("MCP:") || t.contains(".") ? Text.truncate(t.replacing(/^MCP:/, with: ""), 44) : Text.truncate(t, 44)
    }
  }

  public static func map(_ event: String, payload p: JSONValue, fallbackCwd: String) -> EventInput? {
    guard let session = sessionId(p) else { return nil }
    let cwd = p["cwd"]?.text ?? p["workspace_roots"]?.array?.first?.text ?? fallbackCwd
    let mode = p["composer_mode"]?.text
    let meta = [String: JSONValue].pruned([
      "model": (p["model"]?.text ?? p["model_id"]?.text).map(JSONValue.string),
      "app_bundle_id": .string(bundleId),
      // The rows show permission_mode; Cursor's composer mode rides there.
      "permission_mode": mode.map(JSONValue.string),
      "composer_mode": mode.map(JSONValue.string),
      "is_background_agent": p["is_background_agent"]?.bool.map(JSONValue.bool),
    ])
    func done(_ type: EventType, _ title: String, _ detail: [String: JSONValue?] = [:]) -> EventInput {
      var d = [String: JSONValue].pruned(detail)
      d["_meta"] = .object(meta)
      return EventInput(agent: .cursor, sessionId: session, cwd: cwd, type: type, title: title, detail: d)
    }
    let s = { (key: String) in p[key]?.text }
    let str = { (value: String?) in value.map(JSONValue.string) }
    switch event {
    case "sessionStart":
      return done(.sessionStarted, mode.map { "session \($0)" } ?? "session started", ["composer_mode": str(mode), "is_background_agent": p["is_background_agent"]?.bool.map(JSONValue.bool)])
    case "beforeSubmitPrompt":
      let prompt = s("prompt")
      return done(.taskProgress, prompt.map { Text.truncate($0, 48) } ?? "working…", ["prompt": str(prompt.map { Text.truncate($0, 120) })])
    case "preToolUse":
      let tool = s("tool_name"), input = record(p["tool_input"])
      return done(.toolUse, s("agent_message").map { Text.truncate($0, 48) } ?? describe(tool, input), ["tool_name": str(tool), "tool_input": input, "tool_use_id": str(s("tool_use_id"))])
    case "postToolUse":
      return done(.taskProgress, "working…", ["tool_name": str(s("tool_name")), "tool_use_id": str(s("tool_use_id"))])
    case "postToolUseFailure":
      if p["is_interrupt"]?.bool == true {
        return done(.taskProgress, "interrupted", ["tool_name": str(s("tool_name")), "failure_type": str(s("failure_type"))])
      }
      let error = s("error_message")
      return done(.error, error.map { Text.truncate($0, 48) } ?? "tool failed", ["tool_name": str(s("tool_name")), "failure_type": str(s("failure_type")), "error_message": str(error.map { Text.truncate($0, 200) })])
    case "beforeShellExecution":
      let command = s("command")
      return done(.toolUse, command.map { "Running \(Text.truncate($0, 44))" } ?? "Running command", ["cmd": str(command.map { Text.truncate($0, 200) })])
    case "afterShellExecution", "afterMCPExecution":
      return done(.taskProgress, "working…")
    case "beforeReadFile":
      return done(.toolUse, s("file_path").map { "Reading \(Text.basename($0))" } ?? "Reading")
    case "afterFileEdit":
      let file = s("file_path")
      return done(.toolUse, file.map { "Editing \(Text.basename($0))" } ?? "Editing", ["file": str(file.map(Text.basename))])
    case "beforeMCPExecution":
      let server = s("server_name") ?? s("server"), tool = s("tool_name") ?? s("tool")
      let title = server.flatMap { sv in tool.map { Text.truncate("\(sv).\($0)", 44) } } ?? tool.map { Text.truncate($0, 44) } ?? "Calling a tool"
      return done(.toolUse, title, ["server": str(server), "tool_name": str(tool), "tool_input": record(p["tool_input"])])
    case "afterAgentThought":
      return done(.taskProgress, "thinking…", ["duration_ms": p["duration_ms"]?.number.map(JSONValue.number)])
    case "afterAgentResponse":
      return done(.taskProgress, "working…")
    case "subagentStart":
      let task = s("task") ?? s("description")
      return done(.toolUse, task.map { "Delegating: \(Text.truncate($0, 36))" } ?? "Delegating to a subagent", ["subagent_type": str(s("subagent_type")), "task": str(task.map { Text.truncate($0, 120) })])
    case "subagentStop":
      let status = s("status") ?? "completed"
      let summary = s("summary") ?? s("description") ?? s("task")
      if status == "error" {
        return done(.error, summary.map { Text.truncate($0, 48) } ?? "subagent failed", ["status": .string(status), "subagent_type": str(s("subagent_type"))])
      }
      return done(.taskProgress, status == "aborted" ? "subagent aborted" : summary.map { Text.truncate($0, 48) } ?? "working…", ["status": .string(status), "subagent_type": str(s("subagent_type"))])
    case "preCompact":
      let percent = p["context_usage_percent"]?.number.map { $0.rounded() }
      return done(.taskProgress, percent.map { "compacting context (\(Int($0))%)" } ?? "compacting context…", ["trigger": str(s("trigger")), "context_usage_percent": percent.map(JSONValue.number)])
    case "stop":
      let status = s("status") ?? "completed"
      if status == "error" { return done(.error, "agent error", ["status": .string(status)]) }
      return done(.sessionEnded, status == "aborted" ? "aborted" : "finished responding", ["status": .string(status)])
    case "sessionEnd":
      let reason = s("reason") ?? s("final_status") ?? "completed"
      if reason == "error" {
        let error = s("error_message")
        return done(.error, error.map { Text.truncate($0, 48) } ?? "session error", ["reason": .string(reason), "error_message": str(error.map { Text.truncate($0, 200) })])
      }
      return done(.sessionEnded, ["aborted", "user_close", "window_close"].contains(reason) ? "session closed" : "finished responding", ["reason": .string(reason)])
    default:
      return nil
    }
  }
}

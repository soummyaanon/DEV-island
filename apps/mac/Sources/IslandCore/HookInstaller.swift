import Foundation

/// Zero Config (1.x's zero-config.ts): wire Claude Code and Cursor to the
/// daemon by safe-merging our hooks into their config. Pure transforms on
/// parsed JSON here; the app does the file IO. The contract: never touch keys
/// other than ours, never remove the user's own hooks, idempotent re-runs, a
/// timestamped backup before any write, and never overwrite a file that
/// doesn't parse.
public enum HookInstaller {
  public enum Result: Equatable, Sendable { case installed, updated, unchanged, error }

  // MARK: Claude Code

  static let claudeMarker = "/events/claude/"

  public struct ClaudeEvent: Sendable {
    public let event: String
    public let slug: String
    public let matcher: Bool
    public let timeout: Int
  }

  public static let claudeEvents: [ClaudeEvent] = [
    .init(event: "SessionStart", slug: "session-start", matcher: false, timeout: 5),
    .init(event: "PreToolUse", slug: "pre-tool", matcher: true, timeout: 5),
    .init(event: "PostToolUse", slug: "post-tool", matcher: true, timeout: 5),
    // Held open for notch approvals: the long timeout.
    .init(event: "PermissionRequest", slug: "permission-request", matcher: true, timeout: 120),
    .init(event: "Notification", slug: "notification", matcher: false, timeout: 5),
    .init(event: "Stop", slug: "stop", matcher: false, timeout: 5),
    // The session closed: it leaves the island instead of lingering as done.
    .init(event: "SessionEnd", slug: "session-end", matcher: false, timeout: 5),
  ]

  /// Claude runs these only as commands, not HTTP: they go through the bridge.
  static let commandOnly: Set<String> = ["SessionStart", "SessionEnd"]

  /// Where our scripts live, under `~/.agent-island/bin`.
  public struct Paths: Sendable {
    public var home: String

    public init(home: String) { self.home = home }

    public var claudeBridge: String { home + "/bin/claude-hook.sh" }
    public var statusScript: String { home + "/bin/claude-statusline.sh" }
    public var savedStatusLine: String { home + "/statusline-original.json" }
    public var savedStatusCommand: String { home + "/statusline-original.cmd" }
    public var cursorBridge: String { home + "/bin/cursor-hook.sh" }
  }

  static func httpHandler(slug: String, timeout: Int, token: String) -> OrderedJSON {
    .object([
      ("type", .string("http")),
      ("url", .string("http://localhost:7433/events/claude/\(slug)")),
      ("headers", .object([
        ("X-Agent-Island-Token", .string(token)),
        ("X-Term-Program", .string("$TERM_PROGRAM")),
        ("X-Iterm-Session-Id", .string("$ITERM_SESSION_ID")),
        ("X-Term-Session-Id", .string("$TERM_SESSION_ID")),
      ])),
      ("allowedEnvVars", .array([.string("TERM_PROGRAM"), .string("ITERM_SESSION_ID"), .string("TERM_SESSION_ID")])),
      ("timeout", .number(String(timeout))),
    ])
  }

  static func isOurs(_ handler: OrderedJSON, paths: Paths) -> Bool {
    let type = handler["type"]?.string
    return (type == "http" && handler["url"]?.string?.contains(claudeMarker) == true)
      || (type == "command" && handler["command"]?.string == paths.claudeBridge)
  }

  /// Our handlers out of a list of matcher groups; emptied groups dropped.
  static func stripOurs(_ groups: OrderedJSON?, paths: Paths) -> [OrderedJSON] {
    (groups?.array ?? []).compactMap { group in
      var group = group
      let kept = (group["hooks"]?.array ?? []).filter { !isOurs($0, paths: paths) }
      guard !kept.isEmpty else { return nil }
      group["hooks"] = .array(kept)
      return group
    }
  }

  /// Merges our hooks and status line into Claude's settings.
  public static func mergeClaude(_ settings: OrderedJSON, token: String, paths: Paths, savedStatusLine: inout OrderedJSON?) -> OrderedJSON {
    var settings = settings
    var hooks = settings["hooks"].flatMap { $0.isObject ? $0 : nil } ?? .object([])
    for spec in claudeEvents {
      var groups = stripOurs(hooks[spec.event], paths: paths)
      let handler: OrderedJSON = commandOnly.contains(spec.event)
        ? .object([("type", .string("command")), ("command", .string(paths.claudeBridge)), ("args", .array([.string(spec.slug)])), ("timeout", .number(String(spec.timeout)))])
        : httpHandler(slug: spec.slug, timeout: spec.timeout, token: token)
      var group = OrderedJSON.object([("hooks", .array([handler]))])
      if spec.matcher { group["matcher"] = .string("*") }
      groups.append(group)
      hooks[spec.event] = .array(groups)
    }
    settings["hooks"] = hooks
    installStatusLine(&settings, paths: paths, saved: &savedStatusLine)
    return settings
  }

  /// Our hooks and status line out of Claude's settings; the user's stay.
  public static func removeClaude(_ settings: OrderedJSON, paths: Paths, savedStatusLine: OrderedJSON?) -> OrderedJSON {
    var settings = settings
    var hooks = settings["hooks"].flatMap { $0.isObject ? $0 : nil } ?? .object([])
    for spec in claudeEvents {
      let kept = stripOurs(hooks[spec.event], paths: paths)
      hooks[spec.event] = kept.isEmpty ? nil : .array(kept)
    }
    settings["hooks"] = hooks.keys.isEmpty ? nil : hooks
    if isOurStatusLine(settings["statusLine"], paths: paths) {
      settings["statusLine"] = savedStatusLine
    }
    return settings
  }

  // MARK: Status line (Claude's 5-hour and weekly limits)

  /// Seconds between re-runs while a session is idle.
  static let statusRefresh = 10

  static func isOurStatusLine(_ value: OrderedJSON?, paths: Paths) -> Bool {
    value?["type"]?.string == "command" && value?["command"]?.string == paths.statusScript
  }

  /// Points Claude's status line at our script, remembering the user's own
  /// (restored on removal; our script also runs it, so nothing looks different).
  static func installStatusLine(_ settings: inout OrderedJSON, paths: Paths, saved: inout OrderedJSON?) {
    let current = settings["statusLine"]
    if isOurStatusLine(current, paths: paths) {
      if current?["refreshInterval"] == nil {
        var ours = current!
        ours["refreshInterval"] = .number(String(statusRefresh))
        settings["statusLine"] = ours
      }
      return
    }
    let original = current.flatMap { $0.isObject ? $0 : nil }
    saved = original
    var line = OrderedJSON.object([("type", .string("command")), ("command", .string(paths.statusScript))])
    if case .number? = original?["padding"] { line["padding"] = original?["padding"] }
    // A user's own, faster interval wins.
    if case let .number(raw)? = original?["refreshInterval"], let interval = Double(raw) {
      line["refreshInterval"] = interval < Double(statusRefresh) ? .number(raw) : .number(String(statusRefresh))
    } else {
      line["refreshInterval"] = .number(String(statusRefresh))
    }
    settings["statusLine"] = line
  }

  // MARK: Cursor

  static let cursorMarker = ".agent-island/bin/cursor-hook"

  /// Observing hooks only: the bridge exits at once so Cursor never waits.
  public static let cursorEvents = [
    "sessionStart", "sessionEnd", "beforeSubmitPrompt", "preToolUse", "postToolUse", "postToolUseFailure",
    "beforeShellExecution", "afterShellExecution", "beforeReadFile", "afterFileEdit", "beforeMCPExecution",
    "afterMCPExecution", "afterAgentThought", "afterAgentResponse", "subagentStart", "subagentStop", "preCompact", "stop",
  ]

  /// Ours by the standard marker, or by this install's bridge path (a
  /// custom AGENT_ISLAND_HOME has no ".agent-island" in it).
  static func isOursCursor(_ entry: OrderedJSON, paths: Paths) -> Bool {
    guard let command = entry["command"]?.string else { return false }
    return command.contains(cursorMarker) || command.hasPrefix(paths.cursorBridge + " ")
  }

  public static func mergeCursor(_ config: OrderedJSON, paths: Paths) -> OrderedJSON {
    var config = config
    if case .number? = config["version"] {} else { config["version"] = .number("1") }
    var hooks = config["hooks"].flatMap { $0.isObject ? $0 : nil } ?? .object([])
    for event in cursorEvents {
      var entries = (hooks[event]?.array ?? []).filter { !isOursCursor($0, paths: paths) }
      entries.append(.object([("command", .string("\(paths.cursorBridge) \(event)"))]))
      hooks[event] = .array(entries)
    }
    config["hooks"] = hooks
    return config
  }

  public static func removeCursor(_ config: OrderedJSON, paths: Paths) -> OrderedJSON {
    var config = config
    var hooks = config["hooks"].flatMap { $0.isObject ? $0 : nil } ?? .object([])
    for event in hooks.keys {
      let kept = (hooks[event]?.array ?? []).filter { !isOursCursor($0, paths: paths) }
      hooks[event] = kept.isEmpty ? nil : .array(kept)
    }
    config["hooks"] = hooks.keys.isEmpty ? nil : hooks
    return config
  }

  // MARK: Scripts

  /// SessionStart and SessionEnd can't be HTTP hooks, so their stdin goes by curl.
  public static let claudeBridgeScript = #"""
    #!/bin/zsh
    # Agent Island Claude bridge (auto-generated; safe to delete).
    EVENT="${1:-session-start}"
    TOKEN="$(cat "$HOME/.agent-island/token" 2>/dev/null)"
    /usr/bin/curl -s -m 4 -X POST "http://127.0.0.1:7433/events/claude/${EVENT}" \
      -H "content-type: application/json" \
      -H "x-agent-island-token: ${TOKEN}" \
      -H "X-Term-Program: ${TERM_PROGRAM:-}" \
      -H "X-Iterm-Session-Id: ${ITERM_SESSION_ID:-}" \
      -H "X-Term-Session-Id: ${TERM_SESSION_ID:-}" \
      -H "X-App-Bundle-Id: ${__CFBundleIdentifier:-}" \
      -H "X-Agent-Pid: ${PPID:-}" \
      --data-binary @- >/dev/null 2>&1
    exit 0

    """#

  /// Forwards Claude's status JSON (for its limits) in the background, then
  /// runs the user's own status line with the same input.
  public static let statusLineScript = #"""
    #!/bin/zsh
    # Agent Island status line (auto-generated; safe to delete). Forwards Claude
    # Code's status JSON (for its usage limits) and runs your own status line.
    INPUT="$(cat)"
    TOKEN="$(cat "$HOME/.agent-island/token" 2>/dev/null)"
    print -r -- "$INPUT" | /usr/bin/curl -s -m 2 -X POST "http://127.0.0.1:7433/usage/claude" \
      -H "content-type: application/json" \
      -H "x-agent-island-token: ${TOKEN}" \
      --data-binary @- >/dev/null 2>&1 &!
    ORIGINAL="$HOME/.agent-island/statusline-original.cmd"
    if [[ -s "$ORIGINAL" ]]; then
      print -r -- "$INPUT" | /bin/sh -c "$(cat "$ORIGINAL")"
    fi
    exit 0

    """#

  /// Forwards Cursor's hook JSON fire-and-forget: Cursor never waits on us.
  public static let cursorBridgeScript = #"""
    #!/bin/zsh
    # Agent Island Cursor bridge (auto-generated; safe to delete).
    # Forwards the hook JSON from stdin to the local daemon, fire-and-forget:
    # Cursor never waits on us and never fails because of us.
    EVENT="${1:-unknown}"
    IN="$(cat)"
    TOKEN="$(cat "$HOME/.agent-island/token" 2>/dev/null)"
    ( printf '%s' "$IN" | /usr/bin/curl -s -m 2 -X POST "http://127.0.0.1:7433/events/cursor/${EVENT}" \
        -H "content-type: application/json" -H "x-agent-island-token: ${TOKEN}" \
        -H "X-Agent-Pid: ${PPID:-}" \
        --data-binary @- >/dev/null 2>&1 & )
    exit 0

    """#
}

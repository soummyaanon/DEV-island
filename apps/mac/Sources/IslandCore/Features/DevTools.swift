import Foundation

// The developer strip's rules: "always allow" for an approval, which
// commands are checks (tests, builds, lint), the status line's context and
// cost, and `git diff --shortstat`.

// MARK: - Always allow

/// "Always allow" on an approval card: the rule Claude Code itself suggests
/// (what its own "Yes, and don't ask again" would save), else a careful one.
public struct RememberRule: Equatable, Sendable {
  /// What the button says, e.g. `Always allow "npm run lint"`.
  public var label: String
  /// The PermissionRequest decision's `updatedPermissions`.
  public var permissions: JSONValue

  public init(label: String, permissions: JSONValue) {
    self.label = label
    self.permissions = permissions
  }
}

public enum Remember {
  /// Tools that edit files: remembered for this session only, like Claude's own prompt.
  static let editors: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

  /// The rule for a held `tool` call, or nil when nothing safe can be remembered
  /// (a plan to review, a compound shell command with no suggestion).
  public static func rule(tool: String, input: JSONValue?, suggestions: JSONValue?) -> RememberRule? {
    guard tool != "ExitPlanMode", tool != "AskUserQuestion" else { return nil }
    // Claude's own suggestions first: only rules that allow, nothing that
    // widens directories or changes the permission mode.
    let suggested = (suggestions?.array ?? []).filter {
      $0["type"]?.string == "addRules" && $0["behavior"]?.string == "allow" && !($0["rules"]?.array ?? []).isEmpty
    }
    if let first = suggested.first, let rule = first["rules"]?.array?.first, let name = rule["toolName"]?.string {
      let scope = first["destination"]?.string == "session" ? "this session" : "in this project"
      return RememberRule(label: label(name, rule["ruleContent"]?.string, scope: scope), permissions: .array(suggested))
    }
    func add(_ content: String?, destination: String) -> JSONValue {
      var rule: [String: JSONValue] = ["toolName": .string(tool)]
      if let content { rule["ruleContent"] = .string(content) }
      return .array([.object([
        "type": .string("addRules"), "rules": .array([.object(rule)]),
        "behavior": .string("allow"), "destination": .string(destination),
      ])])
    }
    switch tool {
    case "Bash":
      guard let command = input?["command"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty,
        command.firstMatch(of: /&&|\|\||[;|&\n`<>]|\$\(/) == nil
      else { return nil }
      return RememberRule(label: label(tool, command, scope: "in this project"), permissions: add(command, destination: "localSettings"))
    case "WebFetch":
      guard let host = input?["url"]?.string.flatMap({ URL(string: $0)?.host() }), !host.isEmpty else { return nil }
      return RememberRule(label: label(tool, "domain:\(host)", scope: "in this project"), permissions: add("domain:\(host)", destination: "localSettings"))
    case _ where editors.contains(tool):
      return RememberRule(label: "Allow edits for this session", permissions: add(nil, destination: "session"))
    case _ where tool.hasPrefix("mcp__"):
      return RememberRule(label: label(tool, nil, scope: "in this project"), permissions: add(nil, destination: "localSettings"))
    default:
      return nil
    }
  }

  static func label(_ tool: String, _ content: String?, scope: String) -> String {
    let what: String
    if let content, content.hasPrefix("domain:") {
      what = String(content.dropFirst("domain:".count))
    } else if let content, !content.isEmpty {
      what = "“\(Text.truncate(content, 32))”"
    } else if tool.hasPrefix("mcp__") {
      what = tool.split(separator: "__").dropFirst().joined(separator: " ")
    } else {
      what = tool
    }
    return "Always allow \(what) \(scope)"
  }
}

// MARK: - Checks

/// A command that checks the work: its outcome is worth a chip.
public enum DevCheck: String, Sendable, CaseIterable {
  case test, typecheck, lint, build

  public var label: String {
    switch self {
    case .test: "tests"
    case .typecheck: "types"
    case .lint: "lint"
    case .build: "build"
    }
  }

  /// What `command` checks, if anything. Tests win over the rest, so
  /// `npm run build && npm test` counts as tests.
  public static func kind(of command: String) -> DevCheck? {
    let text = command.lowercased()
    let rules: [(DevCheck, Regex<Substring>)] = [
      (.test, /\b(?:test|tests|jest|vitest|pytest|rspec|mocha|phpunit|unittest|playwright|cypress)\b/),
      (.typecheck, /\b(?:typecheck|type-check|mypy|pyright)\b|\btsc\b[^\n]*--noemit/),
      (.lint, /\b(?:lint|eslint|ruff|clippy|swiftlint|rubocop|biome|stylelint|golangci-lint)\b/),
      (.build, /\b(?:build|tsc|webpack|make|gradle|xcodebuild|compile)\b/),
    ]
    // Simple word boundaries: Unicode's treat "test:unit" as one word.
    return rules.first { text.firstMatch(of: $0.1.wordBoundaryKind(.simple)) != nil }?.0
  }
}

// MARK: - Status line

public enum SessionStats {
  /// From Claude Code's status line JSON: the session it's about and the
  /// meta to merge into it (context used, the context window, cost so far).
  public static func meta(from body: JSONValue) -> (sessionId: String, meta: [String: JSONValue])? {
    guard let session = body["session_id"]?.string, !session.isEmpty else { return nil }
    var meta: [String: JSONValue] = [:]
    if let used = body["context_window"]?["used_percentage"]?.number, used.isFinite {
      meta["context_pct"] = .number(min(max(used, 0), 100))
    }
    if let size = body["context_window"]?["context_window_size"]?.number, size > 0 {
      meta["context_size"] = .number(size)
    }
    if let cost = body["cost"]?["total_cost_usd"]?.number, cost.isFinite, cost >= 0 {
      meta["cost_usd"] = .number((cost * 100).rounded() / 100)
    }
    return meta.isEmpty ? nil : (session, meta)
  }

  /// How full a context is: from here a compact is worth thinking about.
  public static let compactSoon: Double = 80
}

// MARK: - Changes

/// `git diff --shortstat`: uncommitted changes in a session's folder.
public struct DiffStat: Equatable, Sendable {
  public var files: Int
  public var added: Int
  public var removed: Int

  public init(files: Int, added: Int, removed: Int) {
    self.files = files
    self.added = added
    self.removed = removed
  }

  public var isEmpty: Bool { files == 0 }

  /// " 3 files changed, 156 insertions(+), 23 deletions(-)"; empty output is a clean tree.
  public static func parse(_ output: String) -> DiffStat {
    func count(_ pattern: Regex<(Substring, Substring)>) -> Int {
      output.firstMatch(of: pattern).flatMap { Int($0.1) } ?? 0
    }
    return DiffStat(
      files: count(/(\d+) files? changed/),
      added: count(/(\d+) insertions?\(\+\)/),
      removed: count(/(\d+) deletions?\(-\)/)
    )
  }
}

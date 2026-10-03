import Foundation

/// What Claude Code and Codex did, from their own local logs (read-only):
/// tokens per day, sessions and projects. Nothing is sent anywhere.
public struct AgentStats: Equatable, Sendable {
  public struct Day: Equatable, Sendable {
    public var claude = 0
    public var codex = 0
    public var total: Int { claude + codex }
  }

  /// Tokens by local calendar day ("2026-10-03").
  public var days: [String: Day] = [:]
  /// Tokens by project folder name, over the whole window.
  public var projects: [String: Int] = [:]
  /// Sessions seen per agent today.
  public var sessionsToday: [AgentKind: Set<String>] = [:]
  /// Tokens per model, over the whole window.
  public var models: [String: Int] = [:]

  public init() {}

  public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  /// The last `count` days, oldest first, zero-filled.
  public func series(days count: Int, now: Date, calendar: Calendar = .current) -> [(key: String, day: Day)] {
    (0..<count).reversed().map { back in
      let date = calendar.date(byAdding: .day, value: -back, to: now) ?? now
      let key = Self.dayKey(date, calendar: calendar)
      return (key, days[key] ?? Day())
    }
  }

  public func today(now: Date) -> Day { days[Self.dayKey(now)] ?? Day() }

  public func topProjects(_ count: Int) -> [(name: String, tokens: Int)] {
    projects.sorted { $0.value > $1.value }.prefix(count).map { ($0.key, $0.value) }
  }

  // MARK: Claude Code

  /// One `~/.claude/projects/*/*.jsonl` file. Each assistant message carries
  /// its usage; streamed copies repeat the message id, so each id counts once.
  public mutating func addClaude(_ text: String, since: Date, now: Date, seen: inout Set<String>) {
    let today = Self.dayKey(now)
    for line in text.split(separator: "\n") where line.contains("\"usage\"") {
      guard let data = line.data(using: .utf8),
        let entry = try? JSONDecoder().decode(ClaudeLine.self, from: data),
        let message = entry.message, let usage = message.usage,
        let date = Self.date(entry.timestamp), date >= since
      else { continue }
      if let id = message.id, !seen.insert(id).inserted { continue }
      let tokens = usage.input_tokens + usage.output_tokens + (usage.cache_creation_input_tokens ?? 0)
      guard tokens > 0 else { continue }
      let key = Self.dayKey(date)
      days[key, default: Day()].claude += tokens
      if let cwd = entry.cwd { projects[Self.projectName(cwd), default: 0] += tokens }
      if let model = message.model, !model.hasPrefix("<") { models[model, default: 0] += tokens }
      if key == today, let session = entry.sessionId { sessionsToday[.claudeCode, default: []].insert(session) }
    }
  }

  // MARK: Codex

  /// One Codex rollout file: its last cumulative token count is the session's
  /// total, credited to the day of that last count.
  public mutating func addCodex(_ text: String, since: Date, now: Date) {
    var session: String?
    var cwd: String?
    var model: String?
    var last: (date: Date, tokens: Int)?
    for line in text.split(separator: "\n") {
      if line.contains("\"session_meta\"") || line.contains("\"turn_context\"") {
        guard let data = line.data(using: .utf8), let entry = try? JSONDecoder().decode(CodexLine.self, from: data) else { continue }
        session = session ?? entry.payload?.id ?? entry.payload?.session_id
        cwd = cwd ?? entry.payload?.cwd
        model = entry.payload?.model ?? model
      } else if line.contains("\"token_count\"") {
        guard let data = line.data(using: .utf8), let entry = try? JSONDecoder().decode(CodexLine.self, from: data),
          let usage = entry.payload?.info?.total_token_usage, let date = Self.date(entry.timestamp)
        else { continue }
        // Cached input is re-read context, not new work: count it out.
        let tokens = max(0, usage.input_tokens - (usage.cached_input_tokens ?? 0)) + usage.output_tokens
        last = (date, tokens)
      }
    }
    guard let last, last.date >= since, last.tokens > 0 else { return }
    let key = Self.dayKey(last.date)
    days[key, default: Day()].codex += last.tokens
    if let cwd { projects[Self.projectName(cwd), default: 0] += last.tokens }
    if let model { models[model, default: 0] += last.tokens }
    if key == Self.dayKey(now), let session { sessionsToday[.codex, default: []].insert(session) }
  }

  // MARK: Parsing

  static func projectName(_ cwd: String) -> String {
    let name = URL(filePath: cwd).lastPathComponent
    return name.isEmpty ? cwd : name
  }

  nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()

  static func date(_ text: String?) -> Date? {
    guard let text else { return nil }
    return iso.date(from: text) ?? isoPlain.date(from: text)
  }

  private struct ClaudeLine: Decodable {
    struct Message: Decodable {
      struct Usage: Decodable {
        let input_tokens: Int
        let output_tokens: Int
        let cache_creation_input_tokens: Int?
      }
      let id: String?
      let model: String?
      let usage: Usage?
    }
    let timestamp: String?
    let sessionId: String?
    let cwd: String?
    let message: Message?
  }

  private struct CodexLine: Decodable {
    struct Payload: Decodable {
      struct Info: Decodable {
        struct Usage: Decodable {
          let input_tokens: Int
          let cached_input_tokens: Int?
          let output_tokens: Int
        }
        let total_token_usage: Usage?
      }
      let id: String?
      let session_id: String?
      let cwd: String?
      let model: String?
      let info: Info?
    }
    let timestamp: String?
    let payload: Payload?
  }
}

public enum TokenText {
  /// "842", "12.4K", "3.1M".
  public static func short(_ tokens: Int) -> String {
    switch tokens {
    case ..<1000: "\(tokens)"
    case ..<1_000_000: String(format: tokens < 10_000 ? "%.1fK" : "%.0fK", Double(tokens) / 1000)
    default: String(format: "%.1fM", Double(tokens) / 1_000_000)
    }
  }
}

/// File paths as a terminal types them when you drag files in: spaces and
/// shell specials escaped, one space between.
public func terminalPaths(_ paths: [String]) -> String {
  paths.map { path in
    var out = ""
    for character in path {
      if " \\'\"()&;$`!*?[]{}<>|#~".contains(character) { out.append("\\") }
      out.append(character)
    }
    return out
  }
  .joined(separator: " ")
}

import Foundation

/// Today's tokens across Claude Code and Codex, fed a few new log lines at a
/// time as the logs grow. Counts the way `AgentStats` does.
public struct TokenTally: Sendable {
  private var claude = 0
  /// Claude message ids already counted: streamed copies repeat them.
  private var seen: Set<String> = []
  /// Each Codex rollout's latest cumulative count, by file.
  private var codex: [String: Int] = [:]

  public init() {}

  public var total: Int { claude + codex.values.reduce(0, +) }

  /// New whole lines from a `~/.claude/projects` log.
  public mutating func addClaude(_ lines: String, since: Date, now: Date) {
    var stats = AgentStats()
    stats.addClaude(lines, since: since, now: now, seen: &seen)
    claude += stats.days.values.reduce(0) { $0 + $1.claude }
  }

  /// New whole lines from one Codex rollout: its latest count replaces the last.
  public mutating func addCodex(_ lines: String, file: String, since: Date, now: Date) {
    var stats = AgentStats()
    stats.addCodex(lines, since: since, now: now)
    let tokens = stats.days.values.reduce(0) { $0 + $1.codex }
    if tokens > 0 { codex[file] = tokens }
  }
}

/// The million-token marks today's total passes. The first reading after
/// launch only sets where we are, so a relaunch never celebrates old news; a
/// new day starts again from zero.
public struct TokenMilestones: Sendable {
  public static let step = 1_000_000

  private var day: String?
  private var reached = 0

  public init() {}

  /// The mark `total` has just passed (1M, 2M…), or nil.
  public mutating func observe(total: Int, day: String) -> Int? {
    let mark = total / Self.step
    guard let current = self.day else {
      self.day = day
      reached = mark
      return nil
    }
    if day != current {
      self.day = day
      reached = 0
    }
    guard mark > reached else { return nil }
    reached = mark
    return mark * Self.step
  }
}

/// Whole lines out of a log that's still being written: everything up to the
/// last newline, and how many bytes that used. A partial last line waits.
public func completeLines(_ data: Data) -> (text: String, used: Int)? {
  guard let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return nil }
  let used = end - data.startIndex + 1
  return (String(decoding: data[data.startIndex..<end], as: UTF8.self), used)
}

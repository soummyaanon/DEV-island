import Foundation
import IslandCore

/// Keeps an eye on today's Claude Code and Codex tokens and calls
/// `onMilestone` each time the total passes another million. Reads only what
/// the logs gained since the last look, every few seconds, off the main actor.
final class TokenMilestoneWatcher {
  /// The mark just passed: 1_000_000, 2_000_000…
  var onMilestone: (Int) -> Void = { _ in }

  nonisolated static let interval: Duration = .seconds(10)

  private let log = TodayTokenLog()
  private var milestones = TokenMilestones()
  private var poll: Task<Void, Never>?

  func start() {
    guard poll == nil else { return }
    poll = Task { [weak self, log] in
      while !Task.isCancelled {
        let (day, total) = await log.read(now: .now)
        guard let self, !Task.isCancelled else { return }
        if let mark = milestones.observe(total: total, day: day) {
          Log.app.notice("tokens passed \(mark, privacy: .public) today")
          onMilestone(mark)
        }
        do { try await Task.sleep(for: Self.interval) } catch { return }
      }
    }
  }

  func stop() {
    poll?.cancel()
    poll = nil
  }
}

/// Today's logs, tailed: each file's read position is kept, so a look costs
/// only the lines written since the last one. A new day starts over.
private actor TodayTokenLog {
  private var day = ""
  private var tally = TokenTally()
  private var offsets: [URL: UInt64] = [:]

  func read(now: Date) -> (day: String, total: Int) {
    let key = AgentStats.dayKey(now)
    if key != day {
      day = key
      tally = TokenTally()
      offsets = [:]
    }
    let since = Calendar.current.startOfDay(for: now)
    let home = FileManager.default.homeDirectoryForCurrentUser
    for file in AgentStatsService.recentFiles(under: home.appending(path: ".claude/projects"), since: since) {
      if let lines = newLines(file) { tally.addClaude(lines, since: since, now: now) }
    }
    for file in AgentStatsService.recentFiles(under: AgentStatsService.codexHome.appending(path: "sessions"), since: since) {
      if let lines = newLines(file) { tally.addCodex(lines, file: file.path, since: since, now: now) }
    }
    return (day, tally.total)
  }

  /// The whole lines written since the last read; a shrunk file is read afresh.
  private func newLines(_ file: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    var offset = offsets[file] ?? 0
    if size < offset { offset = 0 }
    guard size > offset else { return nil }
    guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(),
      let (text, used) = completeLines(data)
    else { return nil }
    offsets[file] = offset + UInt64(used)
    return text
  }
}

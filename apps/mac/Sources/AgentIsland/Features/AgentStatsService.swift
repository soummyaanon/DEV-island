import Foundation
import IslandCore
import Observation

/// Seven days of Claude Code and Codex activity, read from their own logs on
/// this Mac when the Agents tab opens (at most once a minute), off the main actor.
@Observable
final class AgentStatsService {
  private(set) var stats = AgentStats()
  private(set) var loading = false
  private(set) var updated: Date?

  nonisolated static let days = 7

  func refreshIfStale() {
    guard !loading, updated.map({ Date.now.timeIntervalSince($0) > 60 }) ?? true else { return }
    loading = true
    Task {
      let fresh = await Self.read(now: .now)
      stats = fresh
      updated = .now
      loading = false
    }
  }

  @concurrent
  private nonisolated static func read(now: Date) async -> AgentStats {
    let since = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: now)) ?? now
    var stats = AgentStats()
    let home = FileManager.default.homeDirectoryForCurrentUser
    var seen: Set<String> = []
    for file in recentFiles(under: home.appending(path: ".claude/projects"), since: since) {
      guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
      stats.addClaude(text, since: since, now: now, seen: &seen)
    }
    let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(filePath: $0) } ?? home.appending(path: ".codex")
    for file in recentFiles(under: codexHome.appending(path: "sessions"), since: since) {
      guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
      stats.addCodex(text, since: since, now: now)
    }
    return stats
  }

  /// `.jsonl` files touched since `since`, at any depth.
  private nonisolated static func recentFiles(under root: URL, since: Date) -> [URL] {
    guard let walker = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles]
    ) else { return [] }
    var out: [URL] = []
    for case let url as URL in walker where url.pathExtension == "jsonl" {
      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
      if values?.isRegularFile == true, (values?.contentModificationDate ?? .distantPast) >= since { out.append(url) }
    }
    return out
  }
}

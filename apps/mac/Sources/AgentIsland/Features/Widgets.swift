import Foundation
import IslandCore
import Observation

/// Stock quotes, fetched when the Widgets tab shows and the last read is more
/// than five minutes old. Off until switched on in Settings.
@Observable
final class StocksService {
  private(set) var quotes: [StockQuote] = []
  private(set) var updated: Date?
  private(set) var failed = false
  private(set) var loading = false

  @ObservationIgnored private var lastSymbols: [String] = []

  func refreshIfStale(_ symbols: [String]) {
    let stale = updated.map { Date.now.timeIntervalSince($0) > 300 } ?? true
    guard !loading, stale || symbols != lastSymbols else { return }
    lastSymbols = symbols
    loading = true
    Task {
      var fetched: [StockQuote] = []
      for symbol in symbols {
        if let quote = await Self.fetch(symbol) { fetched.append(quote) }
      }
      loading = false
      failed = fetched.isEmpty && !symbols.isEmpty
      if !fetched.isEmpty || symbols.isEmpty {
        quotes = fetched
        updated = .now
      }
    }
  }

  @concurrent
  private nonisolated static func fetch(_ symbol: String) async -> StockQuote? {
    guard let url = StockQuote.url(for: symbol) else { return nil }
    var request = URLRequest(url: url, timeoutInterval: 8)
    request.setValue("Mozilla/5.0 (Macintosh)", forHTTPHeaderField: "User-Agent")
    guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
    return StockQuote(chartJSON: data, symbol: symbol)
  }
}

/// The teleprompter: a script that scrolls under the camera at your pace.
@Observable
final class TeleprompterState {
  var script: String {
    didSet { save() }
  }
  var speed: Double {
    didSet {
      reanchor()
      UserDefaults.standard.set(speed, forKey: "prompterSpeed")
    }
  }
  var fontSize: Double {
    didSet { UserDefaults.standard.set(fontSize, forKey: "prompterFont") }
  }
  var mirrored = false
  var editing = false
  private(set) var playing = false
  /// Height of the laid-out script, for the end stop.
  var contentHeight: Double = 0
  static let viewport: Double = 150

  @ObservationIgnored private var startOffset = 0.0
  @ObservationIgnored private var startedAt: Date?
  @ObservationIgnored private var saveTask: Task<Void, Never>?

  init() {
    script = (try? String(contentsOf: Prompter.scriptURL, encoding: .utf8)) ?? Prompter.sample
    let defaults = UserDefaults.standard
    speed = defaults.object(forKey: "prompterSpeed") as? Double ?? 36
    fontSize = defaults.object(forKey: "prompterFont") as? Double ?? 22
  }

  var limit: Double { max(0, contentHeight - Self.viewport * 0.4) }

  func offset(at now: Date) -> Double {
    guard let startedAt else { return startOffset }
    return Prompter.offset(elapsed: now.timeIntervalSince(startedAt), speed: speed, from: startOffset, limit: limit)
  }

  func togglePlay() {
    if playing {
      startOffset = offset(at: .now)
      startedAt = nil
      playing = false
    } else {
      if startOffset >= limit, limit > 0 { startOffset = 0 }
      editing = false
      startedAt = .now
      playing = true
    }
  }

  func restart() {
    startOffset = 0
    startedAt = playing ? .now : nil
  }

  func stop() {
    startOffset = offset(at: .now)
    startedAt = nil
    playing = false
  }

  func nudge(_ points: Double) {
    startOffset = min(limit, max(0, offset(at: .now) + points))
    if playing { startedAt = .now }
  }

  private func reanchor() {
    guard playing else { return }
    startOffset = offset(at: .now)
    startedAt = .now
  }

  private func save() {
    saveTask?.cancel()
    let text = script
    saveTask = Task {
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      try? FileManager.default.createDirectory(at: Prompter.scriptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? text.write(to: Prompter.scriptURL, atomically: true, encoding: .utf8)
    }
  }
}

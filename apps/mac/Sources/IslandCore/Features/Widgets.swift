import Foundation

// MARK: - Stocks

/// A quote from Yahoo Finance's public chart endpoint (no key, no account).
/// Only the symbols the user typed are sent.
public struct StockQuote: Equatable, Sendable, Identifiable {
  public var symbol: String
  public var price: Double
  public var previousClose: Double
  public var currency: String
  /// Today's closes, oldest first, for a sparkline.
  public var series: [Double]

  public var id: String { symbol }
  public var change: Double { price - previousClose }
  public var changePercent: Double { previousClose == 0 ? 0 : change / previousClose * 100 }

  public init(symbol: String, price: Double, previousClose: Double, currency: String, series: [Double]) {
    self.symbol = symbol
    self.price = price
    self.previousClose = previousClose
    self.currency = currency
    self.series = series
  }

  public static func url(for symbol: String) -> URL? {
    let safe = symbol.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-^=")))
    guard let safe, !safe.isEmpty else { return nil }
    return URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(safe)?range=1d&interval=15m")
  }

  /// "AAPL, msft  ^GSPC" → ["AAPL", "MSFT", "^GSPC"], at most eight, no repeats.
  public static func symbols(_ text: String) -> [String] {
    var seen: Set<String> = []
    return text.uppercased().split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
      .filter { $0.range(of: #"^[A-Z0-9.\-^=]{1,15}$"#, options: .regularExpression) != nil }
      .filter { seen.insert($0).inserted }
      .prefix(8).map(\.self)
  }

  private struct Chart: Decodable {
    struct Body: Decodable {
      let result: [Result]?
    }
    struct Result: Decodable {
      struct Meta: Decodable {
        let symbol: String?
        let currency: String?
        let regularMarketPrice: Double?
        let chartPreviousClose: Double?
        let previousClose: Double?
      }
      struct Indicators: Decodable {
        struct Quote: Decodable { let close: [Double?]? }
        let quote: [Quote]?
      }
      let meta: Meta
      let indicators: Indicators?
    }
    let chart: Body
  }

  public init?(chartJSON data: Data, symbol: String) {
    guard let chart = try? JSONDecoder().decode(Chart.self, from: data), let result = chart.chart.result?.first,
      let price = result.meta.regularMarketPrice
    else { return nil }
    let previous = result.meta.chartPreviousClose ?? result.meta.previousClose ?? price
    let closes = result.indicators?.quote?.first?.close?.compactMap(\.self) ?? []
    self.init(symbol: result.meta.symbol ?? symbol, price: price, previousClose: previous, currency: result.meta.currency ?? "", series: closes)
  }
}

// MARK: - To-dos

/// A local to-do: the island's own list, kept in a JSON file beside settings.
public struct TodoItem: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var text: String
  public var done: Bool
  public var created: Date

  public init(id: UUID = UUID(), text: String, done: Bool = false, created: Date = .now) {
    self.id = id
    self.text = text
    self.done = done
    self.created = created
  }
}

public struct TodoList: Equatable, Sendable {
  public private(set) var items: [TodoItem]

  public init(items: [TodoItem] = []) {
    self.items = items
  }

  /// Open items first (oldest on top), then done ones.
  public var sorted: [TodoItem] {
    items.filter { !$0.done } + items.filter(\.done)
  }

  public var openCount: Int { items.filter { !$0.done }.count }

  @discardableResult
  public mutating func add(_ text: String, at now: Date = .now) -> TodoItem? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let item = TodoItem(text: String(trimmed.prefix(280)), created: now)
    items.append(item)
    return item
  }

  public mutating func toggle(_ id: UUID) {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    items[index].done.toggle()
  }

  public mutating func remove(_ id: UUID) {
    items.removeAll { $0.id == id }
  }

  public mutating func clearDone() {
    items.removeAll(where: \.done)
  }

  public static var defaultURL: URL { IslandSettings.userData.appending(path: "todos.json") }

  public static func load(from url: URL = defaultURL) -> TodoList {
    guard let data = try? Data(contentsOf: url) else { return TodoList() }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return TodoList(items: (try? decoder.decode([TodoItem].self, from: data)) ?? [])
  }

  public func save(to url: URL = defaultURL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(items).write(to: url, options: .atomic)
  }
}

// MARK: - Teleprompter

public enum Prompter {
  /// Speeds offered, in points scrolled per second.
  public static let speeds: ClosedRange<Double> = 8...160
  public static let fontSizes: ClosedRange<Double> = 14...44

  /// How long the script takes to read aloud at a natural 140 words a minute.
  public static func readingTime(_ script: String, wordsPerMinute: Double = 140) -> TimeInterval {
    let words = script.split(whereSeparator: \.isWhitespace).count
    return Double(words) / wordsPerMinute * 60
  }

  /// Where the script sits after `elapsed` seconds, never past its end.
  public static func offset(elapsed: TimeInterval, speed: Double, from start: Double, limit: Double) -> Double {
    min(max(0, limit), max(0, start + elapsed * speed))
  }

  public static var scriptURL: URL { IslandSettings.userData.appending(path: "teleprompter.txt") }

  public static let sample = """
    Welcome to the teleprompter. Paste your script with Edit, then press play.

    The words scroll up right under your camera, so your eyes stay close to the lens \
    while you read. Change the speed and the size below; pause any time.
    """
}

// MARK: - Shelf

/// One thing parked on the shelf: a file you dropped (kept where it was) or
/// one the island had to write itself (a dragged image, a text snippet).
public struct ShelfItem: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var path: String
  /// The island made this file (in its shelf folder) and deletes it on removal.
  public var owned: Bool
  public var added: Date

  public init(id: UUID = UUID(), path: String, owned: Bool = false, added: Date = .now) {
    self.id = id
    self.path = path
    self.owned = owned
    self.added = added
  }

  public var url: URL { URL(filePath: path) }
  public var name: String { url.lastPathComponent }

  public static var folder: URL { IslandSettings.userData.appending(path: "Shelf") }
  public static var indexURL: URL { IslandSettings.userData.appending(path: "shelf.json") }

  /// A name in `folder` that doesn't clash: "Note.txt", "Note 2.txt", …
  public static func freeName(_ wanted: String, existing: Set<String>) -> String {
    guard existing.contains(wanted) else { return wanted }
    let ext = (wanted as NSString).pathExtension
    let stem = (wanted as NSString).deletingPathExtension
    var n = 2
    while true {
      let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
      if !existing.contains(candidate) { return candidate }
      n += 1
    }
  }
}

/// Adds a file once; the shelf is a set by path, newest last.
public func shelfAdding(_ items: [ShelfItem], path: String, owned: Bool = false, at now: Date = .now) -> [ShelfItem] {
  guard !items.contains(where: { $0.path == path }) else { return items }
  return items + [ShelfItem(path: path, owned: owned, added: now)]
}

// MARK: - Month

/// A month laid out in weeks, as a wall calendar: leading blanks up to the
/// first day, honouring the calendar's first weekday.
public enum MonthGrid {
  public static func days(of month: Date, calendar: Calendar = .current) -> [Date?] {
    guard let interval = calendar.dateInterval(of: .month, for: month),
      let count = calendar.range(of: .day, in: .month, for: month)?.count
    else { return [] }
    let first = interval.start
    let weekday = calendar.component(.weekday, from: first)
    let blanks = (weekday - calendar.firstWeekday + 7) % 7
    let days = (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    return Array(repeating: nil, count: blanks) + days.map(Optional.some)
  }

  /// Narrow weekday symbols starting at the calendar's first weekday.
  public static func weekdaySymbols(calendar: Calendar = .current) -> [String] {
    let symbols = calendar.veryShortStandaloneWeekdaySymbols
    let start = calendar.firstWeekday - 1
    return Array(symbols[start...] + symbols[..<start])
  }

  public static func shift(_ month: Date, by months: Int, calendar: Calendar = .current) -> Date {
    let start = calendar.dateInterval(of: .month, for: month)?.start ?? month
    return calendar.date(byAdding: .month, value: months, to: start) ?? month
  }
}

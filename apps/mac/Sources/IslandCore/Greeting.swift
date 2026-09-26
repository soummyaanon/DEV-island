import Foundation

/// The hello the island says at launch and when you come back to the Mac
/// (1.x's greeting.ts). Apple's on-device model writes the line from a few
/// plain facts; without it, a local line stands in. Nothing leaves the Mac.
public struct Greeting: Equatable, Sendable {
  /// "Good evening, Sam".
  public var title: String
  /// One playful line.
  public var line: String
  /// The model wrote `line`.
  public var ai: Bool

  public init(title: String, line: String, ai: Bool) {
    self.title = title
    self.line = line
    self.ai = ai
  }

  public enum Occasion: Sendable { case launch, welcomeBack }

  /// Away at least this long before coming back earns a hello.
  public static let awayThreshold: TimeInterval = 20 * 60

  public struct Facts: Sendable {
    public var name: String
    public var date: Date
    public var weather: String?
    public var battery: (percent: Int, charging: Bool)?
    public var occasion: Occasion
    public var calendar = Calendar.current

    public init(name: String, date: Date, weather: String? = nil, battery: (percent: Int, charging: Bool)? = nil, occasion: Occasion) {
      self.name = name
      self.date = date
      self.weather = weather
      self.battery = battery
      self.occasion = occasion
    }

    var hour: Int { calendar.component(.hour, from: date) }
    var weekday: String { Greeting.weekdays[calendar.component(.weekday, from: date) - 1] }
  }

  static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

  public enum PartOfDay: String, Sendable { case morning, afternoon, evening, night }

  public static func partOfDay(_ hour: Int) -> PartOfDay {
    switch hour {
    case 5..<12: .morning
    case 12..<17: .afternoon
    case 17..<22: .evening
    default: .night
    }
  }

  public static func title(_ facts: Facts) -> String {
    let who = facts.name.isEmpty ? "" : ", \(facts.name)"
    if facts.occasion == .welcomeBack { return "Welcome back\(who)" }
    let part = partOfDay(facts.hour)
    return part == .night ? "Hey there\(who)" : "Good \(part.rawValue)\(who)"
  }

  /// The facts as the model sees them: short lines, nothing it could parrot badly.
  public static func factsText(_ facts: Facts) -> String {
    let minute = facts.calendar.component(.minute, from: facts.date)
    let lines: [String?] = [
      facts.name.isEmpty ? nil : "Name: \(facts.name)",
      "Time of day: \(partOfDay(facts.hour).rawValue) (\(facts.hour):\(String(format: "%02d", minute)))",
      "Weekday: \(facts.weekday)",
      facts.occasion == .welcomeBack ? "Occasion: the user just came back to the Mac" : "Occasion: the Mac just started",
      facts.weather.map { "Weather: \($0)" },
      facts.battery.map { "Battery: \($0.percent)%\($0.charging ? ", charging" : "")" },
    ]
    return lines.compactMap(\.self).joined(separator: "\n")
  }

  /// A local line for when the model can't write one; `pick` in 0..<1 chooses.
  public static func fallbackLine(_ facts: Facts, pick: Double = .random(in: 0..<1)) -> String {
    let part = partOfDay(facts.hour)
    let day = facts.weekday
    var lines: [String] = []
    if let battery = facts.battery, battery.percent <= 20, !battery.charging {
      lines.append("Battery's at \(battery.percent)%. Maybe find a charger before we build anything big?")
    }
    if let weather = facts.weather { lines.append("\(weather) outside. Perfect weather for shipping something.") }
    if part == .morning { lines.append("Fresh coffee, fresh commits. What are we building today?") }
    if part == .night { lines.append("Burning the midnight oil? I'm awake too.") }
    if day == "Friday" { lines.append("It's Friday. Small, safe changes only, deal?") }
    if day == "Monday" { lines.append("New week, clean slate. Let's make it a good one.") }
    lines += [
      "I'm up! Point an agent at something and I'll keep an eye on it.",
      "Ready when you are. Hover over me to ask anything.",
      "Happy \(day). Your agents and I are standing by.",
    ]
    return lines[Int(pick * Double(lines.count)) % lines.count]
  }

  /// One tidy sentence: whitespace collapsed, quotes stripped, capped.
  public static func tidy(_ text: String) -> String {
    let one = text.replacing(/\s+/, with: " ").trimmingCharacters(in: .whitespaces)
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”")).trimmingCharacters(in: .whitespaces)
    guard one.count > 140 else { return one }
    let cut = String(one.prefix(137)).replacing(/\s+\S*$/, with: "")
    return cut + "…"
  }

  /// The title already says hello and the name, so drop the model's own opener
  /// ("Good night, Sam. Ready…" → "Ready…"). Keeps the line if nothing's left.
  public static func dropSalutation(_ line: String, name: String) -> String {
    let who = name.isEmpty ? "" : "(?:\\s*,?\\s*\(NSRegularExpression.escapedPattern(for: name)))?"
    let bareName = name.isEmpty ? "(?!)" : NSRegularExpression.escapedPattern(for: name)
    let pattern = "^(?:(?:good (?:morning|afternoon|evening|night)|hey there|hi|hey|hello|welcome back)\(who)|\(bareName))\\s*[,.!—–-]*\\s*"
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return line }
    let rest = re.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
      .trimmingCharacters(in: .whitespaces)
    guard !rest.isEmpty, rest != line else { return line }
    return rest.prefix(1).uppercased() + rest.dropFirst()
  }

  /// How long the hello stays: long enough to read, then a beat.
  public static func duration(for line: String) -> TimeInterval {
    min(12, 4.2 + Double(line.count) * 0.055)
  }

  /// The first name: the macOS full name's first word, else the login name.
  public static func firstName(fullName: String, login: String) -> String {
    var first = fullName.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    if first.isEmpty {
      first = login.replacing(/[._\d]+/, with: " ").split(separator: " ").first.map(String.init) ?? ""
    }
    return first.prefix(1).uppercased() + first.dropFirst()
  }
}

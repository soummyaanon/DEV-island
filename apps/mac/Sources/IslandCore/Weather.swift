import Foundation

/// Local weather as one of ten scenes (1.x's weather-conditions.ts and
/// location.ts). Pure: the part with judgement in it, testable without
/// waiting for it to snow.
public enum WeatherCondition: String, Sendable, CaseIterable, Codable {
  case clearDay = "clear-day", clearNight = "clear-night", cloudy, fog, rain, snow, thunder, sunrise, sunset, rainbow

  /// WMO 4677 codes as Open-Meteo reports them; the boundaries are what matter.
  public init(wmo code: Int, isDay: Bool) {
    self =
      if code >= 95 { .thunder }
      else if code >= 85 { .snow }
      else if code >= 80 { .rain }
      else if (71...77).contains(code) { .snow }
      else if (51...67).contains(code) { .rain }
      else if code == 45 || code == 48 { .fog }
      else if code >= 2 { .cloudy }
      else { isDay ? .clearDay : .clearNight }
  }

  /// Water is falling right now.
  public static func isPrecipitating(_ code: Int) -> Bool {
    [.rain, .snow, .thunder].contains(WeatherCondition(wmo: code, isDay: true))
  }

  /// How close to sunrise or sunset counts as "at" it, and how long after rain a rainbow may show.
  public static let goldenWindow: TimeInterval = 25 * 60
  public static let rainbowWindow: TimeInterval = 30 * 60

  /// The scene to draw. What's falling wins outright; a rainbow only just
  /// after rain, in daylight; golden hour replaces plain clear or cloudy.
  public init(code: Int, isDay: Bool, now: Date, sunrise: Date?, sunset: Date?, lastPrecipitation: Date?) {
    let base = WeatherCondition(wmo: code, isDay: isDay)
    if [.thunder, .rain, .snow, .fog].contains(base) {
      self = base
    } else if isDay, let rained = lastPrecipitation, (0...Self.rainbowWindow).contains(now.timeIntervalSince(rained)) {
      self = .rainbow
    } else if let sunrise, abs(now.timeIntervalSince(sunrise)) <= Self.goldenWindow {
      self = .sunrise
    } else if let sunset, abs(now.timeIntervalSince(sunset)) <= Self.goldenWindow {
      self = .sunset
    } else {
      self = base
    }
  }

  /// The scene's spoken name: the animation itself is decorative.
  public var words: String {
    switch self {
    case .clearDay: "Clear"
    case .clearNight: "Clear night"
    case .cloudy: "Cloudy"
    case .fog: "Fog"
    case .rain: "Rain"
    case .snow: "Snow"
    case .thunder: "Thunderstorms"
    case .sunrise: "Sunrise"
    case .sunset: "Sunset"
    case .rainbow: "Clearing up"
    }
  }
}

public enum Temperature {
  /// The few regions that still use Fahrenheit day to day, by locale.
  static let fahrenheitRegions: Set<String> = ["US", "BS", "BZ", "KY", "LR", "PW", "FM", "MH"]

  public static func prefersFahrenheit(region: String?) -> Bool {
    region.map { fahrenheitRegions.contains($0) } ?? false
  }

  /// "27°". `auto` follows the locale's usual unit.
  public static func format(celsius: Double, units: IslandSettings.TemperatureUnit, region: String?) -> String {
    let fahrenheit = units == .f || (units == .auto && prefersFahrenheit(region: region))
    let value = fahrenheit ? celsius * 9 / 5 + 32 : celsius
    return "\(Int(value.rounded()))°"
  }
}

/// Where to ask about the weather: typed by you, else the timezone's city (no
/// permission, no network), upgraded to a device fix if one ever arrives.
public struct Coordinates: Equatable, Sendable, Codable {
  public enum Source: String, Sendable, Codable { case manual, device, timezone }

  public var lat: Double
  public var lon: Double
  public var source: Source
  public var label: String

  public init(lat: Double, lon: Double, source: Source, label: String) {
    self.lat = lat
    self.lon = lon
    self.source = source
    self.label = label
  }

  /// ~1 km: weather is city-scale, and more precision is leakage, not accuracy.
  public static func coarsen(_ value: Double) -> Double { (value * 100).rounded() / 100 }

  /// "22.57, 88.36" or "22.57 88.36".
  public static func parseManual(_ input: String) -> (lat: Double, lon: Double)? {
    guard let match = input.wholeMatch(of: /\s*(-?\d+(?:\.\d+)?)\s*[, ]\s*(-?\d+(?:\.\d+)?)\s*/),
      let lat = Double(match.1), let lon = Double(match.2), abs(lat) <= 90, abs(lon) <= 180
    else { return nil }
    return (coarsen(lat), coarsen(lon))
  }

  /// ISO 6709 as zone.tab writes it: `+2232+08822` or `+404251-0740023`.
  public static func parseISO6709(_ value: String) -> (lat: Double, lon: Double)? {
    guard let m = value.trimmingCharacters(in: .whitespaces).wholeMatch(of: /([+-])(\d{2})(\d{2})(\d{2})?([+-])(\d{3})(\d{2})(\d{2})?/) else { return nil }
    func degrees(_ d: Substring, _ m: Substring, _ s: Substring?) -> Double {
      Double(d)! + Double(m)! / 60 + (s.flatMap { Double($0) } ?? 0) / 3600
    }
    let lat = degrees(m.2, m.3, m.4) * (m.1 == "-" ? -1 : 1)
    let lon = degrees(m.6, m.7, m.8) * (m.5 == "-" ? -1 : 1)
    guard abs(lat) <= 90, abs(lon) <= 180 else { return nil }
    return (lat, lon)
  }

  /// The zone name from /etc/localtime's link target, always canonical.
  public static func zone(fromLocaltimeLink target: String) -> String? {
    guard let match = target.firstMatch(of: /(?:^|\/)zoneinfo\/(.+)$/) else { return nil }
    let zone = String(match.1)
    return zone.contains("/") ? zone : nil
  }

  /// The first candidate zone listed in zone.tab. Several candidates, because
  /// the system may report an alias ("Asia/Calcutta") the table doesn't list.
  public static func fromZoneTable(_ table: String, candidates: [String]) -> Coordinates? {
    for zone in candidates {
      for line in table.split(separator: "\n") where !line.hasPrefix("#") {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 3, fields[2].trimmingCharacters(in: .whitespaces) == zone,
          let found = parseISO6709(String(fields[1]))
        else { continue }
        return Coordinates(lat: coarsen(found.lat), lon: coarsen(found.lon), source: .timezone, label: zone)
      }
    }
    return nil
  }
}

/// An Open-Meteo reply (times in epoch seconds, so another timezone can't skew them).
public struct OpenMeteo: Decodable, Sendable {
  public struct Current: Decodable, Sendable {
    public var temperature_2m: Double?
    public var weather_code: Int?
    public var is_day: Int?
  }

  public struct Daily: Decodable, Sendable {
    public var sunrise: [Double]?
    public var sunset: [Double]?
  }

  public struct Hourly: Decodable, Sendable {
    public var time: [Double]?
    public var precipitation: [Double]?
  }

  public var current: Current?
  public var daily: Daily?
  public var hourly: Hourly?

  public static func url(for location: Coordinates) -> URL {
    URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(location.lat)&longitude=\(location.lon)"
      + "&current=temperature_2m,weather_code,is_day&daily=sunrise,sunset"
      + "&hourly=precipitation&past_hours=3&forecast_hours=1&timeformat=unixtime&timezone=auto")!
  }

  /// The last hour with measurable precipitation, looking only backwards.
  public static func lastPrecipitation(times: [Double]?, amounts: [Double]?, before now: Date) -> Date? {
    guard let times, let amounts else { return nil }
    return zip(times, amounts)
      .filter { $0.1 > 0 && $0.0 <= now.timeIntervalSince1970 }
      .map { Date(timeIntervalSince1970: $0.0) }
      .max()
  }

  /// The sunrise or sunset nearest now (tomorrow's once today's has passed).
  public static func nearest(_ values: [Double]?, to now: Date) -> Date? {
    values?.map { Date(timeIntervalSince1970: $0) }.min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
  }

  /// The scene and the temperature in °C, or nil when the reply lacks them.
  public func reading(now: Date) -> (condition: WeatherCondition, celsius: Double)? {
    guard let code = current?.weather_code, let celsius = current?.temperature_2m else { return nil }
    let condition = WeatherCondition(
      code: code,
      isDay: current?.is_day != 0,
      now: now,
      sunrise: Self.nearest(daily?.sunrise, to: now),
      sunset: Self.nearest(daily?.sunset, to: now),
      lastPrecipitation: WeatherCondition.isPrecipitating(code) ? nil : Self.lastPrecipitation(times: hourly?.time, amounts: hourly?.precipitation, before: now)
    )
    return (condition, celsius)
  }
}

/// What the island shows.
public struct WeatherReading: Equatable, Sendable, Codable {
  public var condition: WeatherCondition
  /// "27°".
  public var temperature: String
  /// "Rain, 18°": the scene's accessible name.
  public var summary: String
  public var locationLabel: String
  public var locationSource: Coordinates.Source
  /// A cached reading that couldn't be refreshed.
  public var stale: Bool

  public init(condition: WeatherCondition, temperature: String, summary: String, locationLabel: String, locationSource: Coordinates.Source, stale: Bool) {
    self.condition = condition
    self.temperature = temperature
    self.summary = summary
    self.locationLabel = locationLabel
    self.locationSource = locationSource
    self.stale = stale
  }
}

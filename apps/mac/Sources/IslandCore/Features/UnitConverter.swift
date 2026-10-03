import Foundation

/// "10 km to mi", "72f in c", "3.5 cups = ml": Foundation's own units, read
/// from a short phrase. Nothing leaves the Mac (no currencies, which would).
public enum UnitConverter {
  public struct Result: Equatable, Sendable {
    public var value: Double
    public var input: Double
    public var from: String
    public var to: String

    /// "6.214 mi".
    public var text: String { "\(UnitConverter.format(value)) \(to)" }
    /// "10 km = 6.214 mi".
    public var sentence: String { "\(UnitConverter.format(input)) \(from) = \(text)" }
  }

  /// One alias table: what you type → the unit and how it's shown.
  private static let units: [(names: [String], unit: Dimension, symbol: String)] = [
    // Length
    (["mm", "millimeter", "millimeters", "millimetre", "millimetres"], UnitLength.millimeters, "mm"),
    (["cm", "centimeter", "centimeters", "centimetre", "centimetres"], UnitLength.centimeters, "cm"),
    (["m", "meter", "meters", "metre", "metres"], UnitLength.meters, "m"),
    (["km", "kilometer", "kilometers", "kilometre", "kilometres", "kms"], UnitLength.kilometers, "km"),
    (["in", "inch", "inches", "\""], UnitLength.inches, "in"),
    (["ft", "foot", "feet", "'"], UnitLength.feet, "ft"),
    (["yd", "yard", "yards"], UnitLength.yards, "yd"),
    (["mi", "mile", "miles"], UnitLength.miles, "mi"),
    (["nmi", "nautical mile", "nautical miles"], UnitLength.nauticalMiles, "nmi"),
    // Mass
    (["mg", "milligram", "milligrams"], UnitMass.milligrams, "mg"),
    (["g", "gram", "grams", "gr"], UnitMass.grams, "g"),
    (["kg", "kilo", "kilos", "kilogram", "kilograms", "kgs"], UnitMass.kilograms, "kg"),
    (["oz", "ounce", "ounces"], UnitMass.ounces, "oz"),
    (["lb", "lbs", "pound", "pounds"], UnitMass.pounds, "lb"),
    (["st", "stone", "stones"], UnitMass.stones, "st"),
    (["t", "tonne", "tonnes", "metric ton", "metric tons"], UnitMass.metricTons, "t"),
    // Temperature
    (["c", "°c", "celsius", "centigrade", "degc"], UnitTemperature.celsius, "°C"),
    (["f", "°f", "fahrenheit", "degf"], UnitTemperature.fahrenheit, "°F"),
    (["k", "kelvin"], UnitTemperature.kelvin, "K"),
    // Volume
    (["ml", "milliliter", "milliliters", "millilitre", "millilitres"], UnitVolume.milliliters, "ml"),
    (["l", "liter", "liters", "litre", "litres"], UnitVolume.liters, "l"),
    (["tsp", "teaspoon", "teaspoons"], UnitVolume.teaspoons, "tsp"),
    (["tbsp", "tablespoon", "tablespoons"], UnitVolume.tablespoons, "tbsp"),
    (["floz", "fl oz", "fluid ounce", "fluid ounces"], UnitVolume.fluidOunces, "fl oz"),
    // US customary cups, as recipes mean them (Foundation's `.cups` is 240 ml).
    (["cup", "cups"], UnitVolume(symbol: "cup", converter: UnitConverterLinear(coefficient: 0.2365882365)), "cups"),
    (["pt", "pint", "pints"], UnitVolume.pints, "pt"),
    (["qt", "quart", "quarts"], UnitVolume.quarts, "qt"),
    (["gal", "gallon", "gallons"], UnitVolume.gallons, "gal"),
    // Speed
    (["kmh", "km/h", "kph", "kmph"], UnitSpeed.kilometersPerHour, "km/h"),
    (["mph", "mi/h"], UnitSpeed.milesPerHour, "mph"),
    (["m/s", "mps"], UnitSpeed.metersPerSecond, "m/s"),
    (["kn", "kt", "knot", "knots"], UnitSpeed.knots, "kn"),
    // Area
    (["m2", "m²", "sqm", "sq m", "square meter", "square meters", "square metre", "square metres"], UnitArea.squareMeters, "m²"),
    (["km2", "km²", "sq km", "square kilometer", "square kilometers"], UnitArea.squareKilometers, "km²"),
    (["ft2", "ft²", "sqft", "sq ft", "square foot", "square feet"], UnitArea.squareFeet, "ft²"),
    (["mi2", "mi²", "sq mi", "square mile", "square miles"], UnitArea.squareMiles, "mi²"),
    (["acre", "acres", "ac"], UnitArea.acres, "acres"),
    (["ha", "hectare", "hectares"], UnitArea.hectares, "ha"),
    // Time
    (["ms", "millisecond", "milliseconds"], UnitDuration.milliseconds, "ms"),
    (["s", "sec", "secs", "second", "seconds"], UnitDuration.seconds, "s"),
    (["min", "mins", "minute", "minutes"], UnitDuration.minutes, "min"),
    (["h", "hr", "hrs", "hour", "hours"], UnitDuration.hours, "h"),
    (["day", "days"], UnitDuration(symbol: "d", converter: UnitConverterLinear(coefficient: 86_400)), "days"),
    (["week", "weeks", "wk"], UnitDuration(symbol: "wk", converter: UnitConverterLinear(coefficient: 604_800)), "weeks"),
    // Data
    (["b", "byte", "bytes"], UnitInformationStorage.bytes, "B"),
    (["kb", "kilobyte", "kilobytes"], UnitInformationStorage.kilobytes, "KB"),
    (["mb", "megabyte", "megabytes"], UnitInformationStorage.megabytes, "MB"),
    (["gb", "gigabyte", "gigabytes"], UnitInformationStorage.gigabytes, "GB"),
    (["tb", "terabyte", "terabytes"], UnitInformationStorage.terabytes, "TB"),
    (["kib", "kibibyte", "kibibytes"], UnitInformationStorage.kibibytes, "KiB"),
    (["mib", "mebibyte", "mebibytes"], UnitInformationStorage.mebibytes, "MiB"),
    (["gib", "gibibyte", "gibibytes"], UnitInformationStorage.gibibytes, "GiB"),
    // Energy
    (["j", "joule", "joules"], UnitEnergy.joules, "J"),
    (["kj", "kilojoule", "kilojoules"], UnitEnergy.kilojoules, "kJ"),
    (["cal", "calorie", "calories"], UnitEnergy.calories, "cal"),
    (["kcal", "kilocalorie", "kilocalories"], UnitEnergy.kilocalories, "kcal"),
    (["kwh", "kilowatt hour", "kilowatt hours"], UnitEnergy.kilowattHours, "kWh"),
    // Pressure
    (["psi"], UnitPressure.poundsForcePerSquareInch, "psi"),
    (["bar", "bars"], UnitPressure.bars, "bar"),
    (["kpa"], UnitPressure.kilopascals, "kPa"),
    (["hpa", "mbar"], UnitPressure.hectopascals, "hPa"),
    (["atm"], UnitPressure(symbol: "atm", converter: UnitConverterLinear(coefficient: 101_325)), "atm"),
    // Angle
    (["deg", "degree", "degrees", "°"], UnitAngle.degrees, "°"),
    (["rad", "radian", "radians"], UnitAngle.radians, "rad"),
  ]

  private static func lookup(_ raw: String) -> (unit: Dimension, symbol: String)? {
    let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
    guard !name.isEmpty else { return nil }
    // "MB" and "mb" both mean megabytes; "Mb" (megabits) isn't offered.
    for entry in units where entry.names.contains(name) { return (entry.unit, entry.symbol) }
    // A trailing plural "s" the table didn't list ("kgs" is listed, "mls" isn't).
    if name.hasSuffix("s"), name.count > 2 {
      let single = String(name.dropLast())
      for entry in units where entry.names.contains(single) { return (entry.unit, entry.symbol) }
    }
    return nil
  }

  /// Which family a unit belongs to; `is`, since Foundation hands back subclasses.
  private static func kind(of unit: Dimension) -> String? {
    switch unit {
    case is UnitLength: "length"
    case is UnitMass: "mass"
    case is UnitTemperature: "temperature"
    case is UnitVolume: "volume"
    case is UnitSpeed: "speed"
    case is UnitArea: "area"
    case is UnitDuration: "duration"
    case is UnitInformationStorage: "data"
    case is UnitEnergy: "energy"
    case is UnitPressure: "pressure"
    case is UnitAngle: "angle"
    default: nil
    }
  }

  /// Reads "<number> <unit> to|in|as|=|-> <unit>"; nil for anything else, or
  /// for units of different kinds ("5 kg to km").
  public static func convert(_ phrase: String) -> Result? {
    let text = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      .replacingOccurrences(of: "→", with: " to ").replacingOccurrences(of: "->", with: " to ")
      .replacingOccurrences(of: "=", with: " to ")
      .replacingOccurrences(of: ",", with: "")
    let pattern = #"^(?:convert\s+)?(-?\d+(?:\.\d+)?|-?\.\d+)\s*(.+?)\s+(?:to|in|into|as)\s+(.+?)\??$"#
    guard let re = try? NSRegularExpression(pattern: pattern),
      let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let numberRange = Range(m.range(at: 1), in: text), let fromRange = Range(m.range(at: 2), in: text),
      let toRange = Range(m.range(at: 3), in: text), let number = Double(text[numberRange]),
      let from = lookup(String(text[fromRange])), let to = lookup(String(text[toRange]))
    else { return nil }
    guard let kind = kind(of: from.unit), kind == self.kind(of: to.unit) else { return nil }
    let base = from.unit.converter.baseUnitValue(fromValue: number)
    let value = to.unit.converter.value(fromBaseUnitValue: base)
    return Result(value: value, input: number, from: from.symbol, to: to.symbol)
  }

  /// A family of units for the picker: its icon, its units (display symbols,
  /// in a sensible order) and the pair it starts on.
  public struct Kind: Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let symbol: String
    public let units: [String]
    public let from: String
    public let to: String
  }

  private static let kindInfo: [(id: String, name: String, symbol: String, from: String, to: String)] = [
    ("length", "Length", "ruler", "km", "mi"),
    ("mass", "Weight", "scalemass", "kg", "lb"),
    ("temperature", "Temperature", "thermometer.medium", "°C", "°F"),
    ("volume", "Volume", "drop", "l", "gal"),
    ("speed", "Speed", "gauge.with.dots.needle.67percent", "km/h", "mph"),
    ("area", "Area", "square.dashed", "m²", "ft²"),
    ("duration", "Time", "clock", "h", "min"),
    ("data", "Data", "internaldrive", "GB", "MB"),
    ("energy", "Energy", "bolt", "kcal", "kJ"),
    ("pressure", "Pressure", "barometer", "bar", "psi"),
    ("angle", "Angle", "angle", "°", "rad"),
  ]

  /// Every family, each with its units in table order.
  public static let kinds: [Kind] = kindInfo.map { info in
    var seen: Set<String> = []
    let units = Self.units.filter { kind(of: $0.unit) == info.id }.map(\.symbol).filter { seen.insert($0).inserted }
    return Kind(id: info.id, name: info.name, symbol: info.symbol, units: units, from: info.from, to: info.to)
  }

  /// `value` from one display symbol to another of the same family; nil otherwise.
  public static func convert(_ value: Double, from: String, to: String) -> Double? {
    guard let a = units.first(where: { $0.symbol == from }), let b = units.first(where: { $0.symbol == to }),
      let kind = kind(of: a.unit), kind == self.kind(of: b.unit)
    else { return nil }
    return b.unit.converter.value(fromBaseUnitValue: a.unit.converter.baseUnitValue(fromValue: value))
  }

  /// Up to four decimals, trailing zeros dropped, grouping for big numbers.
  public static func format(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.usesGroupingSeparator = abs(value) >= 1000
    formatter.groupingSeparator = ","
    formatter.maximumFractionDigits = abs(value) >= 1000 ? 1 : abs(value) >= 1 ? 3 : 4
    formatter.minimumFractionDigits = 0
    // Tiny values keep their significant digits.
    if value != 0, abs(value) < 0.001 {
      return String(format: "%.3g", value)
    }
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
  }
}

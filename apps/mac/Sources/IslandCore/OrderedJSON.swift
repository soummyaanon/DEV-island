import Foundation

/// JSON that keeps its keys in order and its numbers as written, so editing
/// someone's `~/.claude/settings.json` changes only what we meant to change.
/// Written back exactly like `JSON.stringify(value, null, 2)`.
public indirect enum OrderedJSON: Equatable, Sendable {
  case object([(key: String, value: OrderedJSON)])
  case array([OrderedJSON])
  case string(String)
  /// The number exactly as it appeared.
  case number(String)
  case bool(Bool)
  case null

  public static func == (a: OrderedJSON, b: OrderedJSON) -> Bool {
    switch (a, b) {
    case let (.object(x), .object(y)): x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    case let (.array(x), .array(y)): x == y
    case let (.string(x), .string(y)): x == y
    case let (.number(x), .number(y)): x == y
    case let (.bool(x), .bool(y)): x == y
    case (.null, .null): true
    default: false
    }
  }

  // MARK: Access

  public subscript(key: String) -> OrderedJSON? {
    get {
      guard case let .object(entries) = self else { return nil }
      return entries.last { $0.key == key }?.value
    }
    set {
      guard case var .object(entries) = self else { return }
      if let index = entries.firstIndex(where: { $0.key == key }) {
        if let newValue { entries[index].value = newValue } else { entries.remove(at: index) }
      } else if let newValue {
        entries.append((key, newValue))
      }
      self = .object(entries)
    }
  }

  public var string: String? {
    if case let .string(value) = self { value } else { nil }
  }

  public var array: [OrderedJSON]? {
    if case let .array(value) = self { value } else { nil }
  }

  public var isObject: Bool {
    if case .object = self { true } else { false }
  }

  public var keys: [String] {
    if case let .object(entries) = self { entries.map(\.key) } else { [] }
  }

  /// Compares by content, ignoring key order: "did anything really change?"
  public var canonical: String {
    switch self {
    case let .object(entries):
      "{" + entries.sorted { $0.key < $1.key }.map { "\(Self.quote($0.key)):\($0.value.canonical)" }.joined(separator: ",") + "}"
    case let .array(items): "[" + items.map(\.canonical).joined(separator: ",") + "]"
    case let .string(value): Self.quote(value)
    case let .number(value): value
    case let .bool(value): value ? "true" : "false"
    case .null: "null"
    }
  }

  // MARK: Writing

  /// `JSON.stringify(value, null, 2)`.
  public func serialized(indent: Int = 0) -> String {
    let pad = String(repeating: "  ", count: indent + 1)
    let close = String(repeating: "  ", count: indent)
    switch self {
    case let .object(entries):
      if entries.isEmpty { return "{}" }
      return "{\n" + entries.map { "\(pad)\(Self.quote($0.key)): \($0.value.serialized(indent: indent + 1))" }.joined(separator: ",\n") + "\n\(close)}"
    case let .array(items):
      if items.isEmpty { return "[]" }
      return "[\n" + items.map { pad + $0.serialized(indent: indent + 1) }.joined(separator: ",\n") + "\n\(close)]"
    case let .string(value): return Self.quote(value)
    case let .number(value): return value
    case let .bool(value): return value ? "true" : "false"
    case .null: return "null"
    }
  }

  static func quote(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case "\u{08}": out += "\\b"
      case "\u{0C}": out += "\\f"
      case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out + "\""
  }

  // MARK: Reading

  public struct ParseError: Error, Equatable {
    public let offset: Int
  }

  public init(parsing text: String) throws {
    var parser = Parser(Array(text.unicodeScalars))
    parser.skipSpace()
    self = try parser.value()
    parser.skipSpace()
    guard parser.atEnd else { throw ParseError(offset: parser.index) }
  }

  private struct Parser {
    let s: [Unicode.Scalar]
    var index = 0

    init(_ s: [Unicode.Scalar]) { self.s = s }

    var atEnd: Bool { index >= s.count }
    var peek: Unicode.Scalar? { atEnd ? nil : s[index] }

    mutating func skipSpace() {
      while let c = peek, c == " " || c == "\n" || c == "\r" || c == "\t" { index += 1 }
    }

    mutating func expect(_ word: String) throws {
      for scalar in word.unicodeScalars {
        guard peek == scalar else { throw ParseError(offset: index) }
        index += 1
      }
    }

    mutating func value() throws -> OrderedJSON {
      switch peek {
      case "{":
        index += 1
        var entries: [(key: String, value: OrderedJSON)] = []
        skipSpace()
        if peek == "}" {
          index += 1
          return .object(entries)
        }
        while true {
          skipSpace()
          let key = try string()
          skipSpace()
          try expect(":")
          skipSpace()
          entries.append((key, try value()))
          skipSpace()
          if peek == "," {
            index += 1
            continue
          }
          try expect("}")
          return .object(entries)
        }
      case "[":
        index += 1
        var items: [OrderedJSON] = []
        skipSpace()
        if peek == "]" {
          index += 1
          return .array(items)
        }
        while true {
          skipSpace()
          items.append(try value())
          skipSpace()
          if peek == "," {
            index += 1
            continue
          }
          try expect("]")
          return .array(items)
        }
      case "\"": return .string(try string())
      case "t":
        try expect("true")
        return .bool(true)
      case "f":
        try expect("false")
        return .bool(false)
      case "n":
        try expect("null")
        return .null
      default:
        let start = index
        while let c = peek, "+-0123456789.eE".unicodeScalars.contains(c) { index += 1 }
        guard index > start, Double(String(String.UnicodeScalarView(s[start..<index]))) != nil else { throw ParseError(offset: start) }
        return .number(String(String.UnicodeScalarView(s[start..<index])))
      }
    }

    mutating func string() throws -> String {
      try expect("\"")
      var out = String.UnicodeScalarView()
      while true {
        guard let c = peek else { throw ParseError(offset: index) }
        index += 1
        if c == "\"" { return String(out) }
        guard c == "\\" else {
          out.append(c)
          continue
        }
        guard let escape = peek else { throw ParseError(offset: index) }
        index += 1
        switch escape {
        case "\"": out.append("\"")
        case "\\": out.append("\\")
        case "/": out.append("/")
        case "n": out.append("\n")
        case "r": out.append("\r")
        case "t": out.append("\t")
        case "b": out.append("\u{08}")
        case "f": out.append("\u{0C}")
        case "u":
          var code = try hex4()
          // A surrogate pair.
          if (0xD800..<0xDC00).contains(code), peek == "\\" {
            index += 1
            try expect("u")
            let low = try hex4()
            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
          }
          guard let scalar = Unicode.Scalar(code) else { throw ParseError(offset: index) }
          out.append(scalar)
        default: throw ParseError(offset: index)
        }
      }
    }

    mutating func hex4() throws -> UInt32 {
      guard index + 4 <= s.count, let value = UInt32(String(String.UnicodeScalarView(s[index..<index + 4])), radix: 16) else {
        throw ParseError(offset: index)
      }
      index += 4
      return value
    }
  }
}

import CoreGraphics
import Foundation

/// SVG path data → `CGPath`, so the robots' outlines and the agents' marks come
/// from exactly the same geometry 1.x drew. Supports every path command
/// (M L H V C S Q T A Z, absolute and relative) and the compact number syntax
/// those files use (`.079-.2307`, `1.5.5`).
public enum SVGPath {
  public enum ParseError: Error, Equatable {
    case unexpected(Character)
    case missingNumber(Character)
  }

  public static func parse(_ data: String) throws -> CGPath {
    let path = CGMutablePath()
    var scanner = Scanner(Array(data.utf8))
    var current = CGPoint.zero
    var start = CGPoint.zero
    // The last control point, for the smooth commands' reflection.
    var lastCubic: CGPoint?
    var lastQuad: CGPoint?
    var command: UInt8 = 0

    while true {
      scanner.skipSeparators()
      guard let next = scanner.peek else { break }
      if next.isLetter {
        command = next
        scanner.index += 1
      } else if command == 0 {
        throw ParseError.unexpected(Character(UnicodeScalar(next)))
      }
      let relative = command.isLowercase
      let origin = relative ? current : .zero
      func point() throws -> CGPoint {
        let x = try scanner.number(for: command)
        let y = try scanner.number(for: command)
        return CGPoint(x: origin.x + x, y: origin.y + y)
      }

      switch command | 0x20 {  // lowercase
      case UInt8(ascii: "m"):
        current = try point()
        start = current
        path.move(to: current)
        // Pairs after a move are implicit lines.
        command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
        lastCubic = nil
        lastQuad = nil
        continue
      case UInt8(ascii: "l"):
        current = try point()
        path.addLine(to: current)
        lastCubic = nil
        lastQuad = nil
      case UInt8(ascii: "h"):
        current.x = origin.x + (try scanner.number(for: command))
        path.addLine(to: current)
        lastCubic = nil
        lastQuad = nil
      case UInt8(ascii: "v"):
        current.y = (relative ? current.y : 0) + (try scanner.number(for: command))
        path.addLine(to: current)
        lastCubic = nil
        lastQuad = nil
      case UInt8(ascii: "c"):
        let c1 = try point()
        let c2 = try point()
        current = try point()
        path.addCurve(to: current, control1: c1, control2: c2)
        lastCubic = c2
        lastQuad = nil
      case UInt8(ascii: "s"):
        let c1 = lastCubic.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
        let c2 = try point()
        current = try point()
        path.addCurve(to: current, control1: c1, control2: c2)
        lastCubic = c2
        lastQuad = nil
      case UInt8(ascii: "q"):
        let c = try point()
        current = try point()
        path.addQuadCurve(to: current, control: c)
        lastQuad = c
        lastCubic = nil
      case UInt8(ascii: "t"):
        let c = lastQuad.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
        current = try point()
        path.addQuadCurve(to: current, control: c)
        lastQuad = c
        lastCubic = nil
      case UInt8(ascii: "a"):
        let rx = try scanner.number(for: command)
        let ry = try scanner.number(for: command)
        let rotation = try scanner.number(for: command)
        let large = try scanner.flag(for: command)
        let sweep = try scanner.flag(for: command)
        let end = try point()
        addArc(to: path, from: current, to: end, rx: rx, ry: ry, degrees: rotation, large: large, sweep: sweep)
        current = end
        lastCubic = nil
        lastQuad = nil
      case UInt8(ascii: "z"):
        path.closeSubpath()
        current = start
        lastCubic = nil
        lastQuad = nil
        // Z takes no numbers; a number after it needs a new command.
        command = 0
      default:
        throw ParseError.unexpected(Character(UnicodeScalar(command)))
      }
    }
    return path
  }

  /// SVG's endpoint arc as cubic Béziers (the W3C implementation notes, F.6).
  static func addArc(
    to path: CGMutablePath, from p0: CGPoint, to p1: CGPoint,
    rx: CGFloat, ry: CGFloat, degrees: CGFloat, large: Bool, sweep: Bool
  ) {
    guard p0 != p1 else { return }
    var rx = abs(rx)
    var ry = abs(ry)
    guard rx > 0, ry > 0 else {
      path.addLine(to: p1)
      return
    }
    let phi = degrees * .pi / 180
    let (cosPhi, sinPhi) = (cos(phi), sin(phi))
    let dx = (p0.x - p1.x) / 2
    let dy = (p0.y - p1.y) / 2
    let x1 = cosPhi * dx + sinPhi * dy
    let y1 = -sinPhi * dx + cosPhi * dy

    // Radii too small to reach: scale them up just enough.
    let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
    if lambda > 1 {
      rx *= sqrt(lambda)
      ry *= sqrt(lambda)
    }
    let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
    var factor = sqrt(max(0, numerator / denominator))
    if large == sweep { factor = -factor }
    let cx1 = factor * rx * y1 / ry
    let cy1 = -factor * ry * x1 / rx
    let center = CGPoint(
      x: cosPhi * cx1 - sinPhi * cy1 + (p0.x + p1.x) / 2,
      y: sinPhi * cx1 + cosPhi * cy1 + (p0.y + p1.y) / 2
    )

    func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
      atan2(ux * vy - uy * vx, ux * vx + uy * vy)
    }
    let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
    var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
    if !sweep && delta > 0 { delta -= 2 * .pi }
    if sweep && delta < 0 { delta += 2 * .pi }

    // At most a quarter turn per Bézier keeps the error invisible.
    let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
    let step = delta / CGFloat(segments)
    let k = 4 / 3 * tan(step / 4)
    func onEllipse(_ t: CGFloat) -> CGPoint {
      let (x, y) = (rx * cos(t), ry * sin(t))
      return CGPoint(x: center.x + cosPhi * x - sinPhi * y, y: center.y + sinPhi * x + cosPhi * y)
    }
    func derivative(_ t: CGFloat) -> CGVector {
      let (x, y) = (-rx * sin(t), ry * cos(t))
      return CGVector(dx: cosPhi * x - sinPhi * y, dy: sinPhi * x + cosPhi * y)
    }
    var t = theta1
    for i in 0..<segments {
      let t2 = t + step
      let (a, b) = (onEllipse(t), i == segments - 1 ? p1 : onEllipse(t2))
      let (da, db) = (derivative(t), derivative(t2))
      path.addCurve(
        to: b,
        control1: CGPoint(x: a.x + k * da.dx, y: a.y + k * da.dy),
        control2: CGPoint(x: b.x - k * db.dx, y: b.y - k * db.dy)
      )
      t = t2
    }
  }

  private struct Scanner {
    let bytes: [UInt8]
    var index = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

    mutating func skipSeparators() {
      while let c = peek, c == UInt8(ascii: " ") || c == UInt8(ascii: ",") || c == 0x0A || c == 0x0D || c == 0x09 {
        index += 1
      }
    }

    /// An arc flag: a single 0 or 1, which may run straight into the next number.
    mutating func flag(for command: UInt8) throws -> Bool {
      skipSeparators()
      guard let c = peek, c == UInt8(ascii: "0") || c == UInt8(ascii: "1") else {
        throw ParseError.missingNumber(Character(UnicodeScalar(command)))
      }
      index += 1
      return c == UInt8(ascii: "1")
    }

    mutating func number(for command: UInt8) throws -> CGFloat {
      skipSeparators()
      let begin = index
      if let c = peek, c == UInt8(ascii: "-") || c == UInt8(ascii: "+") { index += 1 }
      var sawDot = false
      var sawDigit = false
      while let c = peek {
        if c.isDigit {
          sawDigit = true
          index += 1
        } else if c == UInt8(ascii: "."), !sawDot {
          sawDot = true
          index += 1
        } else {
          break
        }
      }
      if sawDigit, let c = peek, c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
        index += 1
        if let s = peek, s == UInt8(ascii: "-") || s == UInt8(ascii: "+") { index += 1 }
        while let d = peek, d.isDigit { index += 1 }
      }
      guard sawDigit, let value = Double(String(decoding: bytes[begin..<index], as: UTF8.self)) else {
        throw ParseError.missingNumber(Character(UnicodeScalar(command)))
      }
      return CGFloat(value)
    }
  }
}

extension UInt8 {
  fileprivate var isLetter: Bool { (65...90).contains(self) || (97...122).contains(self) }
  fileprivate var isLowercase: Bool { (97...122).contains(self) }
  fileprivate var isDigit: Bool { (48...57).contains(self) }
}

import CoreGraphics

/// The island's edge: it grows out of the bezel through two concave ears, runs
/// down its sides and rounds off at the bottom. The same outline as 1.x's
/// `islandOutline` (IslandGlow.tsx), so the body, the charge current and the
/// rim all follow one shape — never a box, never the top edge, which is the
/// bezel itself.
///
/// Coordinates are top-left origin, y down, in a box `ear` wider than the body
/// on each side: the left ear starts at (0, 0), the right one ends at
/// (`boxWidth`, 0).
public struct IslandOutline: Equatable, Sendable {
  /// Concave ear radius where the island meets the bezel.
  public static let earRadius: CGFloat = 10
  /// Bottom corner radius, collapsed and expanded.
  public static let collapsedCorner: CGFloat = 12
  public static let expandedCorner: CGFloat = 16

  /// The body's width, ears excluded.
  public var width: CGFloat
  public var height: CGFloat
  public var corner: CGFloat
  public var ear: CGFloat

  public init(width: CGFloat, height: CGFloat, corner: CGFloat, ear: CGFloat = earRadius) {
    self.width = max(0, width)
    self.height = max(0, height)
    self.corner = corner
    self.ear = ear
  }

  public var boxWidth: CGFloat { width + 2 * ear }

  /// Corner radius after clamping to the body, so a short island stays a pill.
  var radius: CGFloat { max(0, min(corner, width / 2, height / 2)) }

  enum Segment: Equatable {
    case line(from: CGPoint, to: CGPoint)
    /// Angles in radians, y down (so increasing angle turns clockwise on screen).
    case arc(center: CGPoint, radius: CGFloat, start: CGFloat, end: CGFloat)

    var length: CGFloat {
      switch self {
      case let .line(a, b): hypot(b.x - a.x, b.y - a.y)
      case let .arc(_, r, start, end): r * abs(end - start)
      }
    }

    func point(at t: CGFloat) -> CGPoint {
      switch self {
      case let .line(a, b):
        return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
      case let .arc(c, r, start, end):
        let angle = start + (end - start) * t
        return CGPoint(x: c.x + r * cos(angle), y: c.y + r * sin(angle))
      }
    }

    /// Unit direction of travel at `t`.
    func tangent(at t: CGFloat) -> CGVector {
      switch self {
      case let .line(a, b):
        let length = max(hypot(b.x - a.x, b.y - a.y), .ulpOfOne)
        return CGVector(dx: (b.x - a.x) / length, dy: (b.y - a.y) / length)
      case let .arc(_, _, start, end):
        let angle = start + (end - start) * t
        let sign: CGFloat = end >= start ? 1 : -1
        return CGVector(dx: -sin(angle) * sign, dy: cos(angle) * sign)
      }
    }
  }

  /// Left ear → left side → bottom → right side → right ear.
  var segments: [Segment] {
    let r = radius
    let x0 = ear
    let x1 = ear + width
    let h = height
    let half = CGFloat.pi / 2
    return [
      .arc(center: CGPoint(x: 0, y: ear), radius: ear, start: -half, end: 0),
      .line(from: CGPoint(x: x0, y: ear), to: CGPoint(x: x0, y: h - r)),
      .arc(center: CGPoint(x: x0 + r, y: h - r), radius: r, start: .pi, end: half),
      .line(from: CGPoint(x: x0 + r, y: h), to: CGPoint(x: x1 - r, y: h)),
      .arc(center: CGPoint(x: x1 - r, y: h - r), radius: r, start: half, end: 0),
      .line(from: CGPoint(x: x1, y: h - r), to: CGPoint(x: x1, y: ear)),
      .arc(center: CGPoint(x: x1 + ear, y: ear), radius: ear, start: .pi, end: .pi + half),
    ]
  }

  public var length: CGFloat { segments.reduce(0) { $0 + $1.length } }

  /// The open edge, ear to ear.
  public func edge() -> CGPath {
    let path = CGMutablePath()
    path.move(to: .zero)
    for segment in segments {
      switch segment {
      case let .line(_, to):
        path.addLine(to: to)
      case let .arc(center, radius, start, end):
        // A zero radius (a degenerate pill) is just the corner point.
        guard radius > 0 else { continue }
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: end < start)
      }
    }
    return path
  }

  /// The edge closed along the bezel: the island's whole silhouette.
  public func silhouette() -> CGPath {
    let path = CGMutablePath()
    path.addPath(edge())
    path.closeSubpath()
    return path
  }

  /// The point `fraction` (0…1) of the way along the edge, and the outward normal there.
  public func sample(at fraction: CGFloat) -> (point: CGPoint, normal: CGVector) {
    var remaining = min(max(fraction, 0), 1) * length
    let all = segments
    for segment in all {
      let length = segment.length
      if remaining <= length || segment == all.last {
        let t = length > 0 ? min(remaining / length, 1) : 0
        let tangent = segment.tangent(at: t)
        // Travel runs down the left side, along the bottom and up the right
        // (y down): outward is the tangent turned a quarter clockwise.
        return (segment.point(at: t), CGVector(dx: -tangent.dy, dy: tangent.dx))
      }
      remaining -= length
    }
    return (.zero, CGVector(dx: 0, dy: -1))
  }

  /// The edge as a live wire: points every `spacing` pt, each pushed along its
  /// normal by up to ±`amplitude`/2. A different `seed` crackles differently;
  /// the same seed always draws the same wire. 1.x did this with a reseeding
  /// `feDisplacementMap`; here it's a handful of precomputed paths.
  public func crackled(seed: UInt64, amplitude: CGFloat, spacing: CGFloat = 3) -> CGPath {
    var random = SplitMix64(seed: seed)
    let count = max(2, Int((length / max(spacing, 0.5)).rounded(.up)))
    let path = CGMutablePath()
    for i in 0...count {
      let (point, normal) = sample(at: CGFloat(i) / CGFloat(count))
      // The ends stay put, so the wire stays attached to the bezel.
      let shove = i == 0 || i == count ? 0 : (CGFloat(random.unit()) - 0.5) * amplitude
      let moved = CGPoint(x: point.x + normal.dx * shove, y: point.y + normal.dy * shove)
      if i == 0 { path.move(to: moved) } else { path.addLine(to: moved) }
    }
    return path
  }
}

/// A tiny seeded generator, so a crackle is reproducible (and testable).
public struct SplitMix64: RandomNumberGenerator, Sendable {
  private var state: UInt64

  public init(seed: UInt64) { state = seed }

  public mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// Uniform in 0..<1.
  mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

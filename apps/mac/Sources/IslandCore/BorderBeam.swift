import Foundation

// The motion behind 1.x's field glow: the `border-beam` package (1.4.1) with
// FieldBeam's props — `sunset`, `staticColors`, `theme="dark"`, radius 14.
// Typing gets `pulse-inner` (a glow breathing in place, driven by the
// package's shared 30 fps oscillator loop); a submitted question that's still
// waiting gets `line` (a glow travelling the bottom edge, driven by CSS
// keyframes). The numbers are the package's own, read from its source.

public enum BeamMotion {
  /// The oscillators' values at one instant (`pulse-inner`, dark, 2.3 s).
  public struct Pulse: Equatable, Sendable {
    /// Width and height scales for the three ellipse groups.
    public var w: [Double]
    public var h: [Double]
    /// Drift, in points, for the three groups.
    public var dx: [Double]
    public var dy: [Double]
    /// Overall glow height.
    public var height: Double
    /// Per-corner opacity: top-left, top-right, bottom-left, bottom-right.
    public var tl, tr, bl, br: Double
  }

  /// `(1 - cos 2πs) / 2`: 0 → 1 → 0 across one period.
  static func wave(_ s: Double) -> Double { (1 - cos(2 * .pi * s)) / 2 }

  static func oscillate(_ t: Double, from a: Double, to b: Double, period: Double, delay: Double = 0) -> Double {
    a + (b - a) * wave((t - delay) / period)
  }

  /// `t` is seconds on any clock; the package runs it off the page's clock.
  public static func pulse(at t: Double) -> Pulse {
    let sp = 0.28, dr = 33.0, op = 0.48, gh = 0.34, bs = 1.9, ss = 2.6, ghs = 2.4
    func o(_ a: Double, _ b: Double, _ period: Double, _ delay: Double = 0) -> Double {
      oscillate(t, from: a, to: b, period: period, delay: delay)
    }
    return Pulse(
      w: [o(1 - sp, 1 + sp * 1.1, ss * 0.9), o(1 + sp, 1 - sp * 0.85, ss * 1.1), o(1 - sp * 0.6, 1 + sp * 1.15, ss * 0.98)],
      h: [o(1 + sp * 0.9, 1 - sp * 0.85, ss * 1.26), o(1 - sp * 0.8, 1 + sp * 1.05, ss * 0.81), o(1 + sp * 0.75, 1 - sp, ss * 1.4)],
      dx: [o(-dr, dr * 0.9, bs * 1.6), o(dr * 0.8, -dr * 0.9, bs * 1.88), o(-dr * 0.6, dr, bs * 1.45)],
      dy: [o(dr * 0.55, -dr * 0.7, bs * 1.6), o(-dr, dr * 0.65, bs * 1.88), o(-dr * 0.85, dr * 0.45, bs * 1.45)],
      height: o(1 - gh, 1 + gh, ghs),
      tl: o(1 - op, 1, bs),
      tr: o(1 - op, 1, bs * 1.32, bs * 0.28),
      bl: o(1 - op, 1, bs * 0.84, bs * 0.55),
      br: o(1 - op, 1, bs * 1.58, bs * 0.83)
    )
  }

  /// The travelling line's values, `t` seconds after it started.
  public struct Line: Equatable, Sendable {
    /// Where the glow is along the bottom edge, 0…1.
    public var x: Double
    /// Its width and height scales.
    public var w: Double
    public var h: Double
    /// Fades it in off the left end and out at the right.
    public var edge: Double
    /// The flicker of the spikes.
    public var spike: Double
    public var spike2: Double
  }

  public static func line(at t: Double) -> Line {
    let travel = fraction(t, 3.1)
    return Line(
      x: Keyframes.linear(travel, [(0, 0.06), (0.1, 0.15), (0.2, 0.25), (0.3, 0.35), (0.4, 0.44), (0.5, 0.5), (0.6, 0.56), (0.7, 0.65), (0.8, 0.75), (0.9, 0.85), (1, 0.94)]),
      w: Keyframes.linear(travel, [(0, 0.5), (0.1, 0.8), (0.2, 1.1), (0.3, 1.3), (0.4, 1.45), (0.5, 1.5), (0.6, 1.45), (0.7, 1.3), (0.8, 1.1), (0.9, 0.8), (1, 0.5)]),
      h: Keyframes.easeInOut(fraction(t, 4.0), [(0, 0.8), (0.25, 1.25), (0.55, 0.85), (0.8, 1.3), (1, 0.8)]),
      edge: Keyframes.linear(travel, [(0, 0), (0.125, 0), (0.325, 1), (0.675, 1), (0.875, 0), (1, 0)]),
      spike: Keyframes.easeInOut(fraction(t, 4.1), [(0, 0.8), (0.25, 1.3), (0.5, 0.9), (0.75, 1.4), (1, 0.8)]),
      spike2: Keyframes.easeInOut(fraction(t, 5.3), [(0, 1.2), (0.25, 0.7), (0.5, 1.4), (0.75, 0.8), (1, 1.2)])
    )
  }

  static func fraction(_ t: Double, _ period: Double) -> Double {
    let f = (t / period).truncatingRemainder(dividingBy: 1)
    return f < 0 ? f + 1 : f
  }
}

/// CSS `@keyframes` sampling: each segment runs the animation's timing function.
enum Keyframes {
  static func linear(_ p: Double, _ stops: [(Double, Double)]) -> Double {
    sample(p, stops) { $0 }
  }

  static func easeInOut(_ p: Double, _ stops: [(Double, Double)]) -> Double {
    sample(p, stops) { CubicBezier.easeInOut($0) }
  }

  static func sample(_ p: Double, _ stops: [(Double, Double)], timing: (Double) -> Double) -> Double {
    guard let first = stops.first, let last = stops.last else { return 0 }
    if p <= first.0 { return first.1 }
    if p >= last.0 { return last.1 }
    for (a, b) in zip(stops, stops.dropFirst()) where p <= b.0 {
      let local = b.0 > a.0 ? (p - a.0) / (b.0 - a.0) : 1
      return a.1 + (b.1 - a.1) * timing(local)
    }
    return last.1
  }
}

/// A CSS `cubic-bezier()` timing function.
public struct CubicBezier: Sendable {
  let x1, y1, x2, y2: Double

  public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
    self.x1 = x1
    self.y1 = y1
    self.x2 = x2
    self.y2 = y2
  }

  public static let easeInOutCurve = CubicBezier(0.42, 0, 0.58, 1)

  static func easeInOut(_ x: Double) -> Double { easeInOutCurve.y(at: x) }

  private func bezier(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
    let u = 1 - t
    return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
  }

  /// y for a given x, by bisection (the curve is monotonic in x).
  public func y(at x: Double) -> Double {
    guard x > 0 else { return 0 }
    guard x < 1 else { return 1 }
    var lo = 0.0, hi = 1.0
    for _ in 0..<40 {
      let mid = (lo + hi) / 2
      if bezier(mid, x1, x2) < x { lo = mid } else { hi = mid }
    }
    return bezier((lo + hi) / 2, y1, y2)
  }
}

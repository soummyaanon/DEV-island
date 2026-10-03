import IslandCore
import SwiftUI

/// The weather as a tiny living scene: ten conditions, hand-placed elements,
/// transform-and-opacity motion only (1.x's WeatherScene.tsx and weather.css),
/// drawn in one canvas on one clock. `ambient` is the strip beside the notch;
/// `card` the panel's. Decorative: the summary text carries the meaning.
struct WeatherScene: View {
  enum Variant { case ambient, card }

  let condition: WeatherCondition
  let variant: Variant
  var paused = false

  var body: some View {
    // A new condition is a new scene, so its one-shot motion (the rainbow
    // fading in, the first bolt) replays, as 1.x's remount does.
    WeatherCanvas(condition: condition, variant: variant, paused: paused)
      .id(condition)
      .frame(width: variant == .ambient ? 46 : nil, height: variant == .ambient ? 14 : 46)
      .clipShape(RoundedRectangle(cornerRadius: variant == .ambient ? 5 : 9))
      .accessibilityHidden(true)
  }
}

private struct WeatherCanvas: View {
  let condition: WeatherCondition
  let variant: WeatherScene.Variant
  let paused: Bool
  /// When this scene appeared, for the motion that plays once per mount.
  private let mounted = State(initialValue: Date.now)

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.motionFrameRate) private var frameRate

  var body: some View {
    let increased = contrast == .increased
    // Paused holds the current frame (1.x's `animation-play-state: paused`);
    // Reduce Motion swaps in a still illustration instead.
    TimelineView(.animation(minimumInterval: 1 / frameRate, paused: paused || reduceMotion)) { timeline in
      let now = timeline.date
      Canvas { context, size in
        WeatherPainter(
          condition: condition,
          orb: variant == .card ? 30 : 10,
          card: variant == .card,
          t: now.timeIntervalSinceReferenceDate,
          age: now.timeIntervalSince(mounted.wrappedValue),
          still: reduceMotion,
          contrast: increased
        )
        .paint(&context, size)
      }
    }
    .saturation(increased ? 0.55 : 1)
    .overlay {
      // Text sits over the card, so at high contrast the scene dims hard.
      if increased, variant == .card { Color.black.opacity(0.55) }
    }
  }
}

nonisolated struct WeatherPainter {
  let condition: WeatherCondition
  let orb: CGFloat
  let card: Bool
  /// Seconds on the shared clock.
  let t: Double
  /// Seconds since the scene appeared.
  let age: Double
  /// Reduce Motion: every scene a still illustration.
  let still: Bool
  /// Increase Contrast: fewer drops, flakes and stars.
  var contrast = false

  static let easeInOut = CubicBezier.easeInOutCurve
  static let easeOut = CubicBezier(0, 0, 0.58, 1)

  /// CSS `ease-in-out infinite alternate`: 0 → 1 → 0 over two periods.
  /// A positive `delay` lags, like `animation-delay`.
  private func alternate(_ period: Double, delay: Double = 0) -> Double {
    var x = ((t - delay) / period).truncatingRemainder(dividingBy: 2)
    if x < 0 { x += 2 }
    return Self.easeInOut.y(at: x < 1 ? x : 2 - x)
  }

  /// CSS `linear infinite`: 0…1 over `period`, looping.
  private func loop(_ period: Double, delay: Double = 0) -> Double {
    let x = ((t - delay) / period).truncatingRemainder(dividingBy: 1)
    return x < 0 ? x + 1 : x
  }

  func paint(_ context: inout GraphicsContext, _ size: CGSize) {
    let rect = CGRect(origin: .zero, size: size)
    context.fill(Path(rect), with: .linearGradient(Gradient(colors: sky.map { Color(hex: $0) }), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
    switch condition {
    case .clearDay: sun(&context, center: CGPoint(x: size.width / 2, y: size.height / 2), diameter: orb)
    case .clearNight: moonAndStars(&context, size)
    case .cloudy: clouds(&context, size, dark: false)
    case .fog: fog(&context, size)
    case .rain:
      clouds(&context, size, dark: true)
      rain(&context, size)
    case .snow:
      clouds(&context, size, dark: false)
      snow(&context, size)
    case .thunder: thunder(&context, size)
    case .sunrise, .sunset: golden(&context, size, rising: condition == .sunrise)
    case .rainbow: rainbow(&context, size)
    }
  }

  private var sky: [UInt32] {
    switch condition {
    case .clearDay: [0x3F7FD0, 0x78B4EC]
    case .clearNight: [0x0A1130, 0x1D2B57]
    case .cloudy: [0x55606E, 0x808B98]
    case .fog: [0x6B7078, 0x9AA0A7]
    case .rain: [0x37414F, 0x5B6875]
    case .snow: [0x5D6879, 0x93A0B1]
    case .thunder: [0x23262F, 0x3D4350]
    case .sunrise: [0x2B3F6B, 0xF2A45C]
    case .sunset: [0x43356B, 0xF0764F]
    case .rainbow: [0x4A83C4, 0x9FC9EA]
    }
  }

  // MARK: Layers

  private func sun(_ ctx: inout GraphicsContext, center: CGPoint, diameter d: CGFloat) {
    let disc = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)
    // `circle at 42% 38%`, sized to the farthest corner.
    let focus = CGPoint(x: disc.minX + d * 0.42, y: disc.minY + d * 0.38)
    var glow = ctx
    glow.opacity = still ? 1 : 0.86 + 0.14 * alternate(5)
    glow.fill(Path(ellipseIn: disc), with: .radialGradient(
      Gradient(stops: [.init(color: Color(hex: 0xFFF6D0), location: 0), .init(color: Color(hex: 0xFFD257), location: 0.58), .init(color: Color(hex: 0xF7A933), location: 1)]),
      center: focus, startRadius: 0, endRadius: hypot(d * 0.58, d * 0.62)
    ))
    // Rays over the disc: eight thin spokes, turning once a minute.
    var rays = ctx
    rays.translateBy(x: center.x, y: center.y)
    rays.rotate(by: .degrees(still ? 0 : loop(60) * 360))
    let r = d / 2 * 1.55
    for i in 0..<8 {
      let start = Angle.degrees(Double(i) * 45 - 90)
      var wedge = Path()
      wedge.move(to: .zero)
      wedge.addArc(center: .zero, radius: r, startAngle: start, endAngle: start + .degrees(6), clockwise: false)
      wedge.closeSubpath()
      rays.fill(wedge, with: .color(Color(red: 1, green: 226 / 255, blue: 138 / 255, opacity: 0.55)))
    }
  }

  private func moonAndStars(_ ctx: inout GraphicsContext, _ size: CGSize) {
    // A crescent: the disc, less a circle centred at (118%, 32%) whose radius
    // is 52% of the gradient's farthest-corner reach.
    let disc = CGRect(x: size.width / 2 - orb / 2, y: size.height / 2 - orb / 2, width: orb, height: orb)
    let cut = CGPoint(x: disc.minX + orb * 1.18, y: disc.minY + orb * 0.32)
    let cutRadius = 0.52 * hypot(orb * 1.18, orb * 0.68)
    var moon = ctx
    moon.clip(to: Path(ellipseIn: disc))
    var crescent = Path(ellipseIn: disc)
    crescent.addEllipse(in: CGRect(x: cut.x - cutRadius, y: cut.y - cutRadius, width: cutRadius * 2, height: cutRadius * 2))
    moon.fill(crescent, with: .color(Color(hex: 0xF2F3E0)), style: FillStyle(eoFill: true))

    let stars: [(Double, Double, Double)] = [(12, 22, 0), (27, 58, 1.4), (41, 30, 0.7), (55, 66, 2.1), (68, 24, 1.1), (81, 52, 2.8), (92, 34, 0.4)]
    for (x, y, delay) in stars.prefix(contrast ? 3 : stars.count) {
      let p = CGPoint(x: size.width * x / 100, y: size.height * y / 100)
      let opacity = still ? 0.7 : 0.2 + 0.75 * alternate(3.4, delay: delay)
      ctx.fill(Path(ellipseIn: CGRect(x: p.x, y: p.y, width: 1.5, height: 1.5)), with: .color(.white.opacity(opacity)))
    }
  }

  private func clouds(_ ctx: inout GraphicsContext, _ size: CGSize, dark: Bool) {
    let clouds: [(x: Double, y: Double, scale: Double, dur: Double, delay: Double)] = [(-20, 18, 1, 54, 0), (30, 46, 0.72, 68, -22), (70, 26, 0.86, 61, -44)]
    let fill = dark ? Color(red: 190 / 255, green: 199 / 255, blue: 212 / 255, opacity: 0.5) : .white.opacity(0.82)
    for cloud in clouds {
      let w = 28 * cloud.scale, h = 11 * cloud.scale
      let drift = still ? 0 : -40 + 180 * loop(cloud.dur, delay: cloud.delay)
      let origin = CGPoint(x: size.width * cloud.x / 100 + drift, y: size.height * cloud.y / 100)
      // The slab, then the bump on top as its own layer, so the overlap
      // stacks the way two translucent elements do.
      ctx.fill(Path(roundedRect: CGRect(x: origin.x, y: origin.y, width: w, height: h), cornerRadius: h / 2), with: .color(fill))
      ctx.fill(Path(ellipseIn: CGRect(x: origin.x + w * 0.26, y: origin.y + h - h * 0.42 - h * 1.16, width: w * 0.52, height: h * 1.16)), with: .color(fill))
    }
  }

  private func rain(_ ctx: inout GraphicsContext, _ size: CGSize) {
    let drops: [(Double, Double, Double)] = [(6, 0, 0.72), (17, 0.31, 0.66), (28, 0.12, 0.79), (39, 0.54, 0.7), (48, 0.24, 0.63), (58, 0.44, 0.75), (69, 0.06, 0.68), (78, 0.36, 0.72), (87, 0.18, 0.61), (12, 0.62, 0.77), (63, 0.68, 0.65), (93, 0.49, 0.71)]
    // Only the leading drops when still (a static crowd looks like noise) or
    // at high contrast.
    let shown = contrast ? 4 : still ? 6 : drops.count
    for (x, delay, dur) in drops.prefix(shown) {
      let p = loop(dur, delay: delay)
      let offset: CGPoint = still ? CGPoint(x: 0, y: 16) : CGPoint(x: -4 * p, y: -6 + 58 * p)
      let left = size.width * x / 100 + offset.x
      let top = -6 + offset.y
      ctx.fill(
        Path(roundedRect: CGRect(x: left, y: top, width: 1, height: 6), cornerRadius: 0.5),
        with: .linearGradient(Gradient(colors: [Color(red: 200 / 255, green: 224 / 255, blue: 1, opacity: 0), Color(red: 200 / 255, green: 224 / 255, blue: 1, opacity: 0.95)]), startPoint: CGPoint(x: left, y: top), endPoint: CGPoint(x: left, y: top + 6))
      )
    }
  }

  private func snow(_ ctx: inout GraphicsContext, _ size: CGSize) {
    let flakes: [(Double, Double, Double, Double)] = [(8, 0, 3.1, 3), (22, 0.9, 3.8, 2), (34, 1.9, 3.4, 3), (46, 0.5, 4.1, 2), (57, 2.4, 3.2, 3), (68, 1.3, 3.9, 2), (79, 2.9, 3.5, 3), (90, 0.7, 4.2, 2), (15, 3.3, 3.6, 2)]
    let shown = contrast ? 3 : still ? 4 : flakes.count
    for (x, delay, dur, d) in flakes.prefix(shown) {
      let p = loop(dur, delay: delay)
      // Flutter: side to side as it falls.
      let sway: Double = switch p {
      case ..<0.25: 4 * p / 0.25
      case ..<0.5: 4 - 7 * (p - 0.25) / 0.25
      case ..<0.75: -3 + 6 * (p - 0.5) / 0.25
      default: 3 - 3 * (p - 0.75) / 0.25
      }
      let offset: CGPoint = still ? CGPoint(x: 0, y: 18) : CGPoint(x: sway, y: -4 + 56 * p)
      ctx.fill(Path(ellipseIn: CGRect(x: size.width * x / 100 + offset.x, y: -4 + offset.y, width: d, height: d)), with: .color(.white.opacity(0.94)))
    }
  }

  /// Clouds most of the time, a triple-stab flash every 6–14 s: irregular
  /// reads as weather, a metronome as a broken UI. The scene opens on a bolt
  /// without the flash; under Reduce Motion the bolt just stays.
  private func thunder(_ ctx: inout GraphicsContext, _ size: CGSize) {
    clouds(&ctx, size, dark: true)
    var flash = 0.0, bolt = 0.0
    if still {
      bolt = 1
    } else if age < 0.62 {
      bolt = Self.boltKeys(age / 0.62)
    } else if let strike = Self.lastStrike(before: t), strike > t - age {
      let p = (t - strike) / 0.62
      if p < 1 {
        flash = Self.keyed(p, [(0, 0), (0.04, 0.92), (0.12, 0.08), (0.22, 0.78), (0.34, 0.05), (0.46, 0.55), (0.7, 0.02), (1, 0)])
        bolt = Self.boltKeys(p)
      }
    }
    if flash > 0 {
      ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0xFDFBE8).opacity(flash)))
    }
    guard bolt > 0 else { return }
    let box = CGRect(x: size.width * 0.39, y: size.height * 0.34, width: size.width * 0.22, height: size.height * 0.52)
    let scale = min(box.width / 12, box.height / 20)
    var ctx2 = ctx
    ctx2.translateBy(x: box.midX - 6 * scale, y: box.midY - 10 * scale)
    ctx2.scaleBy(x: scale, y: scale)
    var path = Path()
    path.addLines([CGPoint(x: 7.2, y: 0), CGPoint(x: 1, y: 11), CGPoint(x: 4.4, y: 11), CGPoint(x: 3.4, y: 20), CGPoint(x: 10.6, y: 8), CGPoint(x: 7, y: 8)])
    path.closeSubpath()
    ctx2.fill(path, with: .color(Color(hex: 0xFFE98A).opacity(bolt)))
  }

  static func boltKeys(_ p: Double) -> Double {
    keyed(p, [(0, 0), (0.06, 1), (0.24, 0.15), (0.4, 0.9), (0.62, 0), (1, 0)])
  }

  /// The strike at or before `t`. One per 10 s slot, jittered ±2 s by a
  /// seeded hash of the slot, so gaps run 6–14 s and every clock agrees.
  static func lastStrike(before t: Double) -> Double? {
    func strike(_ slot: Double) -> Double {
      var random = SplitMix64(seed: UInt64(bitPattern: Int64(slot)))
      return slot * 10 + 4 * Double(random.next() >> 11) / Double(1 << 53) - 2
    }
    let slot = (t / 10).rounded(.down)
    for candidate in [slot + 1, slot, slot - 1] where strike(candidate) <= t {
      return strike(candidate)
    }
    return nil
  }

  private func fog(_ ctx: inout GraphicsContext, _ size: CGSize) {
    for (top, dur, reverse) in [(0.26, 26.0, false), (0.56, 38.0, true)] {
      var p = loop(dur)
      if reverse { p = 1 - p }
      let shift = still ? 0 : -0.18 + 0.36 * p
      let x = -size.width * 0.5 + size.width * 2 * shift
      let band = CGRect(x: x, y: size.height * top, width: size.width * 2, height: size.height * 0.34)
      ctx.fill(Path(band), with: .linearGradient(
        Gradient(stops: [.init(color: .white.opacity(0), location: 0), .init(color: .white.opacity(0.42), location: 0.3), .init(color: .white.opacity(0.42), location: 0.7), .init(color: .white.opacity(0), location: 1)]),
        startPoint: CGPoint(x: band.minX, y: 0), endPoint: CGPoint(x: band.maxX, y: 0)
      ))
    }
  }

  /// Two static skies cross-fading, and a sun on the horizon.
  private func golden(_ ctx: inout GraphicsContext, _ size: CGSize, rising: Bool) {
    let u = alternate(9)
    let rect = CGRect(origin: .zero, size: size)
    var a = ctx
    a.opacity = still ? 1 : 1 - 0.75 * u
    a.fill(Path(rect), with: .linearGradient(Gradient(colors: [Color(red: 43 / 255, green: 63 / 255, blue: 107 / 255, opacity: 0.9), Color(red: 242 / 255, green: 164 / 255, blue: 92 / 255, opacity: 0.2)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
    var b = ctx
    b.opacity = still ? 0.7 : u
    b.fill(Path(rect), with: .linearGradient(Gradient(colors: [Color(red: 120 / 255, green: 70 / 255, blue: 130 / 255, opacity: 0.55), Color(red: 1, green: 196 / 255, blue: 120 / 255, opacity: 0.55)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
    let lift = still ? 0 : rising ? 6 - 11 * u : -5 + 11 * u
    let disc = CGRect(x: size.width / 2 - orb / 2, y: size.height + orb / 3 - orb + lift, width: orb, height: orb)
    ctx.fill(Path(ellipseIn: disc), with: .radialGradient(
      Gradient(stops: [.init(color: Color(hex: 0xFFF1C4), location: 0), .init(color: Color(hex: 0xFFB457), location: 0.6), .init(color: Color(hex: 0xF8813C), location: 1)]),
      center: CGPoint(x: disc.midX, y: disc.midY), startRadius: 0, endRadius: orb / 2 * 2.squareRoot()
    ))
  }

  /// A low sun, and over it six bands (red outside, violet in) that fade in
  /// each time the scene appears.
  private func rainbow(_ ctx: inout GraphicsContext, _ size: CGSize) {
    sun(&ctx, center: CGPoint(x: size.width * 0.14, y: size.height * 0.66), diameter: orb * 0.62)
    let bands: [UInt32] = [0xFF5F56, 0xFFB020, 0xFFE66D, 0x4ECB8D, 0x5BA8FF, 0xA98CFF]
    let eased = still ? 1 : Self.easeOut.y(at: min(1, age / 2.6))
    var arcs = ctx
    arcs.opacity = 0.92 * eased
    let sx = size.width / 100, sy = size.height / 46
    let scale = 0.94 + 0.06 * eased
    arcs.translateBy(x: size.width / 2, y: size.height / 2)
    arcs.scaleBy(x: scale, y: scale)
    arcs.translateBy(x: -size.width / 2, y: -size.height / 2)
    for (i, color) in bands.enumerated() {
      let rx = (46 - Double(i) * 5) * sx, ry = (40 - Double(i) * 5) * sy
      var arc = Path()
      arc.addArc(center: .zero, radius: 1, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
      let transform = CGAffineTransform(translationX: 50 * sx, y: 46 * sy).scaledBy(x: rx, y: ry)
      arcs.stroke(arc.applying(transform), with: .color(Color(hex: color)), lineWidth: card ? 2.4 : 1)
    }
  }

  /// CSS keyframes under `ease-out`: each segment runs the timing function.
  static func keyed(_ p: Double, _ keys: [(Double, Double)]) -> Double {
    for (a, b) in zip(keys, keys.dropFirst()) where p <= b.0 {
      let local = (p - a.0) / max(b.0 - a.0, .ulpOfOne)
      return a.1 + (b.1 - a.1) * easeOut.y(at: local)
    }
    return keys.last?.1 ?? 0
  }
}

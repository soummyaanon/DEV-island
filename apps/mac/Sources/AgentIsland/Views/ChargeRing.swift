import IslandCore
import SwiftUI

/// The left wing's half of the charger moment. Plugging in: a bolt strikes
/// the ring big and white-hot, lands, throws sparks, and the arc refills from
/// empty. Pulling the plug runs it backwards: the arc drains from full and the
/// bolt flares once and lets go. Colour and temper follow the Energy Mode.
struct ChargeRing: View {
  let moment: PowerActivity
  let percent: Int

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let size: CGFloat = 22

  private var plugged: Bool { moment.kind == .plugged }
  private var target: Double { max(0.04, Double(min(100, max(0, percent))) / 100) }

  /// Sparks thrown off the ring when the bolt lands; Low Power throws none.
  private var sparks: Int {
    guard plugged else { return 0 }
    return switch moment.energyMode {
    case .automatic: 6
    case .low: 0
    case .high: 10
    }
  }

  var body: some View {
    let color = Palette.charge(moment)
    let scale = Self.size / 16
    ZStack {
      ChargeFill(
        from: plugged ? 0 : 1, to: target, plugged: plugged, still: reduceMotion,
        lineWidth: 2 * scale, color: color
      )
      .frame(width: 6.2 * 2 * scale, height: 6.2 * 2 * scale)
      if !(reduceMotion && !plugged) {
        Bolt()
          .fill(.white)
          .modifier(Flicker(active: !reduceMotion))
          .modifier(BoltMotion(
            plugged: plugged, calm: moment.energyMode == .low, still: reduceMotion, color: color, unit: scale
          ))
      }
      if sparks > 0 && !reduceMotion {
        Sparks(count: sparks, color: color, fast: moment.energyMode == .high)
          .frame(width: Self.size * 28 / 16, height: Self.size * 28 / 16)
      }
    }
    .frame(width: Self.size, height: Self.size)
    .shadow(color: color.opacity(0.7), radius: 3)
    // `.la-battery`: the track is the text colour, not the wing's tint.
    .foregroundStyle(Palette.text)
  }
}

/// The arc waits out the wing's pop-in, then fills from empty (plugged) or
/// drains from full (unplugged) to the real level. Played once, on appear.
private struct ChargeFill: View {
  let from: Double
  let to: Double
  let plugged: Bool
  let still: Bool
  let lineWidth: CGFloat
  let color: Color

  var body: some View {
    // Keyframe closures run off the main actor: they get plain values, not `self`.
    let (from, to, lineWidth, color) = (from, to, lineWidth, color)
    let curve = plugged
      ? UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.22, y: 1), endControlPoint: UnitPoint(x: 0.36, y: 1))
      : UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.4, y: 0), endControlPoint: UnitPoint(x: 0.2, y: 1))
    if still {
      RingArc(fill: to, lineWidth: lineWidth, color: color, track: AnyShapeStyle(.foreground.opacity(0.18)))
    } else {
      Color.clear.keyframeAnimator(initialValue: from, repeating: false) { _, fill in
        RingArc(fill: fill, lineWidth: lineWidth, color: color, track: AnyShapeStyle(.foreground.opacity(0.18)))
      } keyframes: { _ in
        LinearKeyframe(from, duration: 0.2)
        LinearKeyframe(to, duration: 1.3, timingCurve: curve)
      }
    }
  }
}

/// The bolt at one instant: its transform, and its two stacked drop-shadows.
nonisolated private struct BoltPose {
  var scale: Double = 1
  /// `translateY` inside the scale, in the ring's 16-unit box.
  var lift: Double = 0
  var opacity: Double = 1
  /// The first shadow's blur, and how far it has gone from the charge colour to white.
  var blur: Double = 1.5
  var white: Double = 0
  /// The second shadow, charge-coloured, faded in from nothing.
  var halo: Double = 0

  static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

  /// Where `t` (0…1) falls among `stops`, eased per segment the way CSS does.
  static func segment(_ t: Double, _ stops: [Double], _ curve: CubicBezier) -> (index: Int, eased: Double) {
    for i in 1..<stops.count where t <= stops[i] {
      let span = stops[i] - stops[i - 1]
      return (i - 1, curve.y(at: span > 0 ? (t - stops[i - 1]) / span : 1))
    }
    return (stops.count - 2, 1)
  }

  /// 1.x's `bolt-strike`: in big and white-hot from above, lands, overshoots
  /// once, settles with a glow in the charge colour.
  static func strike(_ t: Double, curve: CubicBezier) -> BoltPose {
    var pose = BoltPose()
    let scales = [2.6, 1.7, 0.85, 1.12, 1]
    let (i, e) = segment(t, [0, 0.18, 0.45, 0.7, 1], curve)
    pose.scale = mix(scales[i], scales[i + 1], e)
    let (j, f) = segment(t, [0, 0.18, 1], curve)
    if j == 0 {
      pose.lift = mix(-3, 0, f)
      pose.opacity = f
      pose.blur = mix(1.5, 4, f)
      pose.white = f
      pose.halo = f
    } else {
      pose.blur = mix(4, 1.5, f)
      pose.white = 1 - f
      pose.halo = 1 - f
    }
    return pose
  }

  /// 1.x's `bolt-release`: a last white flare, then it shrinks away.
  static func release(_ t: Double, curve: CubicBezier) -> BoltPose {
    var pose = BoltPose()
    let (i, e) = segment(t, [0, 0.25, 1], curve)
    if i == 0 {
      pose.scale = mix(1, 1.35, e)
      pose.blur = mix(1.5, 3, e)
      pose.white = e
    } else {
      pose.scale = mix(1.35, 0.2, e)
      pose.lift = mix(0, 2, e)
      pose.opacity = 1 - e
      pose.blur = mix(3, 1.5, e)
      pose.white = 1 - e
    }
    return pose
  }
}

/// The strike (plugged) or the release (unplugged), played once.
private struct BoltMotion: ViewModifier {
  let plugged: Bool
  /// Low Power: a slower, softer strike.
  let calm: Bool
  let still: Bool
  let color: Color
  /// Points per unit of the ring's 16-unit box.
  let unit: CGFloat

  func body(content: Content) -> some View {
    let (plugged, color, unit) = (plugged, color, unit)
    if still {
      content.shadow(color: color, radius: 1.5)
    } else {
      // Strike: 0.65s on an overshooting curve (Low Power 1s, eased out);
      // release: 0.9s eased in, after a 0.15s wait.
      let (delay, duration) = plugged ? (0, calm ? 1 : 0.65) : (0.15, 0.9)
      let curve = plugged
        ? (calm ? CubicBezier(0, 0, 0.58, 1) : CubicBezier(0.2, 0.9, 0.3, 1.2))
        : CubicBezier(0.42, 0, 1, 1)
      content.keyframeAnimator(initialValue: 0.0, repeating: false) { view, time in
        let t = min(1, max(0, (time - delay) / duration))
        let pose = plugged ? BoltPose.strike(t, curve: curve) : BoltPose.release(t, curve: curve)
        view
          .shadow(color: .white.opacity(pose.white), radius: pose.blur)
          .shadow(color: color.opacity(1 - pose.white), radius: pose.blur)
          .shadow(color: color.opacity(pose.halo), radius: 6 * pose.halo)
          .scaleEffect(pose.scale)
          // The lift sits inside the scale, as in the CSS transform list.
          .offset(y: pose.lift * pose.scale * unit)
          .opacity(pose.opacity)
      } keyframes: { _ in
        LinearKeyframe(delay + duration, duration: delay + duration)
      }
    }
  }
}

/// Short rays shot outward from just off the ring's edge, staggered in threes.
private struct Sparks: View {
  let count: Int
  let color: Color
  let fast: Bool

  var body: some View {
    let (count, color, lineWidth) = (count, color, fast ? 1.5 : 1.4)
    let duration = fast ? 0.4 : 0.55
    let easeOut = CubicBezier(0, 0, 0.58, 1)
    let delays = (0..<count).map { 0.12 + Double($0 % 3) * 0.04 }
    let total = (delays.max() ?? 0) + duration
    // One clock for every ray; each reads its own eased progress off it.
    Color.clear.keyframeAnimator(initialValue: 0.0, repeating: false) { _, time in
      ZStack {
        ForEach(0..<count, id: \.self) { i in
          let p = easeOut.y(at: (time - delays[i]) / duration)
          // A 3-long dash sliding out along the 5-long ray: its head starts at
          // the base and its tail leaves past the tip (dashoffset 3 → -5).
          SparkRay()
            .trim(from: max(0, 1.6 * p - 0.6), to: min(1, 1.6 * p))
            .stroke(.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .shadow(color: color, radius: 1.5)
            .opacity(time < delays[i] ? 0 : 1 - p)
            .rotationEffect(.degrees(360 / Double(count) * Double(i) + Double(i % 2) * 14))
        }
      }
    } keyframes: { _ in
      LinearKeyframe(total, duration: total)
    }
  }
}

/// From 8 to 13 units above the centre of a 28-unit box: just off the ring.
nonisolated private struct SparkRay: Shape {
  func path(in rect: CGRect) -> Path {
    let unit = min(rect.width, rect.height) / 28
    var path = Path()
    path.move(to: CGPoint(x: rect.midX, y: rect.midY - 8 * unit))
    path.addLine(to: CGPoint(x: rect.midX, y: rect.midY - 13 * unit))
    return path
  }
}

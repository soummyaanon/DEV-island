import IslandCore
import SwiftUI

/// The battery as a ring, like the usage rings: the arc is the charge and runs
/// red through amber to green. On a charger the ring breathes a glow (and,
/// without a label, a bolt flickers in the middle); low on battery, the arc
/// turns red and blinks. Decorative: the wing's label carries the meaning.
/// Drawn in 1.x's 16-point box and scaled to `size`.
struct BatteryRing: View {
  var percent: Int
  var charging: Bool
  var low: Bool
  var size: CGFloat = 16
  /// The percentage inside the ring, in place of the bolt.
  var labelled = false
  /// False while paused or with Reduce Motion: nothing repeats.
  var animated = true

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var clamped: Int { min(100, max(0, percent)) }
  private var dead: Bool { low && !charging }
  private var hue: Double { batteryHue(percent: clamped, low: dead) }
  private var repeats: Bool { animated && !reduceMotion }

  /// The island's own low rings (full size, no label: the low wing and the low
  /// live activity) track in red, like 1.x's `.battery-low` / `.wing-low`.
  /// Elsewhere the track takes the surrounding colour, like `currentColor`.
  private var track: AnyShapeStyle {
    dead && !labelled && size >= 16
      ? AnyShapeStyle(Palette.failed.opacity(0.18))
      : AnyShapeStyle(.foreground.opacity(0.18))
  }

  var body: some View {
    let scale = size / 16
    // A thin arc on a wide radius leaves the most room for the number inside.
    let radius = (labelled ? 6.9 : 6.2) * scale
    let line = (labelled ? 1.8 : 2) * scale
    // A sliver always shows, so an empty battery still reads as a battery.
    let filled = max(0.04, Double(clamped) / 100)

    ZStack {
      RingArc(
        fill: filled, lineWidth: line, color: Palette.battery(hue: hue), track: track,
        blinking: dead && repeats, tint: reduceMotion ? nil : .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.4)
      )
      .frame(width: radius * 2, height: radius * 2)
      .animation(reduceMotion ? nil : Motion.level, value: filled)
      if labelled {
        let label = Text("\(clamped)")
          .font(.system(size: (clamped >= 100 ? 6.1 : 7.4) * scale, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .tracking((clamped >= 100 ? -0.45 : -0.35) * scale)
        // 1.x's `paint-order: stroke`: a 0.6-unit black stroke behind the fill,
        // so half of it shows as a hairline outline.
        let reach = 0.3 * scale
        ZStack {
          ForEach(0..<8, id: \.self) { i in
            let angle = Double(i) * .pi / 4
            label.foregroundStyle(.black).offset(x: cos(angle) * reach, y: sin(angle) * reach)
          }
        }
        .compositingGroup()
        .opacity(0.6)
        label.foregroundStyle(.white)
      } else if charging {
        Bolt()
          .fill(.white)
          .modifier(Flicker(active: repeats))
      }
    }
    .frame(width: size, height: size)
    .modifier(Breathe(hue: hue, active: charging && repeats))
  }
}

/// Track and arc, from twelve o'clock clockwise. Nonisolated, so keyframe
/// animators (which run off the main actor) can draw it.
nonisolated struct RingArc: View {
  var fill: Double
  var lineWidth: CGFloat
  var color: Color
  var track = AnyShapeStyle(Color.white.opacity(0.18))
  /// Low on battery: the arc blinks, the track stays.
  var blinking = false
  /// How a change of colour eases, apart from the level's own glide.
  var tint: Animation?

  var body: some View {
    ZStack {
      Circle().stroke(track, lineWidth: lineWidth)
      Circle()
        .trim(from: 0, to: fill)
        .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        .animation(tint) { $0.foregroundStyle(color) }
        .rotationEffect(.degrees(-90))
        .modifier(Blink(active: blinking))
    }
  }
}

/// 1.x's bolt, `M8.8 4.4 5.8 8.6h2.1l-.7 3 3-4.2H8.1z` in a 16-point box.
nonisolated struct Bolt: Shape {
  func path(in rect: CGRect) -> Path {
    let unit = min(rect.width, rect.height) / 16
    let points: [CGPoint] = [(8.8, 4.4), (5.8, 8.6), (7.9, 8.6), (7.2, 11.6), (10.2, 7.4), (8.1, 7.4)]
      .map { CGPoint(x: rect.minX + $0.0 * unit, y: rect.minY + $0.1 * unit) }
    var path = Path()
    path.addLines(points)
    path.closeSubpath()
    return path
  }
}

// MARK: - Repeating effects (each off while paused, and with Reduce Motion)

/// On a charger: a glow in the ring's own colour, breathing.
private struct Breathe: ViewModifier {
  let hue: Double
  let active: Bool

  private let started = State(initialValue: Date.now)

  func body(content: Content) -> some View {
    if active {
      // Dim to bright and back, 0.9 s each way, ease-in-out (a phase animator's
      // two phases), on a 30 fps clock rather than every display refresh.
      TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
        let phase = (timeline.date.timeIntervalSince(started.wrappedValue) / 0.9).truncatingRemainder(dividingBy: 2)
        let u = CubicBezier.easeInOutCurve.y(at: phase < 1 ? phase : 2 - phase)
        content.shadow(
          color: Palette.battery(hue: hue, saturation: 0.9 + 0.05 * u, lightness: 0.55 + 0.05 * u).opacity(0.4 + 0.45 * u),
          radius: 1 + 1.5 * u
        )
      }
      .onAppear { started.wrappedValue = .now }
    } else {
      content
    }
  }
}

/// Low on battery: the arc blinks.
nonisolated private struct Blink: ViewModifier {
  let active: Bool

  func body(content: Content) -> some View {
    if active {
      content.phaseAnimator([1.0, 0.35]) { view, opacity in
        view.opacity(opacity)
      } animation: { _ in .easeInOut(duration: 0.8) }
    } else {
      content
    }
  }
}

/// The bolt stutters now and then, like a live contact (`steps(1)`: no fades).
struct Flicker: ViewModifier {
  let active: Bool

  func body(content: Content) -> some View {
    if active {
      content.keyframeAnimator(initialValue: 1.0, repeating: true) { view, opacity in
        view.opacity(opacity)
      } keyframes: { _ in
        LinearKeyframe(1.0, duration: 0.902)
        MoveKeyframe(0.3)
        LinearKeyframe(0.3, duration: 0.044)
        MoveKeyframe(1.0)
        LinearKeyframe(1.0, duration: 0.066)
        MoveKeyframe(0.55)
        LinearKeyframe(0.55, duration: 0.044)
        MoveKeyframe(1.0)
        LinearKeyframe(1.0, duration: 1.144)
      }
    } else {
      content
    }
  }
}

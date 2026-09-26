import IslandCore
import SwiftUI

/// The island's text fields wear a soft sunset pulse instead of a focus ring:
/// it fades in when you start typing and out when you leave. While a
/// submitted question waits for its first words, the pulse becomes a glow
/// travelling the bottom edge. 1.x's FieldBeam, drawn from `border-beam`'s
/// own layers: a 1pt edge stroke, an inner glow faded in from the edges, and
/// a bloom on top.
struct FieldBeam: View {
  let focused: Bool
  var loading = false
  /// When the question went out, so the line starts from the left end.
  var since: Date?
  let paused: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    // border-beam's pulse types stay hidden under Reduce Motion; the line doesn't.
    let active = (focused || loading) && !paused && (loading || !reduceMotion)
    ZStack {
      if active {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
          Canvas { context, size in
            if loading {
              let t = timeline.date.timeIntervalSince(since ?? timeline.date)
              BeamRenderer.line(BeamMotion.line(at: max(0, t)), in: &context, size: size)
            } else {
              BeamRenderer.pulse(BeamMotion.pulse(at: timeline.date.timeIntervalSinceReferenceDate), in: &context, size: size)
            }
          }
        }
        .transition(.asymmetric(
          insertion: .opacity.animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.6)),
          removal: .opacity.animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.5))
        ))
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Each CSS `radial-gradient(ellipse rx ry at x y, …)` layer, and the masks
/// and clips around them. CSS paints the first background on top, so every
/// list below is drawn back to front.
nonisolated enum BeamRenderer {
  static let radius: CGFloat = 14

  private struct Glow {
    var x, y, rx, ry: Double
    var stops: [Gradient.Stop]
  }

  private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Color {
    Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
  }

  /// `color, transparent`, fading alpha only (CSS interpolates premultiplied).
  private static func fade(_ color: Color, to end: Double = 1) -> [Gradient.Stop] {
    [.init(color: color, location: 0), .init(color: color.opacity(0), location: end)]
  }

  private static func paint(_ glows: [Glow], in context: GraphicsContext) {
    for glow in glows.reversed() where glow.rx > 0.01 && glow.ry > 0.01 {
      var c = context
      c.translateBy(x: glow.x, y: glow.y)
      c.scaleBy(x: 1, y: glow.ry / glow.rx)
      c.fill(
        Path(ellipseIn: CGRect(x: -glow.rx, y: -glow.rx, width: glow.rx * 2, height: glow.rx * 2)),
        with: .radialGradient(Gradient(stops: glow.stops), center: .zero, startRadius: 0, endRadius: glow.rx)
      )
    }
  }

  private static func rounded(_ rect: CGRect, _ r: CGFloat) -> Path {
    Path(roundedRect: rect, cornerRadius: min(r, rect.height / 2), style: .continuous)
  }

  /// The 1pt ring between the border box and its content box.
  private static func ring(_ size: CGSize, radius r: CGFloat) -> Path {
    var path = rounded(CGRect(origin: .zero, size: size), r)
    path.addPath(rounded(CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1), r - 1))
    return path
  }

  /// `linear-gradient(white, transparent 28px, transparent calc(100% - 28px), white)`
  /// down and across, composited `add`: the glow shows only near the edges.
  private static func edgeMask(_ size: CGSize, in context: inout GraphicsContext) {
    let band = 28.0
    let rect = CGRect(origin: .zero, size: size)
    for (start, end, length) in [(CGPoint(x: 0, y: 0), CGPoint(x: 0, y: size.height), size.height), (CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0), size.width)] {
      let edge = min(0.5, band / max(1, length))
      let gradient = Gradient(stops: [
        .init(color: .white, location: 0), .init(color: .white.opacity(0), location: edge),
        .init(color: .white.opacity(0), location: 1 - edge), .init(color: .white, location: 1),
      ])
      context.fill(Path(rect), with: .linearGradient(gradient, startPoint: start, endPoint: end))
    }
  }

  /// Keeps only what's under `mask` (the layer's `mask-image`).
  private static func masked(_ context: inout GraphicsContext, content: (inout GraphicsContext) -> Void, mask: @escaping (inout GraphicsContext) -> Void) {
    context.drawLayer { layer in
      content(&layer)
      layer.blendMode = .destinationIn
      layer.drawLayer { mask(&$0) }
    }
  }

  // MARK: - pulse-inner

  /// strength 0.35, brightness 0.75, saturation 1.2, sunset.
  static func pulse(_ m: BeamMotion.Pulse, in context: inout GraphicsContext, size: CGSize) {
    let strength = 0.35
    let w = size.width, h = size.height
    let corner = [m.tl, m.tr, m.bl, m.br]
    // x%, y%, group, rgb, corner — shared by the stroke and the inner glow.
    let spots: [(Double, Double, Int, (Double, Double, Double), Int)] = [
      (0.33, -0.074, 0, (255, 80, 50), 0), (0.12, -0.05, 1, (255, 160, 40), 0),
      (0.021, 0.683, 2, (255, 120, 60), 2), (0.021, 0.683, 0, (255, 200, 50), 2),
      (0.744, 1, 1, (255, 100, 80), 3), (0.55, 1, 2, (255, 180, 60), 3),
      (0.939, 0, 0, (255, 60, 60), 1), (1, 0.271, 1, (255, 140, 50), 1), (1, 0.271, 2, (255, 90, 70), 1),
    ]
    func glows(_ sizes: [(Double, Double)]) -> [Glow] {
      zip(spots, sizes).map { spot, dims in
        let (px, py, g, c, k) = spot
        return Glow(
          x: px * w + m.dx[g], y: py * h + m.dy[g],
          rx: dims.0 * m.w[g], ry: dims.1 * m.h[g] * m.height,
          stops: fade(rgb(c.0, c.1, c.2, corner[k]))
        )
      }
    }
    var tone = context
    tone.addFilter(.colorMultiply(Color(white: 0.75)))
    tone.addFilter(.saturation(1.2))

    // ::before — the inner glow, plus a white wash in each corner.
    var inner = tone
    inner.clip(to: rounded(CGRect(origin: .zero, size: size), radius))
    inner.opacity = 0.44 * strength
    masked(&inner) { layer in
      let whites = [(0.0, 0.0, 0), (1.0, 0.0, 1), (0.0, 1.0, 2), (1.0, 1.0, 3)].map { x, y, k in
        Glow(x: x * w, y: y * h, rx: 60, ry: 60, stops: fade(.white.opacity(0.18 * corner[k]), to: 0.7))
      }
      paint(glows([(65, 35), (55, 30), (35, 65), (15, 30), (173, 28), (80, 22), (69, 28), (22, 38), (47, 44)]) + whites, in: layer)
    } mask: { edgeMask(size, in: &$0) }

    // ::after — the 1pt stroke.
    var stroke = tone
    stroke.clip(to: ring(size, radius: radius), style: FillStyle(eoFill: true))
    stroke.opacity = 1.54 * strength
    paint(glows([(70, 40), (60, 35), (40, 70), (20, 35), (180, 32), (85, 26), (74, 32), (26, 42), (52, 48)]), in: stroke)

    // The bloom: fixed, blurred, then cut back to the ring.
    var bloom = tone
    bloom.clip(to: ring(size, radius: radius), style: FillStyle(eoFill: true))
    bloom.opacity = 0.66 * strength
    bloom.drawLayer { layer in
      layer.addFilter(.blur(radius: 8))
      let fixed: [(Double, Double, Double, Double, (Double, Double, Double))] = [
        (84, 48, 0.33, -0.074, (255, 80, 50)), (72, 42, 0.12, -0.05, (255, 160, 40)), (48, 84, 0.021, 0.683, (255, 120, 60)),
        (216, 38, 0.744, 1, (255, 100, 80)), (102, 31, 0.55, 1, (255, 180, 60)), (89, 38, 0.939, 0, (255, 60, 60)),
        (62, 58, 1, 0.271, (255, 90, 70)),
      ]
      paint(fixed.map { rx, ry, px, py, c in Glow(x: px * w, y: py * h, rx: rx, ry: ry, stops: fade(rgb(c.0, c.1, c.2, 0.76))) }, in: layer)
    }
  }

  // MARK: - line

  /// strength 0.6, sunset.
  static func line(_ m: BeamMotion.Line, in context: inout GraphicsContext, size: CGSize) {
    let strength = 0.6
    let w = size.width, h = size.height
    let x = m.x * w
    func focus(_ rx: Double, _ ry: Double, _ mid: Double) -> (inout GraphicsContext) -> Void {
      { mask in
        paint([Glow(x: x, y: h, rx: rx * m.w, ry: ry * m.h, stops: [
          .init(color: .white, location: 0), .init(color: .white.opacity(0.5), location: mid), .init(color: .white.opacity(0), location: 1),
        ])], in: mask)
      }
    }

    // ::before — the inner glow and a faint inset shadow, near the beam and the edges.
    var inner = context
    inner.clip(to: rounded(CGRect(origin: .zero, size: size), radius))
    inner.opacity = 0.7 * m.edge * strength
    masked(&inner) { layer in
      let spots: [(Double, Double, Double, Double, (Double, Double, Double), Double)] = [
        (33, 30, 0, 0, (255, 100, 60), 0.48), (24, 26, 39, -3, (255, 180, 50), 0.42), (27, 24, -36, 0, (255, 140, 70), 0.48),
        (23, 28, -54, -2, (255, 80, 80), 0.42), (24, 24, 51, -1, (255, 200, 60), 0.5), (30, 20, 21, 0, (255, 120, 50), 0.45),
        (25, 18, -21, -2, (255, 160, 80), 0.4), (21, 24, 66, 0, (255, 90, 60), 0.45), (18, 26, -66, -1, (255, 70, 70), 0.52),
      ]
      paint(spots.map { rx, ry, dx, dy, c, a in Glow(x: x + dx, y: h + dy, rx: rx * m.w, ry: ry * m.h, stops: fade(rgb(c.0, c.1, c.2, a))) }, in: layer)
      // box-shadow: inset 0 0 9px 1px rgba(255, 255, 255, 0.1)
      layer.drawLayer { shadow in
        shadow.addFilter(.blur(radius: 4.5))
        shadow.stroke(rounded(CGRect(origin: .zero, size: size), radius), with: .color(.white.opacity(0.1)), lineWidth: 2)
      }
    } mask: { mask in
      masked(&mask) { edgeMask(size, in: &$0) } mask: { focus(78, 60, 0.45)(&$0) }
    }

    // ::after — the stroke, lit only under the beam.
    var stroke = context
    stroke.clip(to: ring(size, radius: radius - 1), style: FillStyle(eoFill: true))
    stroke.opacity = 1.14 * m.edge * strength
    masked(&stroke) { layer in
      let spots: [(Double, Double, Double, Double, (Double, Double, Double))] = [
        (36, 36, 0, 2, (255, 100, 60)), (30, 32, 39, 0, (255, 180, 50)), (33, 28, -36, 2, (255, 140, 70)),
        (29, 34, -54, 0, (255, 80, 80)), (27, 30, 51, -1, (255, 200, 60)), (36, 24, 21, 1, (255, 120, 50)),
        (30, 22, -21, 0, (255, 160, 80)), (25, 28, 66, 1, (255, 90, 60)), (23, 30, -66, -1, (255, 70, 70)),
      ]
      let highlight = Glow(x: x, y: h + 2, rx: 24 * m.w, ry: 28 * m.h, stops: [
        .init(color: .white.opacity(0.38), location: 0), .init(color: .white.opacity(0.12), location: 0.3), .init(color: .white.opacity(0), location: 0.65),
      ])
      paint([highlight] + spots.map { rx, ry, dx, dy, c in Glow(x: x + dx, y: h + dy, rx: rx * m.w, ry: ry * m.h, stops: fade(rgb(c.0, c.1, c.2))) }, in: layer)
    } mask: { focus(78, 60, 0.45)(&$0) }

    // The bloom: the spikes and the white-hot core, near the beam.
    var bloom = context
    bloom.clip(to: rounded(CGRect(origin: .zero, size: size), radius))
    bloom.opacity = 0.8 * m.edge * strength
    masked(&bloom) { layer in
      func spike(_ rx: Double, _ ry: Double, _ px: Double, _ dy: Double, _ c: (Double, Double, Double), _ a: Double, _ hold: Double, _ held: Double, _ end: Double) -> Glow {
        let color = rgb(c.0, c.1, c.2)
        return Glow(x: px * w, y: h + dy, rx: rx, ry: ry * m.h, stops: [
          .init(color: color.opacity(a), location: 0), .init(color: color.opacity(held), location: hold), .init(color: color.opacity(0), location: end),
        ])
      }
      paint([
        spike(0.8 * m.spike, 92, 0.08, -2, (255, 140, 80), 1, 0.3, 1, 0.88),
        spike(10 * m.spike2, 35, 0.22, -4, (255, 100, 60), 0.98, 0.5, 0.49, 0.95),
        spike(2 * (2 - m.spike), 72, 0.36, -3, (255, 100, 80), 1, 0.4, 1, 0.9),
        spike(14 * m.spike2, 28, 0.5, -2, (255, 150, 80), 0.59, 0.55, 0.29, 0.96),
        spike(1.2 * (2 - m.spike2), 85, 0.64, -4, (255, 80, 60), 1, 0.35, 1, 0.89),
        spike(7 * m.spike, 45, 0.78, -2, (255, 120, 50), 0.91, 0.48, 0.45, 0.94),
        spike(0.6 * (2 - m.spike), 60, 0.92, -3, (255, 140, 70), 1, 0.42, 1, 0.91),
        Glow(x: x, y: h + 1, rx: 21 * m.spike, ry: 15 * m.spike2, stops: [
          .init(color: .white, location: 0), .init(color: .white.opacity(0.9), location: 0.2),
          .init(color: .white.opacity(0.5), location: 0.5), .init(color: .white.opacity(0), location: 1),
        ]),
        Glow(x: x, y: h, rx: 42 * m.w, ry: 40 * m.h, stops: [
          .init(color: .white.opacity(0.3), location: 0), .init(color: .white.opacity(0.12), location: 0.25),
          .init(color: .white.opacity(0.03), location: 0.55), .init(color: .white.opacity(0), location: 0.8),
        ]),
      ], in: layer)
    } mask: { focus(84, 110, 0.35)(&$0) }
  }
}

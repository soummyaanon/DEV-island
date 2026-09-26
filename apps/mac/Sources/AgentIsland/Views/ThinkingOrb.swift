import IslandCore
import SwiftUI

/// A dotted thought-orb, the native stand-in for `thinking-orbs`: nine
/// animations for what an agent is doing, drawn as dots on a sphere that fade
/// and shrink with depth, in one tint. Frozen while paused or with Reduce Motion.
struct ThinkingOrb: View {
  let state: OrbState
  var tint: Color = Palette.text
  var size: CGFloat = 20
  /// Heavier dots, for the wing, where the orb sits on pure black at a glance.
  var bold = false
  var paused = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let still = paused || reduceMotion
    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { timeline in
      let time = still ? 1.3 : timeline.date.timeIntervalSinceReferenceDate
      Canvas { context, canvas in
        OrbRenderer.draw(state, time: time, tint: tint, bold: bold, in: &context, size: canvas)
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

nonisolated enum OrbRenderer {
  struct Dot {
    var p: SIMD3<Double>
    /// Extra emphasis: the scan line, a packet.
    var weight: Double = 1
  }

  static func draw(_ state: OrbState, time t: Double, tint: Color, bold: Bool, in context: inout GraphicsContext, size: CGSize) {
    let radius = min(size.width, size.height) / 2 * 0.82
    let centre = CGPoint(x: size.width / 2, y: size.height / 2)
    let dotRadius = (bold ? 1.45 : 1) * min(size.width, size.height) / 20 * 0.62
    var lines: [(SIMD3<Double>, SIMD3<Double>)] = []
    let dots = points(state, t: t, lines: &lines)

    func project(_ p: SIMD3<Double>) -> (CGPoint, Double) {
      (CGPoint(x: centre.x + p.x * radius, y: centre.y - p.y * radius), (p.z + 1) / 2)
    }
    for (a, b) in lines {
      let (pa, da) = project(a)
      let (pb, db) = project(b)
      var line = Path()
      line.move(to: pa)
      line.addLine(to: pb)
      context.stroke(line, with: .color(tint.opacity(0.15 + 0.35 * (da + db) / 2)), lineWidth: 0.5)
    }
    // Far dots first, so near ones draw over them.
    for dot in dots.sorted(by: { $0.p.z < $1.p.z }) {
      let (point, depth) = project(dot.p)
      let r = dotRadius * (0.6 + 0.55 * depth) * (0.8 + 0.35 * dot.weight)
      let opacity = min(1, (0.18 + 0.82 * depth) * (0.55 + 0.45 * dot.weight))
      context.fill(
        Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)),
        with: .color(tint.opacity(opacity))
      )
    }
  }

  private static func sphere(lat: Double, lon: Double) -> SIMD3<Double> {
    SIMD3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))
  }

  private static func rotate(_ p: SIMD3<Double>, x ax: Double = 0, y ay: Double = 0, z az: Double = 0) -> SIMD3<Double> {
    var v = p
    if ax != 0 { v = SIMD3(v.x, v.y * cos(ax) - v.z * sin(ax), v.y * sin(ax) + v.z * cos(ax)) }
    if ay != 0 { v = SIMD3(v.x * cos(ay) + v.z * sin(ay), v.y, -v.x * sin(ay) + v.z * cos(ay)) }
    if az != 0 { v = SIMD3(v.x * cos(az) - v.y * sin(az), v.x * sin(az) + v.y * cos(az), v.z) }
    return v
  }

  private static func ease(_ x: Double) -> Double {
    x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
  }

  static func points(_ state: OrbState, t: Double, lines: inout [(SIMD3<Double>, SIMD3<Double>)]) -> [Dot] {
    let tilt = 0.35
    switch state {
    case .working:
      // Particles on three tilted orbits.
      return (0..<3).flatMap { orbit in
        (0..<6).map { i in
          let angle = Double(i) / 6 * 2 * .pi + t * (1.6 + 0.3 * Double(orbit))
          let ring = SIMD3(cos(angle), 0, sin(angle))
          return Dot(p: rotate(ring, x: 1.1, z: Double(orbit) * .pi / 3 + t * 0.2))
        }
      }

    case .searching:
      // A scan meridian sweeps a dotted globe.
      let sweep = (t * 1.4).truncatingRemainder(dividingBy: 2 * .pi)
      return (0..<5).flatMap { row in
        (0..<10).map { column in
          let lat = (Double(row) - 2) / 2.6 * 1.2
          let lon = Double(column) / 10 * 2 * .pi + t * 0.5
          let local = (lon - t * 0.5 - sweep).truncatingRemainder(dividingBy: 2 * .pi)
          let near = abs(local) < 0.35 || abs(local) > 2 * .pi - 0.35
          return Dot(p: rotate(sphere(lat: lat, lon: lon), x: tilt), weight: near ? 1.6 : 0.6)
        }
      }

    case .solving:
      // Bands scramble in quarter turns, then click back solved.
      let cycle = 2.4
      let phase = (t / cycle).truncatingRemainder(dividingBy: 1)
      return (0..<4).flatMap { band in
        let direction = band % 2 == 0 ? 1.0 : -1.0
        let step = phase < 0.75 ? ease(min(1, phase * 4 - floor(phase * 4))) + floor(phase * 4) : 3 * (1 - ease((phase - 0.75) * 4))
        let turn = direction * step * .pi / 2
        return (0..<9).map { i in
          let lat = (Double(band) - 1.5) / 2.2
          return Dot(p: rotate(sphere(lat: lat, lon: Double(i) / 9 * 2 * .pi + turn), x: tilt, y: t * 0.3))
        }
      }

    case .listening:
      // A waveform rolls through the latitude rings.
      return (0..<5).flatMap { ring in
        let wave = 1 + 0.2 * sin(2 * .pi * (t * 1.2 - Double(ring) * 0.2))
        let lat = (Double(ring) - 2) / 2.8 * 1.3
        return (0..<10).map { i in
          var p = sphere(lat: lat, lon: Double(i) / 10 * 2 * .pi + t * 0.4)
          p.x *= wave
          p.z *= wave
          return Dot(p: rotate(p, x: tilt), weight: wave)
        }
      }

    case .connecting:
      // A constellation wires itself; packets run the edges.
      let nodes = (0..<8).map { i -> SIMD3<Double> in
        let y = 1 - 2 * (Double(i) + 0.5) / 8
        let r = sqrt(1 - y * y)
        let theta = Double(i) * 2.399963
        return rotate(SIMD3(r * cos(theta), y, r * sin(theta)), x: tilt, y: t * 0.5)
      }
      let wired = Int((t / 0.4).truncatingRemainder(dividingBy: 10))
      var dots = nodes.map { Dot(p: $0, weight: 1.3) }
      for i in 0..<min(wired, nodes.count - 1) {
        let (a, b) = (nodes[i], nodes[i + 1])
        lines.append((a, b))
        let u = (t * 1.5 + Double(i) * 0.3).truncatingRemainder(dividingBy: 1)
        dots.append(Dot(p: a + (b - a) * u, weight: 1.5))
      }
      return dots

    case .weaving:
      // Three strands plait around the sphere.
      return (0..<3).flatMap { strand in
        (0..<14).map { i in
          let u = Double(i) / 14
          let lon = u * 2 * .pi + t * 0.9
          let lat = 0.55 * sin(2 * lon + Double(strand) * 2 * .pi / 3 + t * 1.3)
          return Dot(p: rotate(sphere(lat: lat, lon: lon), x: tilt))
        }
      }

    case .composing:
      // An undulating multi-band sash.
      return (0..<3).flatMap { band in
        (0..<14).map { i in
          let lon = Double(i) / 14 * 2 * .pi + t * 0.8
          let lat = (Double(band) - 1) * 0.22 + 0.25 * sin(3 * lon + t * 2)
          return Dot(p: rotate(sphere(lat: lat, lon: lon), x: 0.5, z: 0.4))
        }
      }

    case .breathing:
      // A face-on ring, slowly morphing.
      return (0..<16).map { i in
        let a = Double(i) / 16 * 2 * .pi
        let r = 0.78 + 0.12 * sin(t * 1.1) * cos(2 * a + t * 0.6)
        return Dot(p: SIMD3(r * cos(a), r * sin(a), 0.6))
      }

    case .shaping:
      // A dotted outline: circle → triangle → square.
      let cycle = (t / 1.6).truncatingRemainder(dividingBy: 3)
      let (from, to) = (Int(cycle), (Int(cycle) + 1) % 3)
      let mix = ease(min(1, (cycle - floor(cycle)) * 1.6))
      return (0..<18).map { i in
        let a = Double(i) / 18 * 2 * .pi - .pi / 2
        let p = outline(from, a) * (1 - mix) + outline(to, a) * mix
        return Dot(p: SIMD3(p.x * 0.85, -p.y * 0.85, 0.6))
      }
    }
  }

  /// A point on a circle (0), triangle (1) or square (2) at angle `a`.
  private static func outline(_ shape: Int, _ a: Double) -> SIMD2<Double> {
    let direction = SIMD2(cos(a), sin(a))
    switch shape {
    case 1:
      let sector = 2 * Double.pi / 3
      let local = (a + .pi / 2).truncatingRemainder(dividingBy: sector) - sector / 2
      return direction * (0.5 / cos(local))
    case 2:
      return direction / max(abs(cos(a)), abs(sin(a)))
    default:
      return direction
    }
  }
}

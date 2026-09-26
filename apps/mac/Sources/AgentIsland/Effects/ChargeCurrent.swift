import AppKit
import CoreImage
import IslandCore
import QuartzCore
import SwiftUI

/// The charger went in: current runs in from both ears, down the island's
/// sides and along its bottom into the Mac, crackling as it goes, while the
/// rim lights along the same outline. Pulling the plug plays it backwards.
/// Low Power is a calm trickle with no crackle; High Power a fast double surge.
///
/// Core Animation does what 1.x did with SVG dash tricks and a reseeding
/// displacement filter: `strokeStart`/`strokeEnd` move the current, and a few
/// precomputed crackled paths swap in discretely.
///
/// Reduce Motion skips the current, as 1.x did, and keeps only the edge bloom
/// fading in and out; Increase Contrast draws that bloom as a 2pt inner border.
struct ChargeCurrent: NSViewRepresentable {
  let moment: PowerActivity
  let corner: CGFloat
  /// Reduce Motion: no current, just the bloom fading in and out.
  let reduced: Bool
  /// Increase Contrast: the bloom becomes a solid inner border.
  let highContrast: Bool

  func makeNSView(context: Context) -> ChargeView {
    ChargeView(
      style: ChargeView.Style(moment: moment, reduced: reduced, highContrast: highContrast),
      corner: corner
    )
  }

  func updateNSView(_ view: ChargeView, context: Context) {
    view.corner = corner
  }
}

final class ChargeView: NSView {
  struct Style {
    var color: NSColor
    var energyMode: EnergyMode
    var inward: Bool
    var reduced: Bool
    var highContrast: Bool

    init(moment: PowerActivity, reduced: Bool, highContrast: Bool) {
      color = NSColor(Palette.charge(moment))
      energyMode = moment.energyMode
      inward = moment.kind == .plugged
      self.reduced = reduced
      self.highContrast = highContrast
    }

    var crackles: Bool { energyMode != .low && !reduced }
    /// 1.x's `.edge-spark` under the current: only with Reduce Motion or Increase Contrast.
    var blooms: Bool { reduced || highContrast }
    /// One run's duration and how many surges.
    var run: (duration: CFTimeInterval, count: Float) {
      switch energyMode {
      case .high: (0.6, 2)
      case .low: (1.5, 1)
      case .automatic: (0.9, 1)
      }
    }
  }

  var corner: CGFloat {
    didSet { if corner != oldValue { needsLayout = true } }
  }

  private let style: Style
  private let rim = CAShapeLayer()
  private let sides = [CALayer(), CALayer()]
  private var glows: [CAShapeLayer] = []
  private var cores: [CAShapeLayer] = []
  private let bloom = CALayer()
  private let bloomMask = CAShapeLayer()
  private var bloomShapes: [CAShapeLayer] = []
  /// Room around the blurred sheath, so the blur isn't cut at the layer's edge.
  private static let glowPad: CGFloat = 12
  private var laidOut: IslandOutline?

  init(style: Style, corner: CGFloat) {
    self.style = style
    self.corner = corner
    super.init(frame: .zero)
    // Layer-backed and flipped, so AppKit keeps the layer's geometry top-left
    // like the outline's. Hand-setting `isGeometryFlipped` on a hosted layer
    // drew the whole current upside down: ears at the bottom, along the bezel.
    wantsLayer = true
    layerUsesCoreImageFilters = true
    if let layer { buildLayers(in: layer) }
  }

  override var isFlipped: Bool { true }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  private func buildLayers(in root: CALayer) {
    let color = style.color
    if style.blooms { buildBloom(in: root) }
    guard !style.reduced else { return }

    rim.fillColor = nil
    rim.strokeColor = color.blended(withFraction: 0.25, of: .white)?.cgColor
    rim.lineWidth = 1.5
    rim.opacity = 0
    rim.shadowColor = color.cgColor
    rim.shadowRadius = 3
    rim.shadowOpacity = 1
    rim.shadowOffset = .zero
    root.addSublayer(rim)

    for side in sides {
      // The sheath: the full charge colour, 5 wide, blurred soft all through.
      let glow = CAShapeLayer()
      glow.fillColor = nil
      glow.strokeColor = color.cgColor
      glow.lineWidth = 5
      glow.lineCap = .round
      glow.filters = Self.blur(2.5).map { [$0] }

      let core = CAShapeLayer()
      core.fillColor = nil
      core.lineCap = .round
      if style.energyMode == .low {
        core.strokeColor = color.blended(withFraction: 0.6, of: .white)?.cgColor
        core.lineWidth = 1.3
      } else {
        core.strokeColor = NSColor.white.cgColor
        core.lineWidth = 1.6
      }
      for layer in [glow, core] {
        layer.strokeStart = 0
        layer.strokeEnd = 0
        layer.opacity = 0
        side.addSublayer(layer)
      }
      glows.append(glow)
      cores.append(core)
      root.addSublayer(side)
    }
    // The outline is symmetric: the right side is the left one, mirrored.
    sides[1].transform = CATransform3DMakeScale(-1, 1, 1)
  }

  /// 1.x's `.edge-spark` box-shadows, inside the silhouette: a bloom all round
  /// (`inset 0 0 18px -2px`) and a heavier wash off the bottom
  /// (`inset 0 -14px 22px -7px`), or, at Increase Contrast, `inset 0 0 0 2px`.
  private func buildBloom(in root: CALayer) {
    let color = style.color.cgColor
    bloom.opacity = 0
    bloom.mask = bloomMask
    if style.highContrast {
      let border = CAShapeLayer()
      border.fillColor = nil
      border.strokeColor = color
      // Half of it falls outside the mask: 2pt inside.
      border.lineWidth = 4
      bloomShapes = [border]
    } else {
      // An inset shadow is the outside, blurred, seen through the inside.
      bloomShapes = [9.0, 11.0].map { sigma in
        let shape = CAShapeLayer()
        shape.fillColor = color
        shape.fillRule = .evenOdd
        shape.filters = Self.blur(sigma).map { [$0] }
        return shape
      }
    }
    for shape in bloomShapes { bloom.addSublayer(shape) }
    root.addSublayer(bloom)
  }

  private static func blur(_ sigma: Double) -> CIFilter? {
    let filter = CIFilter(name: "CIGaussianBlur")
    filter?.setValue(sigma, forKey: kCIInputRadiusKey)
    return filter
  }

  override func layout() {
    super.layout()
    guard bounds.width > 2 * IslandOutline.earRadius, bounds.height > 0 else { return }
    let outline = IslandOutline(width: bounds.width - 2 * IslandOutline.earRadius, height: bounds.height, corner: corner)
    guard outline != laidOut else { return }
    let first = laidOut == nil
    laidOut = outline

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let edge = outline.edge()
    rim.frame = bounds
    rim.path = edge
    for side in sides {
      side.bounds = bounds
      side.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }
    for layer in cores {
      layer.frame = bounds
      layer.path = edge
    }
    let pad = Self.glowPad
    var shift = CGAffineTransform(translationX: pad, y: pad)
    for layer in glows {
      layer.frame = bounds.insetBy(dx: -pad, dy: -pad)
      layer.path = edge.copy(using: &shift)
    }
    if style.blooms { layoutBloom(outline) }
    CATransaction.commit()

    if first { play() }
    if style.crackles { crackle(outline) }
  }

  private func layoutBloom(_ outline: IslandOutline) {
    let silhouette = outline.silhouette()
    bloom.frame = bounds
    bloomMask.frame = bounds
    bloomMask.path = silhouette
    if style.highContrast {
      bloomShapes.first?.frame = bounds
      bloomShapes.first?.path = silhouette
      return
    }
    // Each shadow's hole is the silhouette grown by the negative spread, moved
    // by the offset; the fill is everything around it.
    let far = bounds.insetBy(dx: -60, dy: -60)
    for (shape, (spread, dy)) in zip(bloomShapes, [(2.0, 0.0), (7.0, -14.0)]) {
      let grown = silhouette.union(silhouette.copy(
        strokingWithWidth: 2 * spread, lineCap: .round, lineJoin: .round, miterLimit: 10
      ))
      let move = CGAffineTransform(translationX: 0, y: dy)
      let path = CGMutablePath()
      path.addRect(far)
      path.addPath(grown, transform: move)
      shape.frame = bounds
      shape.path = path
    }
  }

  private func play() {
    if style.blooms { bloom.add(bloomAnimation(), forKey: "bloom") }
    guard !style.reduced else { return }
    rim.add(rimAnimation(), forKey: "rim")
    let run = runAnimation()
    for layer in glows + cores {
      layer.add(run, forKey: "run")
    }
  }

  /// 1.x's `spark-charge` on the charger, `spark-life` (a single fade) pulling
  /// the plug and with Reduce Motion: 2.4s in, 1.8s out.
  private func bloomAnimation() -> CAAnimation {
    let animation = CAKeyframeAnimation(keyPath: "opacity")
    if style.inward && !style.reduced {
      animation.values = [0, 1, 0.15, 1, 0.3, 1, 0.9, 0]
      animation.keyTimes = [0, 0.05, 0.11, 0.17, 0.22, 0.28, 0.6, 1]
    } else {
      animation.values = [0, 1, 0]
      animation.keyTimes = [0, 0.14, 1]
    }
    animation.duration = style.inward ? 2.4 : 1.8
    animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeOut), count: animation.values!.count - 1)
    return holding(animation)
  }

  /// The rim flickers on with the current, holds, drains away. Unplugging gets
  /// a single fade.
  private func rimAnimation() -> CAAnimation {
    let animation = CAKeyframeAnimation(keyPath: "opacity")
    if style.inward {
      animation.values = [0, 1, 0.15, 1, 0.3, 1, 0.9, 0]
      animation.keyTimes = [0, 0.05, 0.11, 0.17, 0.22, 0.28, 0.6, 1]
      animation.duration = 2.3
    } else {
      animation.values = [0, 1, 0]
      animation.keyTimes = [0, 0.14, 1]
      animation.duration = 1.7
    }
    animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeOut), count: animation.values!.count - 1)
    return holding(animation)
  }

  /// One surge, ear → just past the middle, where the notch swallows it: a
  /// head 14% of the outline long, travelling to 54% of it. Unplugging runs it
  /// backwards, and so does its easing.
  private func runAnimation() -> CAAnimation {
    let (reach, dash): (NSNumber, NSNumber) = (0.54, 0.14)
    let tailStarts = NSNumber(value: dash.doubleValue / reach.doubleValue)
    let ease = style.inward
      ? CAMediaTimingFunction(controlPoints: 0.5, 0, 0.3, 1)
      : CAMediaTimingFunction(controlPoints: 0.7, 0, 0.5, 1)

    let head = CABasicAnimation(keyPath: "strokeEnd")
    // The tail waits at the ear until the head is a dash ahead, then follows.
    let tail = CAKeyframeAnimation(keyPath: "strokeStart")
    let opacity = CAKeyframeAnimation(keyPath: "opacity")
    if style.inward {
      (head.fromValue, head.toValue) = (0, reach)
      tail.values = [0, 0, reach.doubleValue - dash.doubleValue]
      tail.keyTimes = [0, tailStarts, 1]
      opacity.values = [0, 1, 1, 0]
      opacity.keyTimes = [0, 0.1, 0.8, 1]
    } else {
      (head.fromValue, head.toValue) = (reach, 0)
      tail.values = [reach.doubleValue - dash.doubleValue, 0, 0]
      tail.keyTimes = [0, NSNumber(value: 1 - tailStarts.doubleValue), 1]
      opacity.values = [0, 1, 1, 0]
      opacity.keyTimes = [0, 0.2, 0.9, 1]
    }
    head.timingFunction = ease
    tail.timingFunction = ease
    opacity.timingFunctions = [ease, ease, ease]

    let group = CAAnimationGroup()
    group.animations = [head, tail, opacity]
    group.duration = style.run.duration
    group.repeatCount = style.run.count
    return holding(group)
  }

  /// A live wire: seven crackled outlines swapped in discretely, forever.
  private func crackle(_ outline: IslandOutline) {
    let scale: CGFloat = style.energyMode == .high ? 4.5 : 3
    let wires = [1, 4, 2, 7, 3, 9, 5].map { Crackle.path(outline, seed: $0, scale: scale) }
    var shift = CGAffineTransform(translationX: Self.glowPad, y: Self.glowPad)
    for (layers, paths) in [(cores, wires), (glows, wires.compactMap { $0.copy(using: &shift) })] {
      let animation = CAKeyframeAnimation(keyPath: "path")
      animation.values = paths
      animation.calculationMode = .discrete
      animation.duration = 0.35
      animation.repeatCount = .infinity
      for layer in layers {
        layer.add(animation, forKey: "crackle")
      }
    }
  }

  private func holding<A: CAAnimation>(_ animation: A) -> A {
    animation.fillMode = .forwards
    animation.isRemovedOnCompletion = false
    return animation
  }
}

/// 1.x's crackle filter, `feTurbulence type=fractalNoise baseFrequency=0.8
/// numOctaves=2` into `feDisplacementMap scale=3|4.5`, done to the path: each
/// point every 1pt is shoved in x and in y by its own channel of the noise at
/// that spot, up to ±scale/2. A seed always draws the same wire.
nonisolated enum Crackle {
  static func path(_ outline: IslandOutline, seed: UInt64, scale: CGFloat) -> CGPath {
    let count = max(2, Int(outline.length.rounded(.up)))
    let path = CGMutablePath()
    for i in 0...count {
      let (point, _) = outline.sample(at: CGFloat(i) / CGFloat(count))
      let dx = scale * (channel(point, seed: seed, channel: 0) - 0.5)
      let dy = scale * (channel(point, seed: seed, channel: 1) - 0.5)
      let moved = CGPoint(x: point.x + dx, y: point.y + dy)
      if i == 0 { path.move(to: moved) } else { path.addLine(to: moved) }
    }
    return path
  }

  /// One colour channel of fractal noise, 0…1 around 0.5.
  static func channel(_ point: CGPoint, seed: UInt64, channel: UInt64) -> CGFloat {
    var sum = 0.0
    var (frequency, amplitude) = (0.8, 1.0)
    for octave in 0..<2 {
      sum += amplitude * gradient(Double(point.x) * frequency, Double(point.y) * frequency, salt: seed &* 31 &+ channel &* 7 &+ UInt64(octave))
      frequency *= 2
      amplitude /= 2
    }
    return CGFloat(min(1, max(0, (sum + 1) / 2)))
  }

  /// Perlin-style gradient noise, about −0.7…0.7.
  private static func gradient(_ x: Double, _ y: Double, salt: UInt64) -> Double {
    let (x0, y0) = (x.rounded(.down), y.rounded(.down))
    let (fx, fy) = (x - x0, y - y0)
    func dot(_ ix: Double, _ iy: Double) -> Double {
      var random = SplitMix64(seed: UInt64(bitPattern: Int64(ix) &* 73_856_093 ^ Int64(iy) &* 19_349_663) ^ salt &* 0x9E37_79B9)
      let angle = Double(random.next() >> 11) / Double(1 << 53) * 2 * .pi
      return cos(angle) * (x - ix) + sin(angle) * (y - iy)
    }
    func fade(_ t: Double) -> Double { t * t * t * (t * (t * 6 - 15) + 10) }
    let (u, v) = (fade(fx), fade(fy))
    let top = dot(x0, y0) + (dot(x0 + 1, y0) - dot(x0, y0)) * u
    let bottom = dot(x0, y0 + 1) + (dot(x0 + 1, y0 + 1) - dot(x0, y0 + 1)) * u
    return top + (bottom - top) * v
  }
}

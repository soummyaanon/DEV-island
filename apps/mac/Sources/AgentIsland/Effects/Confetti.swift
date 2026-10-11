import AppKit
import QuartzCore
import SwiftUI

/// A quick burst of confetti out of the notch: one short puff from the band's
/// bottom edge, flung down and outward, then falling and fading on its own.
/// It fills the panel's whole transparent canvas, so it isn't clipped to the
/// island, and never takes the mouse.
struct Confetti: NSViewRepresentable {
  /// Where the burst comes from: the notch's width, the band's bottom edge.
  let notchWidth: CGFloat
  let bandHeight: CGFloat

  func makeNSView(context: Context) -> ConfettiView {
    ConfettiView(notchWidth: notchWidth, bandHeight: bandHeight)
  }

  func updateNSView(_ view: ConfettiView, context: Context) {}
}

final class ConfettiView: NSView {
  /// How long pieces pour out; the rest is them falling.
  static let burst: TimeInterval = 0.18
  /// From the burst to the last piece gone.
  static let duration: Duration = .seconds(3)

  private let emitter = CAEmitterLayer()
  private let notchWidth: CGFloat
  private let bandHeight: CGFloat

  init(notchWidth: CGFloat, bandHeight: CGFloat) {
    self.notchWidth = notchWidth
    self.bandHeight = bandHeight
    super.init(frame: .zero)
    wantsLayer = true
    emitter.emitterShape = .line
    emitter.emitterMode = .outline
    emitter.renderMode = .oldestLast
    emitter.emitterCells = Self.cells
    emitter.beginTime = CACurrentMediaTime()
    layer?.addSublayer(emitter)
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.burst) { [emitter] in
      emitter.birthRate = 0
    }
  }

  override var isFlipped: Bool { true }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func layout() {
    super.layout()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    emitter.frame = bounds
    emitter.emitterPosition = CGPoint(x: bounds.midX, y: bandHeight)
    emitter.emitterSize = CGSize(width: notchWidth, height: 1)
    CATransaction.commit()
  }

  private static let colors: [NSColor] = [
    .systemPink, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue, .systemPurple, .white,
  ]

  /// Strips, squares and dots in each colour.
  private static let cells: [CAEmitterCell] = colors.flatMap { color in
    [piece(width: 9, height: 4, radius: 1), piece(width: 6, height: 6, radius: 1), piece(width: 6, height: 6, radius: 3)].map { image in
      let cell = CAEmitterCell()
      cell.contents = image
      cell.color = color.cgColor
      cell.birthRate = 22
      cell.lifetime = 2.8
      cell.lifetimeRange = 0.4
      // Measured from straight up, so π flings them down; gravity does the rest.
      cell.emissionLongitude = .pi
      cell.emissionRange = .pi * 0.42
      cell.velocity = 330
      cell.velocityRange = 160
      cell.yAcceleration = 420
      cell.spin = 3
      cell.spinRange = 10
      cell.scale = 0.9
      cell.scaleRange = 0.4
      cell.alphaSpeed = -0.3
      return cell
    }
  }

  private static func piece(width: CGFloat, height: CGFloat, radius: CGFloat) -> CGImage? {
    let image = NSImage(size: CGSize(width: width, height: height), flipped: false) { rect in
      NSColor.white.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    var rect = CGRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
  }
}

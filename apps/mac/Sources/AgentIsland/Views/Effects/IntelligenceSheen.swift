import IslandCore
import SwiftUI

/// Apple Intelligence's edge light, kept quiet: a hairline of soft pastel
/// colour drifting around the island's edge, over a faint bloom. Never the
/// bezel, never a neon tube.
struct IntelligenceSheen: View {
  /// Apple Intelligence's pastels: lilac, pink, periwinkle, coral, peach, violet.
  static let colors: [Color] = [
    Color(hex: 0xBC82F3), Color(hex: 0xF5B9EA), Color(hex: 0x8D9FFF),
    Color(hex: 0xFF6778), Color(hex: 0xFFBA71), Color(hex: 0xC686FF),
  ]

  /// One turn of the colours, in seconds.
  static let period = 4.0

  var corner: CGFloat
  var placement: IslandPlacement = .top
  var ear: CGFloat = IslandOutline.earRadius
  var paused = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: paused || reduceMotion)) { timeline in
      let turn = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
      let gradient = AngularGradient(colors: Self.colors + [Self.colors[0]], center: .center, angle: .degrees(turn * 360))
      let edge = IslandEdge(corner: corner, placement: placement, ear: ear)
      ZStack {
        edge.stroke(gradient, lineWidth: 5).blur(radius: 5).opacity(0.3)
        edge.stroke(gradient, lineWidth: 1.2).opacity(0.85)
      }
    }
    .allowsHitTesting(false)
  }
}

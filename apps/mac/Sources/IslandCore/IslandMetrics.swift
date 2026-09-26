import CoreGraphics

/// Where the hardware notch is, in points.
public struct NotchMetrics: Equatable, Sendable {
  /// Assumed when the display has no notch (or can't say): 1.x's fallback.
  public static let fallbackWidth: CGFloat = 196

  public var width: CGFloat
  /// From the top of the screen to the notch's bottom line (the menu bar's height).
  public var height: CGFloat
  public var hasNotch: Bool

  public init(width: CGFloat, height: CGFloat, hasNotch: Bool) {
    self.width = width
    self.height = height
    self.hasNotch = hasNotch
  }

  /// From a screen's frame width, its two auxiliary top areas (the menu bar on
  /// either side of the notch) and its top safe-area inset. A real notch is
  /// roughly 120–260 pt; anything else is treated as no notch.
  public init(screenWidth: CGFloat, leftArea: CGFloat?, rightArea: CGFloat?, topInset: CGFloat, menuBarHeight: CGFloat) {
    let gap = leftArea.flatMap { left in rightArea.map { screenWidth - left - $0 } }
    if let gap, topInset > 0, (120...260).contains(gap) {
      self.init(width: gap.rounded(), height: topInset, hasNotch: true)
    } else {
      self.init(width: Self.fallbackWidth, height: menuBarHeight, hasNotch: false)
    }
  }
}

/// The island's sizes, from 1.x's island.css.
public enum IslandMetrics {
  /// The black band runs this far below the notch, never shorter: at the exact
  /// notch height its bottom edge peeked out under the wings mid-animation.
  public static let bandExtra: CGFloat = 5
  /// Wings for the idle battery (ring left, room on the right).
  public static let batteryWings: CGFloat = 104

  public static func bandHeight(_ notch: NotchMetrics) -> CGFloat {
    notch.height + bandExtra
  }

  /// Collapsed: the notch plus wings, or exactly the notch when there's
  /// nothing to show (a desktop Mac with no battery).
  public static func collapsedWidth(_ notch: NotchMetrics, showsWings: Bool) -> CGFloat {
    showsWings ? notch.width + batteryWings : notch.width
  }

  /// Narrowest the expanded island may be.
  public static func expandedWidth(_ notch: NotchMetrics) -> CGFloat {
    max(360, notch.width + 110)
  }
}

/// The battery ring's hue (degrees) for a charge level: red → amber → green.
public func batteryHue(percent: Int, low: Bool) -> Double {
  low ? 2 : Double(min(100, max(0, percent))) * 1.3
}

import AppKit
import IslandCore

/// The overlay over the notch: borderless, never activates the app, above the
/// menu bar, on every Space and over full-screen apps, and stationary, so Show
/// Desktop, Stage Manager and "click wallpaper to reveal desktop" leave it
/// where it is (1.x needed `window-pin.node` for that).
///
/// It's far larger than the island so the expanded panel always fits; the
/// spare area is transparent and ignores the mouse. `IslandController` flips
/// `ignoresMouseEvents` off only while the pointer is over the island's shape.
final class IslandPanel: NSPanel {
  /// Room for the widest, tallest island (a question card at the largest text size).
  static let size = CGSize(width: 820, height: 560)

  init(contentView: NSView) {
    super.init(
      contentRect: CGRect(origin: .zero, size: Self.size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    isFloatingPanel = true
    level = .statusBar
    collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isMovable = false
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    acceptsMouseMovedEvents = true
    ignoresMouseEvents = true
    animationBehavior = .none
    self.contentView = contentView
  }

  /// Only while a prompt is being typed or VoiceOver has reached in.
  var keyAllowed = false

  override var canBecomeKey: Bool { keyAllowed }
  override var canBecomeMain: Bool { false }

  /// A normal window gets pushed below the menu bar; the island has to cover it.
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }

  /// On top: top centre of `screen`, flush with its top edge. On a side: the
  /// full height of that edge, flush with it (or with a Dock that sits there).
  func pin(to screen: NSScreen, placement: IslandPlacement) {
    let frame = screen.frame
    let visible = screen.visibleFrame
    let target = switch placement {
    case .top:
      CGRect(origin: CGPoint(x: (frame.midX - Self.size.width / 2).rounded(), y: frame.maxY - Self.size.height), size: Self.size)
    case .left:
      CGRect(x: visible.minX, y: frame.minY, width: EdgeMetrics.canvasWidth, height: frame.height)
    case .right:
      CGRect(x: visible.maxX - EdgeMetrics.canvasWidth, y: frame.minY, width: EdgeMetrics.canvasWidth, height: frame.height)
    }
    guard target != self.frame else { return }
    setFrame(target, display: true)
  }
}

extension NSScreen {
  /// The menu bar's height (or the notch's, when the menu bar hides itself)
  /// and a bottom Dock's: what a side island keeps clear of.
  var edgeInsets: (top: CGFloat, bottom: CGFloat) {
    let menuBar = frame.maxY - visibleFrame.maxY
    return (max(menuBar, safeAreaInsets.top, NSStatusBar.system.thickness), max(0, visibleFrame.minY - frame.minY))
  }

  /// The built-in display with the notch when it's on, else the one with the menu bar.
  static var island: NSScreen? {
    screens.first { $0.safeAreaInsets.top > 0 } ?? screens.first
  }
}

extension NotchMetrics {
  /// The notch from AppKit directly (1.x probed it with JXA).
  init(screen: NSScreen) {
    let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
    self.init(
      screenWidth: screen.frame.width,
      leftArea: screen.auxiliaryTopLeftArea?.width,
      rightArea: screen.auxiliaryTopRightArea?.width,
      topInset: screen.safeAreaInsets.top,
      // An auto-hidden menu bar reports no height; the island still needs one.
      menuBarHeight: menuBar > 0 ? menuBar : NSStatusBar.system.thickness
    )
  }
}

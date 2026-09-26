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

  /// Top centre of `screen`, flush with its top edge.
  func pin(to screen: NSScreen) {
    let frame = screen.frame
    let origin = CGPoint(x: (frame.midX - Self.size.width / 2).rounded(), y: frame.maxY - Self.size.height)
    setFrame(CGRect(origin: origin, size: Self.size), display: true)
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

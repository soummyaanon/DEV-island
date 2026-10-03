import AppKit
import IslandCore

/// The menu-bar icon: a small island pill drawn as a template image, so it
/// takes the menu bar's own ink in light, dark and tinted menu bars, like
/// Apple's icons. Outlined at rest, solid while agents work, with a dot when
/// one needs you; the count sits beside it in the menu bar's font.
enum TrayIcon {
  static func image(_ kind: TrayStatus.Kind) -> NSImage {
    let size = NSSize(width: 20, height: 14)
    let image = NSImage(size: size, flipped: false) { _ in
      let pill = NSRect(x: 1.5, y: 3.5, width: 15, height: 7)
      let path = NSBezierPath(roundedRect: pill, xRadius: 3.5, yRadius: 3.5)
      NSColor.black.set()
      switch kind {
      case .resting:
        path.lineWidth = 1.4
        path.stroke()
      case .working:
        path.fill()
      case .attention:
        path.fill()
        // A dot off the pill's end: something waits on you.
        NSBezierPath(ovalIn: NSRect(x: 16.2, y: 8.6, width: 3.6, height: 3.6)).fill()
      }
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription = switch kind {
    case .resting: "Agent Island"
    case .working: "Agent Island, agents working"
    case .attention: "Agent Island, an agent needs you"
    }
    return image
  }

  /// Applies `status` to the status item's button.
  static func apply(_ status: TrayStatus, to button: NSStatusBarButton?) {
    guard let button else { return }
    button.image = image(status.kind)
    button.imagePosition = status.count > 0 ? .imageLeading : .imageOnly
    let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize(for: .regular) - 1, weight: .medium)
    button.attributedTitle = NSAttributedString(string: status.count > 0 ? " \(status.count)" : "", attributes: [.font: font])
    button.toolTip = status.kind == .attention ? "\(status.count) need you" : status.kind == .working ? "\(status.count) working" : "Agent Island"
  }
}

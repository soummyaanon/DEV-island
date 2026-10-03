import SwiftUI

/// A round key, lit when on, with an optional one-word caption beneath.
struct CircleKey: View {
  let symbol: String
  var caption: String? = nil
  var on = false
  var tint = Palette.accent
  var size: CGFloat = 34
  var label: String? = nil
  let action: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 3) {
      Hovering { hovered in
        Button(action: action) {
          Glyph(symbol, size: size * 0.36)
            .foregroundStyle(on ? .white : hovered ? Palette.text : .white.opacity(0.78))
            .frame(width: size, height: size)
            .background(Circle().fill(on ? AnyShapeStyle(tint) : AnyShapeStyle(Color.white.opacity(hovered ? 0.15 : 0.08))))
            .overlay(Circle().strokeBorder(.white.opacity(on ? 0.18 : 0.06)))
            .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: on)
      }
      if let caption {
        Text(caption).islandFont(8.5, weight: .medium).foregroundStyle(Palette.textDim).lineLimit(1).fixedSize()
      }
    }
    .help(label ?? caption ?? "")
    .accessibilityLabel(label ?? caption ?? symbol)
    .accessibilityAddTraits(on ? .isSelected : [])
  }
}

/// Sinks a touch while pressed.
struct PressScale: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.92 : 1)
      .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
  }
}

/// Every tool's layout: a narrow left half and a wide right half, split by a hairline.
struct SplitPane<Left: View, Right: View>: View {
  var leftWidth: CGFloat = 150
  @ViewBuilder let left: Left
  @ViewBuilder let right: Right

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      left.frame(width: leftWidth, alignment: .top)
      Rectangle().fill(.white.opacity(0.07)).frame(width: 1).padding(.vertical, 4)
      right.frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// An SF Symbol, or one of macOS's own glyphs that SF Symbols doesn't offer:
/// "system:bluetooth" (AppKit's Bluetooth rune) and "system:airdrop" (Finder's
/// sidebar AirDrop glyph). Both are templates, so they tint like symbols.
struct Glyph: View {
  let name: String
  let size: CGFloat
  var weight: Font.Weight = .semibold

  init(_ name: String, size: CGFloat, weight: Font.Weight = .semibold) {
    self.name = name
    self.size = size
    self.weight = weight
  }

  static let bluetooth = "system:bluetooth"
  static let airdrop = "system:airdrop"

  private static let images: [String: NSImage] = {
    var out: [String: NSImage] = [:]
    if let rune = NSImage(named: NSImage.bluetoothTemplateName) { out[bluetooth] = rune }
    let sidebar = URL(filePath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/SidebarAirDrop.icns")
    if let icon = NSImage(contentsOf: sidebar) {
      icon.isTemplate = true
      out[airdrop] = icon
    }
    return out
  }()

  /// Where the system glyph is missing, a close SF Symbol.
  private var fallback: String {
    name == Self.bluetooth ? "dot.radiowaves.left.and.right" : "dot.radiowaves.up.forward"
  }

  var body: some View {
    if name.hasPrefix("system:") {
      if let image = Self.images[name] {
        Image(nsImage: image)
          .renderingMode(.template)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
          // The rune is tall and narrow; the AirDrop rings fill their square.
          .frame(width: size * (name == Self.bluetooth ? 1.45 : 1.25), height: size * (name == Self.bluetooth ? 1.45 : 1.25))
      } else {
        Image(systemName: fallback).font(.system(size: size, weight: weight))
      }
    } else {
      Image(systemName: name).font(.system(size: size, weight: weight))
    }
  }
}

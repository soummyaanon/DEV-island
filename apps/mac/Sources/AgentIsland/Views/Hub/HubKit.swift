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
          Image(systemName: symbol)
            .font(.system(size: size * 0.36, weight: .semibold))
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

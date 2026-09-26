import SwiftUI

/// The footer's fields (`.prompt-bar`): a quiet recessed pill, faintly top-lit,
/// with a hairline and no focus ring. The field's glow is the focus state.
struct FieldPill: ViewModifier {
  let focused: Bool

  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    let increased = contrast == .increased
    content
      .background {
        if increased {
          Capsule().fill(.black)
        } else if reduceTransparency {
          Capsule().fill(Color(hex: 0x16161A))
        } else {
          Capsule().fill(LinearGradient(
            colors: [.white.opacity(focused ? 0.09 : 0.07), .white.opacity(focused ? 0.045 : 0.035)],
            startPoint: .top, endPoint: .bottom
          ))
        }
      }
      .overlay(Capsule().strokeBorder(.white.opacity(increased ? 0.5 : 0.07)))
      // The top edge catches the light.
      .overlay(Capsule().inset(by: 1).stroke(.white.opacity(0.05), lineWidth: 1).mask(alignment: .top) { Rectangle().frame(height: 3) })
      .overlay {
        if increased && focused { Capsule().inset(by: -2).strokeBorder(Palette.accent, lineWidth: 2) }
      }
      .animation(.easeInOut(duration: 0.18), value: focused)
  }
}

/// The placeholder, in the fields' own dim ink.
func fieldPrompt(_ text: String) -> Text {
  Text(text).foregroundColor(.white.opacity(0.34))
}

/// Send (and stop): a small round key that lights up once there's something to send.
struct SendKey: ButtonStyle {
  let ready: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(ready ? .white : .white.opacity(0.35))
      .background(
        Circle().fill(ready
          ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x6F8DFF), Color(hex: 0x5566E8)], startPoint: .top, endPoint: .bottom))
          : AnyShapeStyle(Color.white.opacity(0.06)))
      )
      // Lit from above, casting a little blue below.
      .overlay {
        if ready {
          Circle().inset(by: 0.5).stroke(.white.opacity(0.3), lineWidth: 1).mask(alignment: .top) { Rectangle().frame(height: 3) }
        }
      }
      .shadow(color: ready ? Color(red: 40 / 255, green: 60 / 255, blue: 200 / 255).opacity(0.45) : .clear, radius: 1.5, y: 1)
      .scaleEffect(configuration.isPressed ? 0.94 : 1)
      .animation(.easeOut(duration: 0.09), value: configuration.isPressed)
      .animation(.easeInOut(duration: 0.15), value: ready)
  }
}

/// `.ctl.icon`: a dim glyph that lights, on a faint tile, under the pointer.
struct ControlStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    Hovering { hovered in
      configuration.label
        .foregroundStyle(hovered ? Palette.text : Palette.textDim)
        .padding(.init(top: 4, leading: 6, bottom: 4, trailing: 6))
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(hovered ? 0.07 : 0)))
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
  }
}

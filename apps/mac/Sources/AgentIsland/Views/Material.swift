import AppKit
import SwiftUI

/// The glass under the open panel: macOS 26's Liquid Glass (looked up by
/// name, configured the way the sidecar did), else a behind-window blur.
/// Always dark: in the light appearance the material lifts toward white.
struct GlassMaterial: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view: NSView
    if let glass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
      view = glass.init(frame: .zero)
      // Dark glass, not frosted grey: only a hint of the wallpaper's light.
      view.setValue(NSColor.black.withAlphaComponent(0.9), forKey: "tintColor")
    } else {
      let blur = NSVisualEffectView(frame: .zero)
      blur.material = .hudWindow
      blur.blendingMode = .behindWindow
      blur.state = .active
      view = blur
    }
    view.appearance = NSAppearance(named: .darkAqua)
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {}
}

/// The island's type scale (Settings → Accessibility → Text size): macOS has
/// no Dynamic Type for fixed-size text, so the island carries its own.
private struct UIScaleKey: EnvironmentKey {
  static let defaultValue: CGFloat = 1
}

/// How often a looping drawing (bots, orbs, weather, glows) redraws. The
/// wings ask for less (`Band`).
private struct MotionFrameRateKey: EnvironmentKey {
  static let defaultValue: Double = 30
}

extension EnvironmentValues {
  var uiScale: CGFloat {
    get { self[UIScaleKey.self] }
    set { self[UIScaleKey.self] = newValue }
  }

  var motionFrameRate: Double {
    get { self[MotionFrameRateKey.self] }
    set { self[MotionFrameRateKey.self] = newValue }
  }
}

private struct IslandFont: ViewModifier {
  let size: CGFloat
  let weight: Font.Weight
  let design: Font.Design
  @Environment(\.uiScale) private var scale

  func body(content: Content) -> some View {
    content.font(.system(size: size * scale, weight: weight, design: design))
  }
}

extension View {
  /// A system font at `size` points times the island's text scale.
  func islandFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
    modifier(IslandFont(size: size, weight: weight, design: design))
  }
}

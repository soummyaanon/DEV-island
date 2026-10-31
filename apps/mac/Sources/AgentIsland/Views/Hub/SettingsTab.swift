import IslandCore
import SwiftUI

/// The island's own settings, a swipe away: where it sits and how it opens on
/// the left, the everyday switches as round keys on the right, and the full
/// Settings window under both.
struct SettingsTab: View {
  let model: IslandModel

  var body: some View {
    let settings = model.settings
    VStack(spacing: 10) {
      SplitPane(leftWidth: 168) {
        VStack(alignment: .leading, spacing: 9) {
          Chooser(title: "Position", options: IslandPlacement.allCases, label: \.label, selected: settings.placement) { placement in
            model.changeSettings { $0.placement = placement }
          }
          Chooser(title: "Open with", options: IslandSettings.OpenWith.allCases, label: { $0 == .swipe ? "Swipe" : "Hover" }, selected: settings.openWith) { open in
            model.changeSettings { $0.openWith = open }
          }
          Chooser(title: "Sessions", options: IslandSettings.SessionView.allCases, label: { $0 == .compact ? "Compact" : "Detailed" }, selected: settings.sessionView) { view in
            model.changeSettings { $0.sessionView = view }
          }
        }
      } right: {
        Grid(horizontalSpacing: 14, verticalSpacing: 8) {
          GridRow {
            key("speaker.wave.2.fill", "Sounds", \.sounds)
            key("hand.tap.fill", "Haptics", \.haptics)
            // The clock that applies where the island is now.
            key("clock.fill", "Clock", model.placement.isSide ? \.edgeClock : \.menuBarClock)
          }
          GridRow {
            key("battery.75percent", "Battery", \.battery)
            key("cloud.sun.fill", "Weather", \.weather)
            key("circle.lefthalf.filled", "Glass", \.glass)
          }
          GridRow {
            key("party.popper.fill", "Confetti", \.tokenConfetti)
            key("hand.wave.fill", "Greeting", \.greeting)
            key("hammer.fill", "Dev strip", \.devTools)
          }
        }
        .frame(maxWidth: .infinity)
      }
      Button { model.openSettings() } label: {
        Label("Open full Settings…", systemImage: "gearshape")
          .islandFont(10.5, weight: .semibold)
          .foregroundStyle(Palette.text)
          .padding(.horizontal, 14)
          .padding(.vertical, 6)
          .background(Capsule().fill(.white.opacity(0.08)))
          .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
          .contentShape(Capsule())
      }
      .buttonStyle(PressScale())
      .frame(maxWidth: .infinity)
    }
  }

  /// A round key bound to one switch.
  private func key(_ symbol: String, _ caption: String, _ path: WritableKeyPath<IslandSettings, Bool>) -> some View {
    CircleKey(symbol: symbol, caption: caption, on: model.settings[keyPath: path], size: 32) {
      model.changeSettings { $0[keyPath: path].toggle() }
    }
  }
}

/// A small titled segmented control: a capsule of choices, the picked one lit.
private struct Chooser<Option: Hashable>: View {
  let title: String
  let options: [Option]
  let label: (Option) -> String
  let selected: Option
  let pick: (Option) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).islandFont(9, weight: .medium).foregroundStyle(Palette.textDim)
      HStack(spacing: 2) {
        ForEach(options, id: \.self) { option in
          let on = option == selected
          Button { pick(option) } label: {
            Text(label(option))
              .islandFont(9.5, weight: on ? .semibold : .medium)
              .foregroundStyle(on ? .black : Palette.text.opacity(0.8))
              .lineLimit(1)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 4)
              .background(Capsule().fill(on ? Color.white.opacity(0.92) : .clear))
              .contentShape(Capsule())
          }
          .buttonStyle(PressScale())
          .accessibilityAddTraits(on ? .isSelected : [])
        }
      }
      .padding(2)
      .background(Capsule().fill(.white.opacity(0.07)))
      .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: selected)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }
}

import AppKit
import IslandCore
import SwiftUI

/// What the wings show for quick access: small, one glance, same type and
/// motion as the agents' wings.
enum QuickPalette {
  static let meeting = Color(hex: 0x4ECB8D)
  static let muted = Color(hex: 0xFF5F56)
  static let focus = Color(hex: 0xFF7A59)
  static let rest = Color(hex: 0x4ECB8D)
  static let timer = Color(hex: 0xFFB020)

  static func timer(_ timer: IslandTimer) -> Color {
    switch (timer.kind, timer.phase) {
    case (.countdown, _): Self.timer
    case (.pomodoro, .focus): focus
    case (.pomodoro, _): rest
    }
  }
}

/// A timer's progress as a thin ring that empties as it runs.
struct TimerRing: View {
  let timer: IslandTimer
  let now: Date
  var size: CGFloat = 14
  var lineWidth: CGFloat = 2

  var body: some View {
    let tint = QuickPalette.timer(timer)
    ZStack {
      Circle().stroke(tint.opacity(0.22), lineWidth: lineWidth)
      Circle()
        .trim(from: 0, to: 1 - timer.progress(at: now))
        .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        .rotationEffect(.degrees(-90))
      if timer.isPaused {
        Image(systemName: "pause.fill").font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(tint)
      } else if timer.kind == .pomodoro {
        Circle().fill(tint).frame(width: size * 0.28, height: size * 0.28)
      }
    }
    .frame(width: size, height: size)
  }
}

/// Album art, small and rounded; a note glyph until it arrives.
struct ArtworkView: View {
  let image: NSImage?
  var size: CGFloat = 18
  var radius: CGFloat = 4

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
      } else {
        LinearGradient(colors: [Color(hex: 0x3A3A44), Color(hex: 0x1C1C22)], startPoint: .top, endPoint: .bottom)
          .overlay(Image(systemName: "music.note").font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white.opacity(0.6)))
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
  }
}

/// Four bars that dance while music plays and rest flat when paused.
struct EqualizerBars: View {
  let playing: Bool
  let tint: Color
  let paused: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 15, paused: !playing || paused || reduceMotion)) { timeline in
      let t = timeline.date.timeIntervalSinceReferenceDate
      HStack(alignment: .center, spacing: 2) {
        ForEach(0..<4, id: \.self) { index in
          let phase = Double(index) * 1.7
          let level = playing && !reduceMotion ? 0.35 + 0.65 * abs(sin(t * (5.2 + Double(index) * 1.3) + phase)) : 0.3
          Capsule().fill(tint).frame(width: 2.4, height: max(3, 13 * level))
        }
      }
      .frame(height: 14)
    }
  }
}

/// A live call: a green camera (red slash when muted).
struct CallBadge: View {
  let muted: Bool?

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      Image(systemName: "video.fill")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(QuickPalette.meeting)
      if muted == true {
        Image(systemName: "mic.slash.fill")
          .font(.system(size: 7, weight: .bold))
          .foregroundStyle(QuickPalette.muted)
          .padding(1)
          .background(Circle().fill(.black))
          .offset(x: 4, y: 3)
      }
    }
    .modifier(CountPulse(period: 1.6, active: true, reducible: true))
  }
}

/// The time, for when the menu bar (and its clock) is hidden.
struct WingClock: View {
  var body: some View {
    TimelineView(.everyMinute) { timeline in
      // No AM/PM: the wing has room for the digits alone, and they read at a glance.
      Text(timeline.date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
        .islandFont(12.5, weight: .bold)
        .monospacedDigit()
        .foregroundStyle(.white)
        .lineLimit(1)
        .fixedSize()
    }
  }
}

/// The right wing's live text for a call or timer: it ticks each second.
struct WingTicker: View {
  let text: (Date) -> String
  let tint: Color

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { timeline in
      Text(text(timeline.date))
        .islandFont(11, weight: .bold)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(tint)
        .contentTransition(.numericText(countsDown: true))
    }
  }
}

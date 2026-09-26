import IslandCore
import SwiftUI

/// Colours and motion from 1.x's island.css and motion.ts.
enum Palette {
  static let text = Color.white.opacity(0.94)
  static let textDim = Color.white.opacity(0.46)
  /// The fields' insertion point (`.prompt-input { caret-color }`).
  static let caret = Color(hex: 0x8FB3FF)
  static let done = Color(hex: 0x4ECB8D)
  static let failed = Color(hex: 0xFF5F56)
  static let working = Color(hex: 0x5BA8FF)
  static let starting = Color(hex: 0x8FB8FF)
  static let waiting = Color(hex: 0xFFB020)
  static let idle = Color.white.opacity(0.32)
  static let accent = Color(hex: 0x74B7FF)

  /// A session state's colour: dots, badges, the wings' tint.
  static func state(_ state: SessionState) -> Color {
    switch state {
    case .working: working
    case .starting: starting
    case .waitingForApproval: waiting
    case .done: done
    case .failed: failed
    case .idle: idle
    }
  }

  /// The same, opaque, for tinting the orbs (canvas ink can't be translucent grey).
  static func tint(_ state: SessionState) -> Color {
    state == .idle ? Color(hex: 0x9A9A9A) : self.state(state)
  }

  /// The charger moment's colour follows the Energy Mode: green, Low Power a
  /// calm amber, High Power cyan. Pulling the plug is plain white.
  static func charge(_ moment: PowerActivity) -> Color {
    guard moment.kind == .plugged else { return Color(white: 0xEC / 255) }
    return switch moment.energyMode {
    case .automatic: done
    case .low: Color(red: 1, green: 0xD6 / 255, blue: 0x0A / 255)
    case .high: Color(red: 0x64 / 255, green: 0xD2 / 255, blue: 1)
    }
  }

  /// `hsl(hue 85% 55%)`, the battery ring's arc.
  static func battery(hue: Double, saturation: Double = 0.85, lightness: Double = 0.55) -> Color {
    // HSL → HSB: SwiftUI only speaks the latter.
    let brightness = lightness + saturation * min(lightness, 1 - lightness)
    let hsbSaturation = brightness == 0 ? 0 : 2 * (1 - lightness / brightness)
    return Color(hue: hue / 360, saturation: hsbSaturation, brightness: brightness)
  }
}

enum Motion {
  /// Opening: quick and steady, under 1% overshoot.
  static let open = Animation.interpolatingSpring(mass: 1, stiffness: 420, damping: 34)
  /// Adjusting while already open: firm, no visible overshoot.
  static let settle = Animation.interpolatingSpring(mass: 1, stiffness: 380, damping: 36)
  /// Leaving is faster than arriving, and starts moving at once.
  static let close = Animation.timingCurve(0.3, 0, 0.8, 0.15, duration: 0.18)
  /// The battery arc gliding to a new level.
  static let level = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 1)
}

/// 1.x's CSS mount animations: each plays once when its element appears (a
/// remount replays it), on the tokens' curves, applied per keyframe segment.
struct Entrance: ViewModifier {
  enum Kind {
    /// `row-in`: rows, cards and turns fade in.
    case rowIn
    /// `count-roll`: a value rolls up 5 pt into place.
    case countRoll
    /// `sprite-pop`: scale 0.8 → 1.03 → 1 as it fades in.
    case spritePop
    /// `work-bot-in`: a bot grows in from 0.6.
    case workBotIn
    /// `greet-rise`: 6 pt up as it fades in, ease-out, over the seconds given.
    case rise(Double)

    var duration: Double {
      switch self {
      case .rowIn: 0.22
      case .countRoll: 0.3
      case .spritePop: 0.4
      case .workBotIn: 0.35
      case let .rise(seconds): seconds
      }
    }
  }

  let kind: Kind
  var delay = 0.0
  /// 1.x stops some entrances under Reduce Motion, not all.
  var reducible = true

  private let started = State(initialValue: false)
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    let skip = reducible && reduceMotion
    content
      .modifier(EntranceEffect(kind: kind, progress: started.wrappedValue || skip ? 1 : 0))
      .onAppear {
        guard !skip else { return }
        withAnimation(.linear(duration: kind.duration).delay(delay)) { started.wrappedValue = true }
      }
  }
}

nonisolated struct EntranceEffect: ViewModifier, Animatable {
  let kind: Entrance.Kind
  var progress: Double

  var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  static let easeOut = CubicBezier(0, 0, 0.58, 1)
  static let springOpen = CubicBezier(0.34, 1.2, 0.64, 1)
  static let springSettle = CubicBezier(0.22, 1, 0.36, 1)

  func body(content: Content) -> some View {
    let p = min(max(progress, 0), 1)
    switch kind {
    case .rowIn:
      content.opacity(Self.easeOut.y(at: p))
    case .countRoll:
      let s = Self.springSettle.y(at: p)
      content.offset(y: 5 * (1 - s)).opacity(min(1, s))
    case .spritePop:
      // Two segments, each on the open spring: 0 → 60 % → 100 %.
      let first = p < 0.6
      let s = Self.springOpen.y(at: first ? p / 0.6 : (p - 0.6) / 0.4)
      let scale = first ? 0.8 + 0.23 * s : 1.03 - 0.03 * s
      content.scaleEffect(scale).opacity(first ? min(1, max(0, s)) : 1)
    case .workBotIn:
      let s = Self.springSettle.y(at: p)
      content.scaleEffect(0.6 + 0.4 * s).opacity(min(1, s))
    case .rise:
      let s = Self.easeOut.y(at: p)
      content.offset(y: 6 * (1 - s)).opacity(s)
    }
  }
}

/// `count-pulse`: opacity breathing 0.55 ↔ 1, ease-in-out, alternate.
struct CountPulse: ViewModifier {
  var period = 1.2
  var active = true
  /// Most of 1.x's pulses keep going under Reduce Motion.
  var reducible = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    if active && !(reducible && reduceMotion) {
      content.phaseAnimator([0.55, 1.0]) { view, opacity in view.opacity(opacity) } animation: { _ in .easeInOut(duration: period) }
    } else {
      content
    }
  }
}

/// Whether the pointer is over the view, for hover styles.
struct Hovering<Label: View>: View {
  @ViewBuilder let label: (Bool) -> Label
  private let hovered = State(initialValue: false)

  var body: some View {
    label(hovered.wrappedValue).onHover { hovered.wrappedValue = $0 }
  }
}

extension View {
  /// `sprite-pop` on arrival; leaving is instant, as in 1.x.
  func pop() -> some View {
    modifier(Entrance(kind: .spritePop)).transition(.identity)
  }
}

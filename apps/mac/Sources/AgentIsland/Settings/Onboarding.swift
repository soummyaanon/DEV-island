import AppKit
import IslandCore
import SwiftUI

// 1.x's onboarding.tsx + onboarding.css + window-chrome.css.

@Observable
final class OnboardingState {
  static var flag: URL { IslandSettings.userData.appending(path: "onboarded") }

  var accessibilityTrusted = Accessibility.isTrusted
  var openAtLogin = LoginItem.isEnabled

  func refresh() {
    if accessibilityTrusted != Accessibility.isTrusted { accessibilityTrusted = Accessibility.isTrusted }
    if openAtLogin != LoginItem.isEnabled { openAtLogin = LoginItem.isEnabled }
  }
}

/// Frameless and transparent: the SwiftUI card is the whole window. Borderless
/// windows refuse key status and ⌘W by default, so this one opts back in.
final class OnboardingWindow: NSWindow {
  static let size = NSSize(width: 640, height: 520)

  init() {
    super.init(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: false)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    isMovableByWindowBackground = true
    isReleasedWhenClosed = false
    title = "Welcome to Agent Island"
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  override func performClose(_ sender: Any?) {
    if delegate?.windowShouldClose?(self) ?? true { close() }
  }
}

/// The `:root` tokens, dark and light.
private struct Tokens {
  let edge, text, textDim, accent, working, done, surface, surfaceEdge, keyBg, buttonText, buttonBg, buttonHover: Color
  let window: LinearGradient

  static func of(_ scheme: ColorScheme) -> Tokens {
    scheme == .light
      ? Tokens(
        edge: Color(hex: 0x26476C, opacity: 0.16), text: Color(hex: 0x182233), textDim: Color(hex: 0x182233, opacity: 0.58),
        accent: Color(hex: 0x397FC9), working: Color(hex: 0x397FC9), done: Color(hex: 0x2F9464),
        surface: Color.white.opacity(0.72), surfaceEdge: Color(hex: 0x26476C, opacity: 0.13), keyBg: Color(hex: 0x397FC9, opacity: 0.11),
        buttonText: .white, buttonBg: Color(hex: 0x397FC9), buttonHover: Color(hex: 0x2F72BA),
        window: LinearGradient(colors: [Color(hex: 0xF8FBFF), Color(hex: 0xEDF3F9)], startPoint: .top, endPoint: .bottom)
      )
      : Tokens(
        edge: Color.white.opacity(0.09), text: Color.white.opacity(0.94), textDim: Color.white.opacity(0.5),
        accent: Color(hex: 0x74B7FF), working: Color(hex: 0x74B7FF), done: Color(hex: 0x4ECB8D),
        surface: Color.white.opacity(0.04), surfaceEdge: Color.white.opacity(0.07), keyBg: Color.white.opacity(0.09),
        buttonText: Color(hex: 0x101923), buttonBg: Color(hex: 0xE7F2FF), buttonHover: .white,
        window: LinearGradient(
          stops: [.init(color: Color(hex: 0x171B22), location: 0), .init(color: Color(hex: 0x0C0F14), location: 0.6), .init(color: Color(hex: 0x080A0D), location: 1)],
          startPoint: .top, endPoint: .bottom
        )
      )
  }
}

private enum Curves {
  /// `--spring`: cubic-bezier(0.34, 1.2, 0.64, 1).
  static func spring(_ duration: Double) -> Animation { .timingCurve(0.34, 1.2, 0.64, 1, duration: duration) }
  /// CSS `ease`.
  static func ease(_ duration: Double) -> Animation { .timingCurve(0.25, 0.1, 0.25, 1, duration: duration) }
}

/// A CSS numeric weight (550, 640, 750…) as a system font.
private func cssFont(_ size: CGFloat, _ weight: Double) -> Font {
  Font(nsFont(size, weight))
}

private func nsFont(_ size: CGFloat, _ weight: Double) -> NSFont {
  // CSS weight → NSFont.Weight, interpolated between the named stops.
  let stops: [(Double, CGFloat)] = [(100, -0.8), (200, -0.6), (300, -0.4), (400, 0), (500, 0.23), (600, 0.3), (700, 0.4), (800, 0.56), (900, 0.62)]
  let w = min(max(weight, 100), 900)
  var value: CGFloat = 0
  for (a, b) in zip(stops, stops.dropFirst()) where w >= a.0 && w <= b.0 {
    value = a.1 + (b.1 - a.1) * CGFloat((w - a.0) / (b.0 - a.0))
    break
  }
  return NSFont.systemFont(ofSize: size, weight: NSFont.Weight(value))
}

/// The first-run window: a live mock of the island, two optional steps, and a way out.
struct OnboardingView: View {
  let state: OnboardingState
  let finish: () -> Void

  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let shown = State(initialValue: false)

  var body: some View {
    let t = Tokens.of(scheme)
    let still = reduceMotion
    let on = shown.wrappedValue || still
    VStack(spacing: 0) {
      IslandDemo(working: t.working, done: t.done, still: still)
        .padding(.top, 6)
        .rise(on, delay: 0.08, still: still)
      Text("Agent Island")
        .font(cssFont(27, 750))
        .tracking(-0.54)
        .foregroundStyle(t.text)
        .padding(.top, 20)
        .rise(on, delay: 0.16, still: still)
      subtitle(t)
        .padding(.top, 8)
        .rise(on, delay: 0.24, still: still)
      VStack(spacing: 8) {
        Step(tokens: t, title: "Answer from the notch", detail: "Accessibility lets Agent Island press the option key in your terminal for you.", done: state.accessibilityTrusted) {
          Accessibility.request()
        }
        Step(tokens: t, title: "Always on your island", detail: "Start automatically when you log in — silent, no Dock, no menu bar.", done: state.openAtLogin) {
          LoginItem.isEnabled = true
          state.refresh()
        }
      }
      .frame(maxWidth: 480)
      .padding(.top, 18)
      .rise(on, delay: 0.32, still: still)
      Button("Take me to the island", action: finish)
        .buttonStyle(StartButton(accent: t.accent))
        .padding(.top, 20)
        .rise(on, delay: 0.40, still: still)
      Text("Hover the notch anytime for sessions, sounds, and quit.")
        .font(.system(size: 10.5))
        .foregroundStyle(t.textDim)
        .padding(.top, 10)
        .rise(on, delay: 0.48, still: still)
      Spacer(minLength: 0)
    }
    .padding(.init(top: 26, leading: 44, bottom: 26, trailing: 44))
    .frame(width: OnboardingWindow.size.width, height: OnboardingWindow.size.height)
    .background(t.window)
    .overlay(alignment: .top) { DragStrip().frame(height: 40) }
    .overlay(alignment: .topLeading) { TrafficLights(close: finish).padding(14) }
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(t.edge, lineWidth: 1))
    // card-in
    .opacity(on ? 1 : 0)
    .scaleEffect(on ? 1 : 0.96)
    .offset(y: on ? 0 : 10)
    .animation(still ? nil : Curves.spring(0.5), value: on)
    .onAppear { shown.wrappedValue = true }
  }

  private func subtitle(_ t: Tokens) -> some View {
    (Text("Your coding agents live at the notch. Claude Code, Codex, and Cursor sessions appear the moment they start — watch them work, approve with ")
      + kbd("⌘Y", t) + Text(", answer questions with ") + kbd("⌘1–9", t)
      + Text(", and jump back to the right terminal in one click. Everything stays on this Mac."))
      .font(.system(size: 12.5))
      .lineSpacing(12.5 * 1.6 - nsFont(12.5, 400).lineHeight)
      .foregroundStyle(t.textDim)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 470)
      .fixedSize(horizontal: false, vertical: true)
  }

  /// `<kbd>`: a pill can't live inside a Text run, so it's drawn and inlined as an image.
  private func kbd(_ key: String, _ t: Tokens) -> Text {
    let font = nsFont(11, 650)
    let pill = Text(key)
      .font(Font(font))
      .foregroundStyle(t.text)
      .frame(height: font.ascender - font.descender)
      .padding(.horizontal, 5)
      .background(RoundedRectangle(cornerRadius: 5).fill(t.keyBg))
    let renderer = ImageRenderer(content: pill)
    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
    guard let image = renderer.nsImage else { return Text(key).font(Font(font)).foregroundColor(t.text) }
    return Text(Image(nsImage: image)).baselineOffset(font.descender)
  }

  private struct Step: View {
    let tokens: Tokens
    let title: String
    let detail: String
    let done: Bool
    let enable: () -> Void

    var body: some View {
      HStack(spacing: 14) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(cssFont(12.5, 640)).foregroundStyle(tokens.text)
          Text(detail)
            .font(.system(size: 11))
            .lineSpacing(max(0, 11 * 1.45 - nsFont(11, 400).lineHeight))
            .foregroundStyle(tokens.textDim)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
        if done {
          Text("✓ enabled").font(cssFont(11.5, 650)).foregroundStyle(tokens.done)
        } else {
          Button("Enable", action: enable).buttonStyle(StepButton(tokens: tokens))
        }
      }
      .padding(.init(top: 11, leading: 14, bottom: 11, trailing: 14))
      .background(RoundedRectangle(cornerRadius: 13).fill(tokens.surface))
      .overlay(
        RoundedRectangle(cornerRadius: 13)
          .strokeBorder(done ? Color(hex: 0x4ECB8D, opacity: 0.35) : tokens.surfaceEdge, lineWidth: 1)
          .animation(Curves.ease(0.3), value: done)
      )
    }
  }
}

private extension NSFont {
  var lineHeight: CGFloat { ascender - descender + leading }
}

private extension View {
  /// `rise`: 0.6s spring, from 14px down and transparent, held until its delay.
  func rise(_ on: Bool, delay: Double, still: Bool) -> some View {
    opacity(on ? 1 : 0)
      .offset(y: on ? 0 : 14)
      .animation(still ? nil : Curves.spring(0.6).delay(delay), value: on)
  }
}

// MARK: Buttons

/// `.ob-btn`.
private struct StepButton: ButtonStyle {
  let tokens: Tokens

  func makeBody(configuration: Configuration) -> some View {
    Face(configuration: configuration, tokens: tokens)
  }

  private struct Face: View {
    let configuration: Configuration
    let tokens: Tokens
    private let hovering = State(initialValue: false)

    var body: some View {
      configuration.label
        .font(cssFont(11.5, 650))
        .foregroundStyle(tokens.buttonText)
        .padding(.init(top: 6, leading: 14, bottom: 6, trailing: 14))
        .background(RoundedRectangle(cornerRadius: 9).fill(hovering.wrappedValue ? tokens.buttonHover : tokens.buttonBg))
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .animation(Curves.ease(0.08), value: configuration.isPressed)
        .onHover { hovering.wrappedValue = $0 }
        .fixedSize()
    }
  }
}

/// `.ob-start`.
private struct StartButton: ButtonStyle {
  let accent: Color

  func makeBody(configuration: Configuration) -> some View {
    Face(configuration: configuration, accent: accent)
  }

  private struct Face: View {
    let configuration: Configuration
    let accent: Color
    private let hovering = State(initialValue: false)

    var body: some View {
      // :active's transform replaces :hover's, as in CSS.
      let pressed = configuration.isPressed
      configuration.label
        .font(cssFont(13.5, 680))
        .foregroundStyle(Color(hex: 0xF8FBFF))
        .padding(.init(top: 11, leading: 26, bottom: 11, trailing: 26))
        .background(RoundedRectangle(cornerRadius: 12).fill(accent))
        .shadow(color: accent.opacity(0.3), radius: 9, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .scaleEffect(pressed ? 0.98 : 1)
        .offset(y: !pressed && hovering.wrappedValue ? -1 : 0)
        .animation(Curves.spring(0.1), value: pressed)
        .animation(Curves.spring(0.1), value: hovering.wrappedValue)
        .onHover { hovering.wrappedValue = $0 }
    }
  }
}

// MARK: Window chrome

/// macOS-style close control for the frameless card; the glyph shows on hover.
private struct TrafficLights: View {
  let close: () -> Void
  private let hovering = State(initialValue: false)

  var body: some View {
    HStack(spacing: 8) {
      Button(action: close) {
        Circle()
          .fill(Color(hex: 0xFF5F57))
          .overlay(Circle().strokeBorder(.black.opacity(0.2), lineWidth: 0.5))
          .overlay {
            Path { p in
              p.move(to: CGPoint(x: 2.2, y: 2.2)); p.addLine(to: CGPoint(x: 7.8, y: 7.8))
              p.move(to: CGPoint(x: 7.8, y: 2.2)); p.addLine(to: CGPoint(x: 2.2, y: 7.8))
            }
            .applying(CGAffineTransform(scaleX: 0.8, y: 0.8))
            .stroke(.black.opacity(0.55), lineWidth: 1.4 * 0.8)
            .frame(width: 8, height: 8)
            .opacity(hovering.wrappedValue ? 1 : 0)
          }
          .frame(width: 12, height: 12)
      }
      .buttonStyle(LightPress())
      .accessibilityLabel("Close window")
    }
    .onHover { hovering.wrappedValue = $0 }
  }

  /// `.tl:active { filter: brightness(0.8) }`.
  private struct LightPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
      configuration.label.brightness(configuration.isPressed ? -0.2 : 0)
    }
  }
}

/// The top 40px drags the window, like 1.x's `-webkit-app-region: drag` strip.
private struct DragStrip: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { Strip() }
  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class Strip: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override var mouseDownCanMoveWindow: Bool { true }
  }
}

// MARK: Demo

/// A black island with the agents at work and three rows under it.
private struct IslandDemo: View {
  let working: Color
  let done: Color
  let still: Bool
  private let start = State(initialValue: Date.now)

  var body: some View {
    TimelineView(.animation(paused: still)) { timeline in
      let time = still ? 0 : timeline.date.timeIntervalSince(start.wrappedValue)
      island(time)
        .scaleEffect(Self.breathe(time))
    }
    .accessibilityHidden(true)
  }

  private func island(_ time: TimeInterval) -> some View {
    let shape = UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16)
    return VStack(spacing: 0) {
      HStack {
        HStack(spacing: 6) {
          sprite(.claudeCode)
            .rotationEffect(.degrees(Self.cycle(time, 8) * 360))
            .scaleEffect(Self.sparkScale(time))
          sprite(.codex)
            .rotationEffect(.degrees(Self.cycle(time, 4) * 360))
          sprite(.cursor)
            .offset(y: Self.bob(time))
        }
        Spacer()
        Text("3").font(.system(size: 11, weight: .bold)).foregroundStyle(working)
      }
      .padding(.horizontal, 12)
      .frame(height: 32)
      VStack(spacing: 2) {
        row("fix auth bug", "claude · 28m", working, glow: true)
        row("backend server", "codex · 1h", working, glow: true)
        row("optimize queries", "cursor · done", done, glow: false)
      }
      .padding(.init(top: 2, leading: 8, bottom: 2, trailing: 8))
    }
    .padding(.bottom, 8)
    .frame(width: 300)
    .background(shape.fill(.black))
    // No top border: the island hangs from the notch.
    .overlay(shape.strokeBorder(.white.opacity(0.1), lineWidth: 1).padding(.top, -1))
    .clipShape(shape)
  }

  private func sprite(_ agent: AgentKind) -> some View {
    AgentMarkView(agent: agent, size: 13, color: working)
      .shadow(color: working, radius: 1.5)
  }

  private func row(_ name: String, _ meta: String, _ color: Color, glow: Bool) -> some View {
    HStack(spacing: 8) {
      Circle().fill(color).frame(width: 6, height: 6)
        .shadow(color: glow ? color : .clear, radius: 2.5)
      Text(name).font(cssFont(11.5, 550)).foregroundStyle(Color.white.opacity(0.94))
      Spacer(minLength: 0)
      Text(meta).font(.system(size: 9.5)).foregroundStyle(Color.white.opacity(0.5))
    }
    .padding(.init(top: 5, leading: 8, bottom: 5, trailing: 8))
    .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.03)))
  }

  /// Progress 0..<1 through a looping animation of `period` seconds.
  private static func cycle(_ time: TimeInterval, _ period: Double) -> Double {
    time.truncatingRemainder(dividingBy: period) / period
  }

  /// `spark-work`'s scale: 1 → .9 → 1 → .9 → 1, linear between quarters.
  private static func sparkScale(_ time: TimeInterval) -> Double {
    let quarters = cycle(time, 8) * 4
    let frac = quarters - quarters.rounded(.down)
    return Int(quarters) % 2 == 0 ? 1 - 0.1 * frac : 0.9 + 0.1 * frac
  }

  /// `bob`: 2s ease-in-out alternate, +0.8px ↔ -0.8px.
  private static func bob(_ time: TimeInterval) -> Double {
    let half = time.truncatingRemainder(dividingBy: 4) / 2
    let eased = UnitCurve.easeInOut.value(at: half < 1 ? half : 2 - half)
    return 0.8 - 1.6 * eased
  }

  /// `island-breathe`: 5s ease-in-out, 1 → 1.02 → 1.
  private static func breathe(_ time: TimeInterval) -> Double {
    let half = cycle(time, 5) * 2
    return 1 + 0.02 * UnitCurve.easeInOut.value(at: half < 1 ? half : 2 - half)
  }
}

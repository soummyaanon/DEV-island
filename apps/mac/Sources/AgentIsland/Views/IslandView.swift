import IslandCore
import SwiftUI

/// The island's silhouette, filling a box one ear wider than the body on each
/// side. SwiftUI draws shapes off the main actor, so it's nonisolated.
nonisolated struct IslandShape: Shape {
  var corner: CGFloat

  var animatableData: CGFloat {
    get { corner }
    set { corner = newValue }
  }

  func path(in rect: CGRect) -> Path {
    let outline = IslandOutline(width: rect.width - 2 * IslandOutline.earRadius, height: rect.height, corner: corner)
    return Path(outline.silhouette()).offsetBy(dx: rect.minX, dy: rect.minY)
  }
}

/// The island's edge alone — ears, sides and bottom, never the bezel along the top.
nonisolated struct IslandEdge: Shape {
  var corner: CGFloat

  var animatableData: CGFloat {
    get { corner }
    set { corner = newValue }
  }

  func path(in rect: CGRect) -> Path {
    let outline = IslandOutline(width: rect.width - 2 * IslandOutline.earRadius, height: rect.height, corner: corner)
    return Path(outline.edge()).offsetBy(dx: rect.minX, dy: rect.minY)
  }
}

/// Collapsed, a fixed width for what the wings hold; open, the content's own
/// width, clamped between the floor and the display's ceiling (1.x's
/// island-width.ts, as a layout instead of a measuring loop).
struct IslandWidth: Layout {
  var fixed: CGFloat?
  var range: ClosedRange<CGFloat>

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let content = subviews.first else { return .zero }
    let natural = content.sizeThatFits(.unspecified).width
    // Whole points: a fractional width would re-lay out forever.
    let width = fixed ?? min(max(natural, range.lowerBound), range.upperBound).rounded()
    return CGSize(width: width, height: content.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
  }
}

/// The black band pixel-aligned with the notch, with a wing either side;
/// opening grows a panel beneath it. The band never moves: only the wings
/// and the panel animate.
struct IslandView: View {
  let model: IslandModel

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    island
      .environment(\.uiScale, model.settings.textSize.scale)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .animation(reduceMotion ? nil : (model.isExpanded ? Motion.open : Motion.close), value: model.isExpanded)
      // Collapsed, a width change eases like a close; open, content growing
      // or shrinking settles the width on the firmer spring.
      .animation(reduceMotion ? nil : Motion.close, value: model.collapsedWidth)
      .animation(reduceMotion || !model.isExpanded ? nil : Motion.settle, value: panelShape)
      // A swipe follows the fingers fast, then springs home on release.
      .animation(reduceMotion ? nil : model.rubber == 0 ? Motion.settle : .easeOut(duration: 0.09), value: model.rubber)
      .animation(reduceMotion ? nil : Motion.settle, value: model.notch)
      .animation(reduceMotion ? nil : Motion.settle, value: model.power.activity)
      .animation(reduceMotion ? nil : Motion.settle, value: model.sessions.moment)
  }

  /// What the open panel holds, roughly: when it changes, the width settles.
  private var panelShape: [Int] {
    [
      model.sessions.sessions.count, model.pending.count, model.asking.count, model.greeting == nil ? 0 : 1,
      model.greetingOnly ? 1 : 0, model.ask.isOpen ? 1 : 0, model.ask.turns.count, model.ask.proposals.count,
      model.weather.reading == nil ? 0 : 1,
      model.hubTab.map { HubTab.allCases.firstIndex(of: $0)! + 1 } ?? 0, model.timers.timers.count,
      model.liveTrack == nil ? 0 : 1, model.liveCall == nil ? 0 : 1, model.browser.front == nil ? 0 : 1,
      model.shelf.items.count, model.shelfDropping ? 1 : 0, model.prompterLive ? 1 : 0,
    ]
  }

  /// Solid black by default: one body, no seam. With glass, the panel below
  /// the band shows real glass under a dark scrim; the band stays black.
  @ViewBuilder private func body(glass: Bool) -> some View {
    if glass && model.isExpanded {
      ZStack(alignment: .top) {
        GlassMaterial()
        Color.black.opacity(0.8)
        Color.black.frame(height: model.bandHeight)
      }
      .clipShape(IslandShape(corner: corner))
    } else {
      IslandShape(corner: corner).fill(.black)
    }
  }

  private var corner: CGFloat {
    if model.isExpanded { IslandOutline.expandedCorner } else if model.isResting { 0 } else { IslandOutline.collapsedCorner }
  }

  private var island: some View {
    IslandWidth(fixed: model.isExpanded ? nil : model.collapsedWidth, range: model.expandedWidthRange) {
      VStack(spacing: 0) {
        Band(model: model)
          .frame(height: model.bandHeight)
          .contentShape(Rectangle())
          .onTapGesture { model.clickWings() }
        if model.isExpanded {
          Panel(model: model)
            .offset(y: reduceMotion ? 0 : min(model.rubber, 0) * 8)
            .transition(reduceMotion ? .identity : .asymmetric(
              insertion: .opacity.animation(.easeOut(duration: 0.18).delay(0.05)),
              removal: .opacity.animation(.easeIn(duration: 0.07))
            ))
        }
      }
    }
    .padding(.horizontal, IslandOutline.earRadius)
    .background { body(glass: model.settings.glass && !reduceTransparency && contrast != .increased) }
    .overlay {
      if let pulse = model.sessions.pulse {
        EdgeGlow(pulse: pulse, corner: corner, reduced: reduceMotion, highContrast: contrast == .increased, paused: model.isPaused) {
          model.sessions.clearPulse(pulse.id)
        }
        .id(pulse.id)
      }
    }
    .clipShape(IslandShape(corner: corner))
    .overlay {
      if model.settings.edgeGlow && model.ask.isOpen && model.isExpanded && !model.isPaused {
        IslandGlow(corner: corner, bright: model.ask.live != nil, paused: model.isPaused)
      }
    }
    .overlay {
      if let activity = model.power.activity, activity.isCharger, model.reading != nil, !model.isPaused {
        ChargeCurrent(moment: activity, corner: corner, reduced: reduceMotion, highContrast: contrast == .increased)
          .allowsHitTesting(false)
          .id(activity.id)
      }
    }
    .contentShape(IslandShape(corner: corner))
    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
      model.bodySize = CGSize(width: size.width - 2 * IslandOutline.earRadius, height: size.height)
    }
    .contextMenu { IslandMenu(power: model.power, openSettings: model.openSettings) }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Agent Island")
  }
}

// MARK: - Band

/// The notch band and its two wings: one winner at a time (`WingContent`).
private struct Band: View {
  let model: IslandModel

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 0) {
      left
        .frame(maxWidth: .infinity, alignment: .leading)
      // The hardware notch: nothing drawn here, ever.
      Color.clear.frame(width: model.notch.width)
      right
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .padding(.horizontal, 11)
    .padding(.bottom, 3)
    // A swipe pulls the wings down a touch; the band itself never moves.
    .offset(y: model.isExpanded || reduceMotion ? 0 : max(model.rubber, 0) * 3)
    .opacity(model.isResting ? 0 : 1)
    .foregroundStyle(tint)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(WingText.label(model))
  }

  private var reading: PowerReading? { model.reading }

  /// The dominant session's colour; a moment, low battery or the charger take over.
  private var tint: Color {
    if model.wing == .moment, let moment = model.sessions.moment {
      return moment.kind == .done ? Palette.done : Palette.failed
    }
    if model.wing == .lowBattery {
      return Palette.failed
    }
    let sessions = model.sessions.sessions
    let dominant = sessions.first { $0.pendingApproval != nil } ?? model.active.first ?? sessions.first
    if let dominant { return Palette.state(dominant.state) }
    return model.sessions.connected ? Palette.idle : Palette.failed
  }

  @ViewBuilder private var left: some View {
    Group {
      if model.wing == .moment, let session = model.sessions.momentSession {
        BotAvatar(
          look: .agent(session.agent), state: session.avatarState(now: .now), size: 24, seed: session.seed,
          paused: model.isPaused, interactive: false
        )
        .padding(.vertical, -4)
        .pop()
        .id(model.sessions.moment?.id)
      } else if model.wing == .meeting, model.liveCall != nil {
        CallBadge(muted: model.meeting.muted).pop()
      } else if model.wing == .timer, let timer = model.liveTimer {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
          TimerRing(timer: timer, now: timeline.date)
        }
        .pop()
        .id(timer.id)
      } else if model.wing == .media, model.liveTrack != nil {
        ArtworkView(image: model.media.artwork)
          .padding(.vertical, -2)
          .pop()
      } else if model.isSleeping || model.isIdleBot {
        if let reading {
          BatteryRing(
            percent: reading.percent, charging: !reading.isOnBattery, low: reading.isLow, labelled: true,
            animated: !model.isPaused
          )
          .pop()
        }
      } else if model.wing == .activity, let focus = model.focusMoment, model.power.activity?.isCharger != true {
        Image(systemName: "moon.fill")
          .font(.system(size: 11))
          .foregroundStyle(focus.active ? Color(hex: 0xC9B8FF) : Palette.textDim)
          .pop()
          .id(focus.id)
      } else if model.wing == .activity, let activity = model.power.activity, let reading {
        switch activity.kind {
        case .plugged, .unplugged:
          ChargeRing(moment: activity, percent: reading.percent).pop().id(activity.id)
        case .low:
          BatteryRing(percent: reading.percent, charging: false, low: true, animated: !model.isPaused).pop().id(activity.id)
        }
      } else if model.wing == .lowBattery, let reading {
        BatteryRing(percent: reading.percent, charging: false, low: true, animated: !model.isPaused).pop()
      } else if model.wing == .weather, let weather = model.weather.reading {
        WeatherScene(condition: weather.condition, variant: .ambient, paused: model.isPaused).pop()
      } else {
        HStack(spacing: 6) {
          ForEach(model.orbs, id: \.agent) { orb in
            ThinkingOrb(
              state: orb.state,
              tint: orb.waiting ? Palette.waiting : Color(hex: BotLook.agent(orb.agent).color),
              bold: true,
              paused: model.isPaused
            )
            // Whatever arrives in the wing pops in; the old one just goes.
            .pop()
          }
        }
      }
    }
  }

  @ViewBuilder private var right: some View {
    if (model.isSleeping || model.isIdleBot) && model.showsClock {
      WingClock().pop()
    } else if model.isSleeping || model.isIdleBot {
      // At rest, one mascot keeps the island company.
      BotAvatar(
        look: BotLook.crew[0].look, state: .idle, size: 19, seed: 0.12, paused: model.isPaused,
        style: BotPose.Style(jumpEvery: 0), interactive: false
      )
      .pop()
    } else if model.wing == .meeting, let call = model.liveCall {
      WingTicker(text: { Clock.elapsed($0.timeIntervalSince(call.since)) }, tint: QuickPalette.meeting)
        .modifier(Entrance(kind: .countRoll))
    } else if model.wing == .timer, let timer = model.liveTimer {
      WingTicker(text: { Clock.countdown(timer.remaining(at: $0)) }, tint: QuickPalette.timer(timer))
        .modifier(Entrance(kind: .countRoll))
        .id(timer.id)
    } else if model.wing == .media, let track = model.liveTrack {
      EqualizerBars(playing: track.playing, tint: model.media.accent.map(Color.init(nsColor:)) ?? Palette.done, paused: model.isPaused)
        .pop()
    } else if model.showsWorkCrew {
      WorkCrewView(active: model.active, paused: model.isPaused)
    } else {
      let text = WingText.count(model)
      let charge = model.wing == .activity ? model.power.activity.flatMap { $0.isCharger ? $0 : nil } : nil
      Text(text)
        .islandFont(charge == nil ? 10.5 : 12.5, weight: charge == nil ? .bold : .heavy)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(charge.map(Palette.charge) ?? tint)
        .shadow(color: charge.map { Palette.charge($0).opacity(0.55) } ?? .clear, radius: 3)
        // While agents work, the count breathes.
        .modifier(CountPulse(period: 1.5, active: model.wing == .working && !model.isPaused, reducible: true))
        // Keyed on its value: a change remounts and rolls in like a counter.
        .modifier(Entrance(kind: .countRoll))
        .id(text)
        .transition(.identity)
    }
  }
}

/// The right wing's text and the wings' spoken label (1.x's countText / countLabel).
enum WingText {
  static func count(_ model: IslandModel) -> String {
    let needsYou = model.needsYou.count
    if needsYou > 0 { return "\(needsYou)!" }
    if model.wing == .moment, let moment = model.sessions.moment { return moment.kind == .done ? "done" : "failed" }
    if model.wing == .activity, let focus = model.focusMoment, model.power.activity?.isCharger != true {
      return focus.active ? (model.focus.name ?? "Focus") : ""
    }
    if model.wing == .activity, let reading = model.reading { return "\(reading.percent)%" }
    if !model.active.isEmpty { return String(model.active.count) }
    if model.wing == .lowBattery, let reading = model.reading { return "\(reading.percent)%" }
    if model.wing == .weather, let weather = model.weather.reading { return weather.temperature }
    return ""
  }

  static func label(_ model: IslandModel) -> String {
    let needsYou = model.needsYou.count
    let reading = model.reading
    if needsYou > 0 { return "\(needsYou) sessions need attention" }
    if model.wing == .moment, let moment = model.sessions.moment, let session = model.sessions.momentSession {
      return "\(session.projectName) \(moment.kind == .done ? "finished" : "failed")"
    }
    if model.wing == .activity, let focus = model.focusMoment, model.power.activity?.isCharger != true {
      return focus.active ? "Focus on" + (model.focus.name.map { ": \($0)" } ?? "") : "Focus off"
    }
    if model.wing == .activity, let activity = model.power.activity, let reading {
      return switch activity.kind {
      case .plugged: "Charging, \(reading.percent)%"
      case .unplugged: "On battery, \(reading.percent)%"
      case .low: "Low battery, \(reading.percent)%"
      }
    }
    if model.wing == .lowBattery, let reading { return "Low battery, \(reading.percent)%" }
    if model.wing == .weather, let weather = model.weather.reading { return weather.summary }
    if model.wing == .meeting, let call = model.liveCall {
      return "On a \(call.source.name) call for \(Clock.elapsed(Date.now.timeIntervalSince(call.since)))" + (model.meeting.muted == true ? ", muted" : "")
    }
    if model.wing == .timer, let timer = model.liveTimer {
      return "\(timer.title), \(Clock.countdown(timer.remaining(at: .now))) left" + (timer.isPaused ? ", paused" : "")
    }
    if model.wing == .media, let track = model.liveTrack { return "Playing \(track.title) by \(track.artist)" }
    let battery = reading.map { ", battery \($0.percent)%" } ?? ""
    if model.isSleeping { return "\(model.sessions.sessions.count) sessions, all resting\(battery)" }
    if model.isIdleBot { return "No agents running\(battery)" }
    return "\(model.active.count) active sessions"
  }
}

// MARK: - Edge glow

/// A soft coloured bloom washes the island on each event, then fades: done
/// green, a question blue ripple, attention an amber throb, a failure three
/// jagged red flashes. Reduce Motion keeps only a gentle fade.
private struct EdgeGlow: View {
  let pulse: EdgePulse
  let corner: CGFloat
  let reduced: Bool
  /// At high contrast the bloom becomes a 2 pt border: same signal, text stays legible.
  let highContrast: Bool
  /// Paused holds the frame it's on, and picks up from there.
  let paused: Bool
  let onEnd: () -> Void

  private let clock = State(initialValue: PauseClock())

  private struct PauseClock {
    var held = 0.0
    var since: Date?
  }

  private func elapsed(at now: Date) -> Double {
    (clock.wrappedValue.since ?? now).timeIntervalSince(pulse.at) - clock.wrappedValue.held
  }

  private var color: Color {
    switch pulse.kind {
    case .done, .approve: Palette.done
    case .failed: Palette.failed
    case .question: Palette.working
    case .attention: Palette.waiting
    case .hello: Color(hex: 0xFF6FA8)
    }
  }

  /// Duration and opacity keyframes (time fraction, opacity), from island.css.
  private var rhythm: (duration: Double, keys: [(Double, Double)]) {
    let life: [(Double, Double)] = [(0.14, 1), (1, 0)]
    let duration = switch pulse.kind {
    case .done: 0.9
    case .approve: 0.5
    case .hello: 2.2
    case .question: 1.1
    case .attention: 1.2
    case .failed: 0.7
    }
    // Reduce Motion keeps only the gentle fade, at the event's own pace.
    if reduced { return (duration, life) }
    return switch pulse.kind {
    case .done, .approve, .hello: (duration, life)
    case .question: (duration, [(0.3, 0.85), (1, 0)])
    case .attention: (duration, [(0.12, 1), (0.33, 0.25), (0.55, 1), (0.76, 0.25), (0.92, 1), (1, 0)])
    case .failed: (duration, [(0.08, 1), (0.22, 0.1), (0.38, 1), (0.55, 0.12), (0.7, 1), (1, 0)])
    }
  }

  var body: some View {
    let (duration, keys) = rhythm
    TimelineView(.animation(paused: paused)) { timeline in
      let t = elapsed(at: timeline.date) / duration
      ZStack {
        if highContrast {
          IslandShape(corner: corner).stroke(color, lineWidth: 4)
        } else {
        IslandShape(corner: corner)
          .stroke(
            pulse.kind == .hello
              ? AnyShapeStyle(AngularGradient(colors: [Color(hex: 0xB18CFF), Color(hex: 0xFF6FA8), Color(hex: 0xFFB36B), Color(hex: 0x6BC8FF), Color(hex: 0xB18CFF)], center: .center))
              : AnyShapeStyle(color),
            lineWidth: 16
          )
          .blur(radius: 9)
        // A heavier wash off the bottom edge.
        LinearGradient(colors: [color.opacity(0), color.opacity(0.55)], startPoint: .init(x: 0.5, y: 0.55), endPoint: .bottom)
          .blur(radius: 6)
        }
      }
      .opacity(Self.opacity(at: t, keys: keys))
    }
    .allowsHitTesting(false)
    .onChange(of: paused, initial: true) { _, now in
      if now {
        clock.wrappedValue.since = clock.wrappedValue.since ?? .now
      } else if let since = clock.wrappedValue.since {
        clock.wrappedValue.held += Date.now.timeIntervalSince(since)
        clock.wrappedValue.since = nil
      }
    }
    .task(id: paused) {
      guard !paused else { return }
      try? await Task.sleep(for: .seconds(max(0, duration - elapsed(at: .now))))
      guard !Task.isCancelled else { return }
      onEnd()
    }
  }

  static let easeOut = CubicBezier(0, 0, 0.58, 1)

  /// Piecewise between keyframes from 0 at the start, eased out per segment like CSS.
  static func opacity(at t: Double, keys: [(Double, Double)]) -> Double {
    var (from, value) = (0.0, 0.0)
    for (at, target) in keys {
      if t <= at {
        let u = at > from ? max(0, (t - from) / (at - from)) : 1
        let eased = easeOut.y(at: u)
        return value + (target - value) * eased
      }
      (from, value) = (at, target)
    }
    return 0
  }
}

/// Right-click on the island. The Settings window replaces most of this in phase 6.
private struct IslandMenu: View {
  let power: PowerMonitor
  let openSettings: () -> Void

  var body: some View {
    if LoginItem.isAvailable {
      // Read fresh each time the menu opens: System Settings can change it too.
      Toggle("Open at Login", isOn: Binding(get: { LoginItem.isEnabled }, set: { LoginItem.isEnabled = $0 }))
    }
    Button("Settings…") { openSettings() }
    #if DEBUG
    Button("Play Charger Moment") { power.simulateMoment() }
    #endif
    Divider()
    Button("Quit Agent Island") { NSApp.terminate(nil) }
  }
}

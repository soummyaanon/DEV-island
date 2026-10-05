import IslandCore
import SwiftUI

/// The open island: the sessions (robot bubbles, or detailed rows), the usage
/// footer, and the controls. Phases 4–6 add the cards, prompt, assistant and
/// the remaining controls above and beside these.
struct Panel: View {
  let model: IslandModel

  var body: some View {
    // Elapsed times tick while open, and only then.
    TimelineView(.periodic(from: .now, by: 1)) { timeline in
      let now = timeline.date
      VStack(alignment: .leading, spacing: 0) {
        let sessions = model.sessions.sessions
        // Files dragged at the notch, or the script rolling: that's all it shows.
        if model.shelfDropping {
          ShelfDropZone(model: model)
        } else if model.prompterLive {
          PrompterStage(model: model)
        } else {
        if let greeting = model.greeting {
          GreetingCard(greeting: greeting.value, at: greeting.at, paused: model.isPaused) { model.dismissGreeting() }
            .id(greeting.id)
        }
        if !model.greetingOnly {
        // Everything waiting on you, in one place: past a few cards it scrolls
        // rather than pushing the island off the screen.
        if !model.pending.isEmpty || !model.asking.isEmpty {
          ScrollView(.vertical) {
            VStack(spacing: 0) {
              ForEach(model.pending, id: \.key) { session in
                if let approval = session.pendingApproval {
                  ApprovalCard(session: session, approval: approval, model: model)
                    .modifier(Entrance(kind: .rowIn, delay: 0.06))
                }
              }
              ForEach(model.asking, id: \.key) { session in
                if let question = session.pendingQuestion {
                  QuestionCard(session: session, question: question, model: model)
                    .id(question.id)
                    .modifier(Entrance(kind: .rowIn, delay: 0.06))
                }
              }
            }
          }
          .scrollIndicators(.automatic)
          .frame(maxHeight: Panel.cardsHeight)
          .fixedSize(horizontal: false, vertical: true)
        }
        // Pages overlap as they swap: the old one blurs out one way while the
        // new one comes into focus from the other.
        ZStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 0) {
        if let tab = model.hubTab {
          // Only Timers ticks each second; the other tools redraw once a minute.
          HubPage(model: model, tab: tab, now: tab == .timers ? now : Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60))
        } else {
        ContextCards(model: model, now: now)
        if model.settings.sessionView == .compact && !sessions.isEmpty {
          FlowLayout(spacing: 4) {
            ForEach(Array(sessions.prefix(SessionList.maxBubbles).enumerated()), id: \.element.key) { index, session in
              SessionBubble(session: session, now: now, model: model)
                .modifier(Entrance(kind: .rowIn, delay: 0.05 + Double(index) * 0.022))
            }
          }
          .padding(.init(top: 6, leading: 8, bottom: 4, trailing: 8))
        } else {
          VStack(spacing: 1) {
            ForEach(Array(sessions.prefix(SessionList.maxRows).enumerated()), id: \.element.key) { index, session in
              SessionRow(session: session, now: now, model: model)
                .modifier(Entrance(kind: .rowIn, delay: 0.05 + Double(index) * 0.022))
            }
            if sessions.isEmpty && !model.sessions.connected {
              Text("offline")
                .islandFont(12)
                .foregroundStyle(Palette.textDim)
                .frame(maxWidth: .infinity)
                .padding(.init(top: 10, leading: 12, bottom: 14, trailing: 12))
            }
          }
          .padding(.init(top: 3, leading: 6, bottom: 7, trailing: 6))
        }
        StatusFooter(model: model, now: now)
        }
        }
        .id(model.hubTab)
        .transition(reduceMotion ? AnyTransition.opacity : PageTurn.transition(model))
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
          // Only once paging starts: the sessions page alone keeps its own size.
          guard model.hubTab != nil || model.pageFloor != .zero else { return }
          let floor = CGSize(
            width: max(model.pageFloor.width, size.width.rounded(.up)),
            height: max(model.pageFloor.height, size.height.rounded(.up), PageTurn.minHeight)
          )
          guard floor != model.pageFloor else { return }
          withAnimation(reduceMotion ? nil : Motion.settle) { model.pageFloor = floor }
        }
        .frame(minWidth: model.pageFloor.width, minHeight: model.pageFloor.height, alignment: .top)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : Motion.settle, value: model.hubTab)
        if model.ask.isOpen {
          AssistantPanel(state: model.ask)
        }
        if model.showsPrompt && !model.ask.isOpen && model.needsAccessibility {
          Hovering { hovered in
            Button {
              Accessibility.request()
            } label: {
              Text("⚠ Grant Accessibility to send prompts →")
                .islandFont(10, weight: .semibold)
                .foregroundStyle(Color(hex: 0xFFCF70))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.init(top: 4, leading: 8, bottom: 4, trailing: 8))
                .background(RoundedRectangle(cornerRadius: 7).fill(Palette.waiting.opacity(hovered ? 0.2 : 0.12)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.waiting.opacity(0.32)))
            }
            .buttonStyle(.plain)
          }
          .help("Agent Island needs Accessibility to type into Cursor's Composer or your terminal. App updates invalidate an existing grant even when the toggle still shows on: clicking refreshes our entry; tick Agent Island in the list that opens.")
          .padding(.init(top: 4, leading: 8, bottom: 0, trailing: 8))
        }
        Controls(model: model)
        }
        }
      }
      .frame(maxWidth: model.maxIslandWidth, alignment: .leading)
      // A sideways swipe leans the page and shows where it's going.
      .offset(x: reduceMotion ? 0 : model.sideRubber * -12)
      // …and starts to lose focus under the fingers, so the turn has already begun.
      .blur(radius: reduceMotion ? 0 : abs(model.sideRubber) * 8)
      .overlay(alignment: model.sideRubber > 0 ? .leading : .trailing) {
        if model.sideRubber != 0, let target = model.page(after: model.sideRubber < 0 ? 1 : -1) {
          SwipeTarget(tab: target, progress: abs(model.sideRubber))
            .padding(.horizontal, 6)
            .allowsHitTesting(false)
        }
      }
      .animation(reduceMotion ? nil : model.sideRubber == 0 ? Motion.settle : .easeOut(duration: 0.08), value: model.sideRubber)
    }
    .onDisappear { model.pageFloor = .zero }
  }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The tallest the approval and question cards get together before they
  /// scroll; the island's canvas is 560 pt and the band and controls need room.
  static let cardsHeight: CGFloat = 320
}

/// Changing pages, like a camera pulling focus: the old page drops out of
/// focus fast, then the new one resolves from a deep blur to fully sharp,
/// drifting in a touch from the side you're heading. They don't overlap, so
/// there's never a double image; the blur hides the swap itself.
private struct PageTurn: Transition {
  /// Read when the transition runs, so a page leaving knows the latest direction.
  let model: IslandModel
  let leaving: Bool

  /// The page area is never shorter than this once paging starts.
  static let minHeight: CGFloat = 150

  static func transition(_ model: IslandModel) -> AnyTransition {
    .asymmetric(
      // A long, gentle settle: most of the focus pull happens early, the last
      // of the blur melts away slowly.
      insertion: AnyTransition(PageTurn(model: model, leaving: false))
        .animation(.timingCurve(0.2, 0.85, 0.25, 1, duration: 0.55).delay(0.05)),
      removal: AnyTransition(PageTurn(model: model, leaving: true))
        .animation(.timingCurve(0.4, 0, 0.9, 0.6, duration: 0.16))
    )
  }

  func body(content: Content, phase: TransitionPhase) -> some View {
    // Both halves of the pair stay applied at rest: only act in our own phase.
    let off = leaving ? phase == .didDisappear : phase == .willAppear
    let gone = leaving && off
    // Arrivals come from ahead, departures go behind.
    let side = Double(model.pageStep) * (leaving ? -1 : 1)
    content
      // The leaving page stops taking room, so the panel settles on the new one at once.
      .fixedSize(horizontal: false, vertical: gone)
      .frame(height: gone ? 0 : nil, alignment: .top)
      .blur(radius: off ? (leaving ? 16 : 30) : 0)
      .scaleEffect(off ? (leaving ? 0.96 : 1.04) : 1, anchor: .top)
      .offset(x: off ? side * (leaving ? 14 : 24) : 0)
      .opacity(off ? 0 : 1)
      .allowsHitTesting(!gone)
  }
}

/// The page a swipe is heading for: its icon in a circle that fills as the swipe nears.
private struct SwipeTarget: View {
  let tab: HubTab?
  let progress: Double

  var body: some View {
    Image(systemName: tab?.symbol ?? "person.2.fill")
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: 34, height: 34)
      .background(Circle().fill(.white.opacity(0.1 + 0.25 * progress)))
      .overlay(Circle().trim(from: 0, to: progress).stroke(Palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90)))
      .scaleEffect(0.7 + 0.3 * progress)
      .opacity(min(1, progress * 1.6))
  }
}

// MARK: - Sessions

/// A session's robot with a small state badge on its shoulder.
struct AgentAvatar: View {
  let session: SessionSnapshot
  let now: Date
  var size: CGFloat = 30
  var badge = true
  var paused = false
  /// Follows the pointer and hops at a click (the row's click still jumps).
  var interactive = true

  var body: some View {
    BotAvatar(
      look: .agent(session.agent), state: session.avatarState(now: now), size: size, seed: session.seed, paused: paused,
      interactive: interactive
    )
      .overlay(alignment: .bottomTrailing) {
        if badge {
          Circle()
            .fill(Palette.state(session.state))
            .frame(width: 8, height: 8)
            .padding(2)
            .background(Circle().fill(.black))
            .offset(x: 3, y: 2)
            .modifier(BadgePulse(active: session.state == .waitingForApproval && !paused))
        }
      }
  }
}

private struct BadgePulse: ViewModifier {
  let active: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    if active && !reduceMotion {
      content.phaseAnimator([0.55, 1.0]) { view, opacity in view.opacity(opacity) } animation: { _ in .easeInOut(duration: 1.4) }
    } else {
      content
    }
  }
}

/// A detailed row: robot, project and elapsed; the activity (with a thinking
/// orb while busy) and where it runs. Click to jump back to it.
private struct SessionRow: View {
  let session: SessionSnapshot
  let now: Date
  let model: IslandModel

  var body: some View {
    Button {
      JumpBack.jump(to: session)
    } label: {
      HStack(alignment: .top, spacing: 8) {
        AgentAvatar(session: session, now: now, paused: model.isPaused)
          .padding(.init(top: -2, leading: -2, bottom: -2, trailing: 0))
        VStack(alignment: .leading, spacing: 2) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(session.projectName)
              .islandFont(12.5, weight: .medium)
              .foregroundStyle(Palette.text)
              .lineLimit(1)
              .frame(maxWidth: 210, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(session.elapsed(now: now))
              .islandFont(9.5)
              .monospacedDigit()
              .foregroundStyle(Palette.textDim)
          }
          HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 1) {
              if session.isThinking {
                ThinkingOrb(state: session.orbState, tint: Palette.tint(session.state), paused: model.isPaused)
                  .padding(.init(top: -6, leading: -2, bottom: -4, trailing: 2))
              }
              Text(session.title)
                .islandFont(11)
                .foregroundStyle(Palette.textDim)
                .lineLimit(1)
            }
            .frame(maxWidth: 312, alignment: .leading)
            Spacer(minLength: 8)
            Text(session.contextLine)
              .islandFont(9.5)
              .foregroundStyle(Palette.textDim)
              .lineLimit(1)
              .frame(maxWidth: 178, alignment: .trailing)
            if let stats = model.procStats[session.key] {
              Text("\(stats.cpu)% · \(Format.memory(megabytes: Double(stats.rssMB)))")
                .islandFont(9.5)
                .monospacedDigit()
                .foregroundStyle(stats.heat == .burning ? Palette.failed : stats.heat == .hot ? Palette.waiting : Palette.textDim)
                .fixedSize()
            }
          }
        }
      }
      .padding(.init(top: 6, leading: 8, bottom: 6, trailing: 8))
      .contentShape(Rectangle())
    }
    .buttonStyle(HoverRow(hovered: model.hovered == session.key, radius: 9))
    .onHover { inside in model.hovered = inside ? session.key : (model.hovered == session.key ? nil : model.hovered) }
    .help(helpText)
    .accessibilityLabel(session.spokenDescription(now: now))
  }

  private var helpText: String {
    if let term = session.metaString("term_program") { "Jump to \(session.projectName) in \(term)" } else { "Jump to terminal" }
  }
}

/// A compact session: its robot with the project name underneath. Hover for
/// the whole story (the same sentence VoiceOver reads); click to jump.
private struct SessionBubble: View {
  let session: SessionSnapshot
  let now: Date
  let model: IslandModel

  var body: some View {
    let hovered = model.hovered == session.key
    Button {
      JumpBack.jump(to: session)
    } label: {
      VStack(spacing: 3) {
        AgentAvatar(session: session, now: now, size: 32, badge: false, paused: model.isPaused, interactive: false)
          .padding(.top, 1)
        Text(session.projectName)
          .islandFont(9.5)
          .foregroundStyle(hovered ? Palette.text : Palette.textDim)
          .lineLimit(1)
      }
      .frame(width: 54)
      .padding(.init(top: 4, leading: 2, bottom: 3, trailing: 2))
      .contentShape(Rectangle())
    }
    .buttonStyle(HoverRow(hovered: hovered, radius: 10))
    .onHover { inside in model.hovered = inside ? session.key : (hovered ? nil : model.hovered) }
    .help(session.spokenDescription(now: now))
    .accessibilityLabel(session.spokenDescription(now: now))
  }
}

/// A faint lift under the pointer, a touch more while pressed.
private struct HoverRow: ButtonStyle {
  let hovered: Bool
  let radius: CGFloat

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(
        RoundedRectangle(cornerRadius: radius)
          .fill(.white.opacity(configuration.isPressed ? 0.1 : hovered ? 0.06 : 0))
      )
      .animation(.easeOut(duration: 0.1), value: hovered)
  }
}

/// Wraps its children onto new lines at the proposed width.
struct FlowLayout: Layout {
  var spacing: CGFloat
  /// Each row centred in the width, not packed to the left.
  var centered = false

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
    return CGSize(width: rows.map(\.width).max() ?? 0, height: rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1)))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in arrange(width: bounds.width, subviews: subviews) {
      var x = bounds.minX + (centered ? (bounds.width - row.width) / 2 : 0)
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += row.height + spacing
    }
  }

  private func arrange(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
    var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      if let last = rows.last, last.width + spacing + size.width <= width {
        rows[rows.count - 1].indices.append(index)
        rows[rows.count - 1].width += spacing + size.width
        rows[rows.count - 1].height = max(last.height, size.height)
      } else {
        rows.append(([index], size.width, size.height))
      }
    }
    return rows
  }
}

// MARK: - Footer

/// One row: each agent's 5-hour and weekly limits as small rings, then the
/// battery when no agent is working. Hidden when there's nothing to say.
/// Focus and the resource total join in phase 5.
private struct StatusFooter: View {
  let model: IslandModel
  let now: Date

  var body: some View {
    let quotas = QuotaSummary.from(model.sessions.usage, now: now)
    // Battery is an idle-time fact: while any agent works, the footer is about the agents.
    let reading = model.active.isEmpty ? model.reading : nil
    let focus = model.focus.active ? model.focus : nil
    let total = model.settings.procStats ? model.procTotal.flatMap { $0.cpu + $0.rssMB > 0 ? $0 : nil } : nil
    if !quotas.isEmpty || reading != nil || focus != nil || total != nil {
      HStack(spacing: 10) {
        ForEach(quotas, id: \.agent) { quota in
          HStack(spacing: 6) {
            AgentMarkView(agent: quota.agent, size: 11)
              .opacity(0.85)
              .help(quota.agent.shortName)
            ForEach(quota.windows, id: \.label) { window in
              HStack(spacing: 3) {
                QuotaRing(used: window.used)
                Text(window.short).foregroundStyle(Palette.textDim)
                Text("\(window.used)%").foregroundStyle(Palette.text).monospacedDigit()
              }
              .help(window.detail)
              .accessibilityElement(children: .ignore)
              .accessibilityLabel(window.detail)
            }
            if let credits = quota.credits {
              Text("\(credits) credits").foregroundStyle(Palette.textDim)
            }
          }
        }
        Spacer(minLength: 0)
        if let reading {
          HStack(spacing: 5) {
            BatteryRing(percent: reading.percent, charging: !reading.isOnBattery, low: reading.isLow, size: 14, animated: !model.isPaused)
            Text("\(reading.percent)%")
              .fontWeight(.semibold)
              .foregroundStyle(reading.isLow ? Palette.failed : reading.isOnBattery ? Palette.text : Palette.done)
          }
          .help(PowerDescription.detail(reading))
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(PowerDescription.detail(reading))
        }
        if let focus {
          Hovering { hovered in
            Button {
              model.setFocus(MacFocus())
            } label: {
              HStack(spacing: 5) {
                Image(systemName: "moon.fill").islandFont(10)
                // Hovering strikes it through: a click turns it off.
                Text(focus.name ?? "Focus").fontWeight(.semibold).foregroundStyle(Color(hex: 0xC9B8FF)).strikethrough(hovered)
              }
            }
            .buttonStyle(.plain)
          }
          .foregroundStyle(Palette.textDim)
          .help("Focus is on (from your Shortcuts automation). Click if it stayed on by mistake.")
        }
        if let total {
          HStack(spacing: 5) {
            Image(systemName: "cpu").islandFont(10)
            Text("\(total.cpu)%").fontWeight(.semibold).foregroundStyle(Palette.text).monospacedDigit()
            Text(Format.memory(megabytes: Double(total.rssMB)))
          }
          .help("What your agents are using right now")
        }
      }
      .islandFont(9.5)
      .lineLimit(1)
      .frame(minHeight: 25)
      .padding(.init(top: 4, leading: 6, bottom: 5, trailing: 6))
      .padding(.init(top: 2, leading: 8, bottom: 0, trailing: 8))
    }
  }
}

/// A limit as a small ring: the arc is what's USED, warming as it fills; past
/// 90% it glows softly so a nearly spent window gets noticed.
private struct QuotaRing: View {
  let used: Int
  /// It draws in from empty when it appears.
  private let drawn = State(initialValue: false)

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let tone = used >= 90 ? Palette.failed : used >= 70 ? Palette.waiting : Palette.done
    let scale = 13.0 / 16
    RingArc(fill: drawn.wrappedValue || reduceMotion ? Double(used) / 100 : 0, lineWidth: 2 * scale, color: tone)
      .frame(width: 6.2 * 2 * scale, height: 6.2 * 2 * scale)
      .frame(width: 13, height: 13)
      .animation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.9), value: used)
      .onAppear {
        guard !reduceMotion else { return }
        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.9)) { drawn.wrappedValue = true }
      }
      .modifier(HotGlow(color: tone, active: used >= 90 && !reduceMotion))
  }
}

private struct HotGlow: ViewModifier {
  let color: Color
  let active: Bool

  func body(content: Content) -> some View {
    if active {
      content.phaseAnimator([0.0, 2.5]) { view, radius in view.shadow(color: color, radius: radius) } animation: { _ in .easeInOut(duration: 1.2) }
    } else {
      content
    }
  }
}

enum PowerDescription {
  /// "1:05" or "40m"; empty when unknown.
  static func remaining(_ minutes: Int?) -> String {
    guard let minutes, minutes > 0 else { return "" }
    return minutes >= 60 ? String(format: "%d:%02d", minutes / 60, minutes % 60) : "\(minutes)m"
  }

  static func detail(_ reading: PowerReading) -> String {
    let time = remaining(reading.minutesRemaining)
    return switch reading.state {
    case .discharging: "\(reading.percent)% battery" + (time.isEmpty ? "" : ", \(time) left")
    case .charging: "\(reading.percent)%, charging" + (time.isEmpty ? "" : ", \(time) to full")
    case .charged: "Fully charged"
    case .ac: "\(reading.percent)%, on power"
    }
  }
}

// MARK: - Controls

/// The footer: a field in the left slot (the prompt bar; the assistant joins
/// in phase 6), and every key on the right.
private struct Controls: View {
  let model: IslandModel

  var body: some View {
    HStack(spacing: 8) {
      if model.ask.isOpen {
        AssistantField(state: model.ask, voiceEnabled: model.settings.voice, paused: model.isPaused)
          .frame(minWidth: 150, maxWidth: 250)
          .transition(.opacity)
      } else if model.showsPrompt {
        PromptBar(model: model)
          .frame(minWidth: 150, maxWidth: 250)
          .transition(.opacity)
      } else if model.crewAvailable && model.sessions.sessions.isEmpty {
        BotCrewButton(
          working: model.ask.live != nil, talk: model.sessions.connected, paused: !model.isExpanded || model.isPaused,
          disabledReason: nil
        ) { model.toggleAsk() }
      }
      Spacer(minLength: 0)
      if let version = model.updates.available {
        Hovering { hovered in
          Button("↑ update \(version)") { model.updates.openDownload() }
            .buttonStyle(.plain)
            .islandFont(9.5, weight: .bold)
            .foregroundStyle(Palette.accent)
            .padding(.init(top: 3, leading: 7, bottom: 3, trailing: 7))
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.accent.opacity(hovered ? 0.14 : 0)))
        }
        .help("Download Agent Island \(version)")
      }
      if !model.hubTabs.filter({ $0 != .ask }).isEmpty {
        PageDots(model: model)
      }
      HStack(spacing: 6) {
        Keycap(symbol: model.settings.sounds ? "speaker.wave.2.fill" : "speaker.slash.fill", label: model.settings.sounds ? "Sound on" : "Sound off", off: !model.settings.sounds) {
          model.changeSettings { $0.sounds.toggle() }
        }
        if model.crewAvailable && !model.sessions.sessions.isEmpty {
          // With agents on screen the crew steps aside; Ask stays one click away.
          Keycap(symbol: "sparkles", label: model.ask.isOpen ? "Close Apple Intelligence" : "Ask Apple Intelligence", on: model.ask.isOpen) {
            model.toggleAsk()
          }
        }
        Keycap(symbol: "power", label: "Quit") { NSApp.terminate(nil) }
      }
    }
    .padding(.init(top: 2, leading: 12, bottom: 6, trailing: 12))
    .padding(.bottom, 4)
  }
}

/// A small raised key, lit from above; pressing sinks it.
struct Keycap: View {
  let symbol: String
  let label: String
  var on = false
  var off = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .islandFont(12, weight: .medium)
        // Embossed: a dark cast below, a faint catch-light above.
        .shadow(color: .black.opacity(0.85), radius: 0, y: 1)
        .shadow(color: .white.opacity(0.18), radius: 0, y: -0.5)
    }
    .buttonStyle(KeycapStyle(on: on, off: off))
    .help(label)
    .accessibilityLabel(label)
  }
}

private struct KeycapStyle: ButtonStyle {
  let on: Bool
  let off: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    Hovering { hovered in
      let pressed = configuration.isPressed || on
      configuration.label
        .foregroundStyle(on ? Color(hex: 0xC9B3FF) : off ? .white.opacity(0.3) : hovered ? Palette.text : .white.opacity(0.62))
        .frame(width: 24, height: 24)
        .background(
          Circle().fill(LinearGradient(
            stops: [
              .init(color: .white.opacity(hovered ? 0.2 : 0.13), location: 0),
              .init(color: .white.opacity(hovered ? 0.05 : 0.03), location: 0.55),
              .init(color: .black.opacity(hovered ? 0.15 : 0.2), location: 1),
            ],
            startPoint: .top, endPoint: .bottom
          ))
        )
        .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(pressed ? 0.04 : 0.18), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .shadow(color: on ? Color(hex: 0xB18CFF).opacity(0.35) : .black.opacity(pressed ? 0 : 0.7), radius: on ? 3 : 1, y: on ? 0 : 1)
        .offset(y: configuration.isPressed ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: configuration.isPressed)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: hovered)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: on)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.12), value: off)
    }
  }
}

/// A quiet recessed pill for a free-form prompt to the session that's
/// running. Return sends it into the agent's terminal; Escape clears and
/// closes it.
private struct PromptBar: View {
  let model: IslandModel
  @FocusState private var focused: Bool

  var body: some View {
    let binding = Binding(get: { model.promptText }, set: { model.promptText = $0 })
    HStack(spacing: 6) {
      TextField("", text: binding, prompt: fieldPrompt(placeholder))
        .textFieldStyle(.plain)
        .islandFont(11)
        .foregroundStyle(Palette.text)
        .tint(Palette.caret)
        .focused($focused)
        .onSubmit { model.submitPrompt() }
        .onExitCommand {
          model.promptText = ""
          model.promptOpen = false
          focused = false
        }
        .accessibilityLabel(model.promptTarget?.agent == .cursor ? "Send a prompt to Cursor" : "Send a prompt to the agent")
      Button { model.submitPrompt() } label: {
        Image(systemName: "arrow.up.circle")
          .islandFont(11)
          .frame(width: 22, height: 22)
      }
      .buttonStyle(SendKey(ready: !model.promptText.trimmingCharacters(in: .whitespaces).isEmpty))
      .disabled(model.promptText.trimmingCharacters(in: .whitespaces).isEmpty)
      .help("Send prompt")
      .accessibilityLabel("Send prompt")
    }
    .padding(.init(top: 0, leading: 8, bottom: 0, trailing: 3))
    .frame(height: 28)
    .modifier(FieldPill(focused: focused))
    .overlay { FieldBeam(focused: focused, paused: model.isPaused) }
    .onChange(of: focused) { _, now in model.promptFocused = now }
    .onAppear { if model.promptOpen { focused = true } }
    .onChange(of: model.promptOpen) { _, open in focused = open }
  }

  private var placeholder: String {
    if !model.asking.isEmpty { return "Reply to the agent…" }
    return model.promptTarget?.agent == .cursor ? "Ask Cursor…" : "Ask the agent…"
  }
}



/// A compact swiper: back, the current page's icon, next. The icon steps
/// forward on a click; for the first few opens the arrows nudge, saying the
/// island swipes sideways.
private struct PageDots: View {
  let model: IslandModel

  var body: some View {
    let pages = model.pages
    let index = pages.firstIndex(of: model.hubTab) ?? 0
    HStack(spacing: 1) {
      arrow("chevron.compact.left", enabled: index > 0, label: "Previous") { model.stepPage(-1) }
      Button { model.stepPage(index == pages.count - 1 ? -index : 1) } label: {
        Image(systemName: model.hubTab?.symbol ?? "person.2.fill")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(.black)
          .frame(width: 22, height: 14)
          .background(Capsule().fill(.white.opacity(0.9)))
          .contentTransition(.symbolEffect(.replace))
      }
      .buttonStyle(.plain)
      .help(model.hubTab?.title ?? "Sessions")
      .accessibilityLabel("Page: \(model.hubTab?.title ?? "Sessions")")
      arrow("chevron.compact.right", enabled: index < pages.count - 1, label: "Next", hint: model.swipeHintsLeft > 0 && model.hubTab == nil) {
        model.stepPage(1)
      }
    }
    .help("Swipe sideways with two fingers")
  }

  private func arrow(_ symbol: String, enabled: Bool, label: String, hint: Bool = false, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(hint ? Palette.accent : .white.opacity(enabled ? 0.55 : 0.15))
        .frame(width: 14, height: 18)
        .modifier(Nudge(active: hint))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .accessibilityLabel(label)
  }
}

/// Drifts a few points toward where the swipe goes, and back.
private struct Nudge: ViewModifier {
  let active: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    if active && !reduceMotion {
      content.phaseAnimator([0.0, 3.0, 0.0]) { view, x in view.offset(x: x) } animation: { _ in .easeInOut(duration: 0.6) }
    } else {
      content
    }
  }
}

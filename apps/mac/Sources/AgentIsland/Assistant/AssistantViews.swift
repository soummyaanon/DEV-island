import IslandCore
import SwiftUI

/// The conversation above the footer: each question, the steps it took, the
/// answer (copyable), and its sources; then anything waiting for your click.
struct AssistantPanel: View {
  let state: AssistantState

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if !state.turns.isEmpty {
        ScrollView(.vertical) {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(state.turns) { turn in
              TurnView(turn: turn, state: state)
                .modifier(Entrance(kind: .rowIn, reducible: false))
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
        .frame(maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 330, alignment: .leading)
        .padding(.horizontal, 8)
      }
      if let note = state.voiceNote {
        Text(note).islandFont(9.5).foregroundStyle(Palette.waiting).padding(.horizontal, 8)
      }
      ForEach(state.proposals) { proposal in
        ProposalView(proposal: proposal, state: state)
      }
    }
    .padding(.top, 2)
  }
}

private struct TurnView: View {
  let turn: AssistantState.Turn
  let state: AssistantState

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(turn.question).islandFont(9.5).foregroundStyle(Palette.textDim)
      if !turn.steps.isEmpty {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(Array(turn.steps.enumerated()), id: \.offset) { index, step in
            let running = turn.tool != nil && index == turn.steps.count - 1
            (Text(running ? "› " : "✓ ").foregroundColor(running ? Color(hex: 0xC9B3FF) : Palette.done) + Text(step))
              .islandFont(9.5)
              .foregroundStyle(running ? Palette.text : Palette.textDim)
              .modifier(CountPulse(active: running))
          }
        }
        .padding(.bottom, 4)
      }
      Group {
        switch turn.status {
        case .error:
          Text(turn.error ?? "").foregroundStyle(Palette.failed)
        case _ where !turn.answer.isEmpty:
          // Copy sits inline after the last word, so the answer keeps its width.
          Text(answer)
            .foregroundStyle(Palette.text)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
              guard url == Self.copyURL else { return .systemAction }
              state.copyAnswer(turn)
              return .handled
            })
            .accessibilityAction(named: "Copy answer") { state.copyAnswer(turn) }
        default:
          Text("Thinking…").foregroundStyle(Palette.textDim).modifier(CountPulse())
        }
      }
      .islandFont(12)
      .lineSpacing(3)
      .fixedSize(horizontal: false, vertical: true)
      if !turn.sources.isEmpty {
        FlowLayout(spacing: 4) {
          ForEach(turn.sources, id: \.url) { source in
            Hovering { hovered in
              Button(source.url.host()?.replacing(/^www\./, with: "") ?? source.url.absoluteString) {
                NSWorkspace.shared.open(source.url)
              }
              .buttonStyle(.plain)
              .islandFont(9.5)
              .foregroundStyle(hovered ? Palette.text : Palette.textDim)
              .padding(.init(top: 1, leading: 7, bottom: 1, trailing: 7))
              .background(Capsule().fill(.white.opacity(hovered ? 0.12 : 0.06)))
              .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
            }
            .help(source.title.isEmpty ? source.url.absoluteString : source.title)
          }
        }
        .padding(.top, 4)
      }
    }
    .accessibilityElement(children: .combine)
  }

  static let copyURL = URL(string: "agentisland-copy:answer")!

  /// The answer, and once it's done a copy glyph after its last word.
  private var answer: AttributedString {
    var text = AttributedString(turn.answer)
    guard turn.status == .done else { return text }
    var copy = AttributedString(" ⧉")
    copy.link = Self.copyURL
    copy.foregroundColor = Palette.textDim
    copy.underlineStyle = Text.LineStyle?.none
    text.append(copy)
    return text
  }
}

private struct ProposalView: View {
  let proposal: AssistantState.Proposal
  let state: AssistantState

  var body: some View {
    let (heading, detail, button, ready): (String, String, String, Bool) = switch proposal.kind {
    case let .draft(project, message):
      AssistantContext.session(named: project, in: state.sessions()) != nil
        ? ("To \(project)", message, "Send", true)
        : ("To \(project) (not running)", message, "Send", false)
    case let .shortcut(name):
      switch proposal.status {
      case .failed: ("Shortcut failed", name, "Retry", true)
      case .running: ("Running shortcut…", name, "Run", false)
      case .waiting: ("Run shortcut", name, "Run", true)
      }
    }
    HStack(spacing: 6) {
      VStack(alignment: .leading, spacing: 1) {
        Text(heading.uppercased()).islandFont(9.5).tracking(0.5).foregroundStyle(Palette.textDim)
        Text(detail).islandFont(11).foregroundStyle(Palette.text)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button(button) { state.accept(proposal) }
        .buttonStyle(ProposalButton())
        .disabled(!ready)
      Button { state.dismiss(proposal) } label: { Image(systemName: "xmark").islandFont(10, weight: .semibold) }
        .buttonStyle(ControlStyle())
        .help("Dismiss")
        .accessibilityLabel("Dismiss")
    }
    .padding(.init(top: 6, leading: 10, bottom: 6, trailing: 6))
    .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: 0xB18CFF).opacity(0.1)))
    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(hex: 0xB18CFF).opacity(0.25)))
    .padding(.horizontal, 8)
  }
}

private struct ProposalButton: ButtonStyle {
  @Environment(\.isEnabled) private var enabled

  func makeBody(configuration: Configuration) -> some View {
    Hovering { hovered in
      configuration.label
        .islandFont(12.5, weight: .semibold)
        .foregroundStyle(Color(hex: 0x111214))
        .padding(.init(top: 6, leading: 12, bottom: 6, trailing: 12))
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: enabled && (hovered || configuration.isPressed) ? 0xFFFFFF : 0xECECEC)))
        .scaleEffect(configuration.isPressed && enabled ? 0.98 : 1)
        .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        .animation(.easeInOut(duration: 0.15), value: hovered)
        .opacity(enabled ? 1 : 0.4)
    }
  }
}

/// The Ask field, in the footer's left slot: the orb (the assistant's whole
/// status), the text, the mic, and send or stop.
struct AssistantField: View {
  let state: AssistantState
  let voiceEnabled: Bool
  let paused: Bool
  @FocusState private var focused: Bool

  var body: some View {
    let binding = Binding(get: { state.text }, set: {
      state.text = $0
      if state.speaking { state.stopSpeaking() }
    })
    let empty = state.text.trimmingCharacters(in: .whitespaces).isEmpty
    HStack(spacing: 6) {
      ThinkingOrb(state: state.orb, tint: state.live != nil ? Color(hex: 0xB18CFF) : Palette.text, paused: paused || state.orbResting)
      TextField("", text: binding, prompt: fieldPrompt(state.placeholder))
        .textFieldStyle(.plain)
        .islandFont(11)
        .foregroundStyle(Palette.text)
        .tint(Palette.caret)
        .focused($focused)
        .onSubmit { state.ask() }
        .onExitCommand {
          if state.live != nil {
            state.cancel()
          } else {
            state.close()
          }
        }
        .accessibilityLabel("Ask Apple Intelligence about your agents")
      if voiceEnabled && state.live == nil && (empty || state.voice != nil) {
        Button { state.toggleVoice() } label: {
          Image(systemName: "mic").islandFont(12).frame(width: 22, height: 22)
        }
        .buttonStyle(MicKey(on: state.voice != nil, speaking: state.speaking))
        .help(state.voice != nil ? "Stop listening" : state.speaking ? "Stop speaking" : "Speak your question")
        .accessibilityLabel(state.voice != nil ? "Stop listening" : state.speaking ? "Stop speaking" : "Speak your question")
      }
      if state.live != nil {
        Button { state.cancel() } label: { Image(systemName: "xmark").islandFont(10, weight: .bold).frame(width: 22, height: 22) }
          .buttonStyle(SendKey(ready: true))
          .help("Stop")
          .accessibilityLabel("Stop answering")
      } else if !(empty && voiceEnabled) && state.voice == nil {
        Button { state.ask() } label: { Image(systemName: "arrow.up.circle").islandFont(11).frame(width: 22, height: 22) }
          .buttonStyle(SendKey(ready: !empty))
          .disabled(empty)
          .help("Ask")
          .accessibilityLabel("Ask")
      }
    }
    .padding(.init(top: 0, leading: 5, bottom: 0, trailing: 3))
    .frame(height: 28)
    .modifier(FieldPill(focused: focused))
    .overlay { FieldBeam(focused: focused, loading: state.live?.status == .thinking, since: state.live?.askedAt, paused: paused) }
    .onChange(of: focused) { _, now in state.focused = now }
    .onAppear { focused = true }
  }
}

private struct MicKey: ButtonStyle {
  let on: Bool
  let speaking: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(on ? .white : speaking ? Color(hex: 0x3FCF8E) : .white.opacity(0.7))
      .background(Circle().fill(on ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x3FCF8E), Color(hex: 0x1F9E6A)], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.white.opacity(0.08))))
      .modifier(Breathing(active: on))
  }
}

/// Listening: a green key that breathes.
private struct Breathing: ViewModifier {
  let active: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    if active && !reduceMotion {
      // A ring spreading 0 → 4 pt as it fades 0.5 → 0.18, and back.
      content.phaseAnimator([false, true]) { view, out in
        view.background(Circle().stroke(Color(hex: 0x3FCF8E).opacity(out ? 0.18 : 0.5), lineWidth: out ? 4 : 0).padding(out ? -2 : 0))
      } animation: { _ in .easeInOut(duration: 0.7) }
    } else {
      content
    }
  }
}

/// The assistant as three small bots in the footer's left corner: the door
/// to it. With nothing running they say so and offer to help, a line at a time.
struct BotCrewButton: View {
  let working: Bool
  let talk: Bool
  let paused: Bool
  let disabledReason: String?
  /// The assistant is open.
  var on = false
  let action: () -> Void

  private let held = State(initialValue: Int(Date.now.timeIntervalSinceReferenceDate / 4.5) % BotCrewButton.lines.count)

  static let lines = [
    "Nothing running. Ask us anything",
    "Need a hand with something?",
    "What should we build next?",
    "Ask a question, draft an email…",
  ]

  var body: some View {
    Button {
      if disabledReason == nil { action() }
    } label: {
      HStack(spacing: 8) {
        // One mascot, a little bigger: it follows the pointer and hops at a
        // click, which still opens the assistant.
        BotStage(
          bots: [StageBot(
            look: BotLook.crew[0].look, state: working ? .working : .idle, seed: BotLook.crew[0].seed, size: 28,
            style: BotPose.Style(turn: 1.4), box: CGRect(x: 0, y: 0, width: 28, height: 28)
          )],
          size: CGSize(width: 28, height: 28), paused: paused, interactive: true
        )
        if talk {
          // A new line every 4.5 s, rolling in; paused, the current one stays.
          TimelineView(.periodic(from: .now, by: 4.5)) { timeline in
            let index = Int(timeline.date.timeIntervalSinceReferenceDate / 4.5) % Self.lines.count
            let line = paused ? held.wrappedValue : index
            Text(disabledReason ?? Self.lines[line])
              .islandFont(11)
              .foregroundStyle(Palette.text.opacity(0.8))
              .lineLimit(1)
              .modifier(Entrance(kind: .countRoll))
              .id(line)
              .transition(.identity)
              .onChange(of: index) { _, now in if !paused { held.wrappedValue = now } }
          }
        }
      }
      .padding(.init(top: 2, leading: 2, bottom: 2, trailing: 8))
      .contentShape(Capsule())
    }
    .buttonStyle(CrewStyle(on: on))
    .opacity(disabledReason == nil ? 1 : 0.55)
    .help(disabledReason ?? "Ask Apple Intelligence")
    .accessibilityLabel(disabledReason ?? "Ask Apple Intelligence")
  }
}

/// A faint tile under the pointer, and while the assistant is open.
private struct CrewStyle: ButtonStyle {
  let on: Bool

  func makeBody(configuration: Configuration) -> some View {
    Hovering { hovered in
      configuration.label
        .background(Capsule().fill(.white.opacity(hovered || on ? 0.06 : 0)))
        .animation(.easeInOut(duration: 0.12), value: hovered || on)
    }
  }
}

/// While the assistant is open, a soft silver glow washes in from the
/// island's real outline (1.x's IslandGlow), brighter while it answers. It
/// follows the edge only: nothing glows along the bezel at the top.
struct IslandGlow: View {
  let corner: CGFloat
  let bright: Bool
  let paused: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let beam = LinearGradient(
      stops: [
        .init(color: Color(white: 150 / 255), location: 0), .init(color: Color(white: 215 / 255), location: 0.3),
        .init(color: Color(white: 175 / 255), location: 0.55), .init(color: Color(white: 230 / 255), location: 0.8),
        .init(color: Color(white: 160 / 255), location: 1),
      ],
      startPoint: .leading, endPoint: .trailing
    )
    ZStack {
      IslandEdge(corner: corner).stroke(beam, lineWidth: 56).blur(radius: 14).opacity(bright ? 0.2 : 0.13)
      IslandEdge(corner: corner).stroke(beam, lineWidth: 1.5).opacity(bright ? 0.26 : 0.18)
    }
    .clipShape(IslandShape(corner: corner))
    .modifier(GlowPulse(active: !paused && !reduceMotion))
    .allowsHitTesting(false)
  }
}

private struct GlowPulse: ViewModifier {
  let active: Bool

  func body(content: Content) -> some View {
    if active {
      content.phaseAnimator([0.6, 1.0]) { view, opacity in view.opacity(opacity) } animation: { _ in .easeInOut(duration: 1.15) }
    } else {
      content.opacity(0.8)
    }
  }
}

import IslandCore
import SwiftUI

/// "Permission Request": what the agent wants to do (a diff, a command, a
/// plan to review) with Deny ⌘N and Allow ⌘Y. The daemon holds the agent's
/// hook open until one is pressed. Just who, what, and two pills; the
/// shortcuts live in Settings.
struct ApprovalCard: View {
  let session: SessionSnapshot
  let approval: PendingApproval
  let model: IslandModel

  var body: some View {
    VStack(spacing: 10) {
      CardTop(session: session)
      Text(approval.title)
        .islandFont(15, weight: .semibold)
        .foregroundStyle(Palette.text)
        .multilineTextAlignment(.center)
      ApprovalBody(request: approval.body)
      HStack(spacing: 8) {
        Button { model.actions.decide(approval.id, allow: false) } label: { Text("Deny") }
          .buttonStyle(Pill(kind: .quiet))
          .accessibilityLabel("Deny")
        Button { model.actions.decide(approval.id, allow: true) } label: { Text("Allow") }
          .buttonStyle(Pill(kind: .bright))
          .accessibilityLabel("Allow")
      }
      .padding(.top, 2)
    }
    .frame(maxWidth: .infinity)
    .padding(.init(top: 10, leading: 18, bottom: 14, trailing: 18))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Permission request from \(session.projectName): \(approval.title)")
  }
}

/// One quiet line: the agent's robot, its name, the project.
private struct CardTop: View {
  let session: SessionSnapshot

  var body: some View {
    HStack(spacing: 6) {
      AgentAvatar(session: session, now: .now, size: 18, badge: false)
      Text(session.agent.name).foregroundStyle(Palette.text.opacity(0.7))
      Text(session.projectName).foregroundStyle(Palette.textDim)
    }
    .islandFont(11, weight: .medium)
    .lineLimit(1)
  }
}

/// A small capsule: bright for the answer you'll most often give, quiet otherwise.
private struct Pill: ButtonStyle {
  enum Kind { case bright, quiet, picked }
  let kind: Kind
  /// A long answer: a full-width rounded row that wraps, not a chip.
  var wide = false

  func makeBody(configuration: Configuration) -> some View {
    Hovering { hovered in
      let lit = hovered || configuration.isPressed
      let shape = RoundedRectangle(cornerRadius: wide ? 14 : 100, style: .continuous)
      configuration.label
        .islandFont(12, weight: .medium)
        .lineLimit(wide ? nil : 1)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: wide)
        .padding(.init(top: wide ? 8 : 6, leading: 16, bottom: wide ? 8 : 6, trailing: 16))
        .frame(minWidth: 84, maxWidth: wide ? .infinity : nil)
        .foregroundStyle(foreground(lit))
        .background(shape.fill(fill(lit)))
        .contentShape(shape)
        .scaleEffect(configuration.isPressed ? 0.96 : 1)
        .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
        .animation(.easeInOut(duration: 0.15), value: lit)
    }
  }

  private func foreground(_ lit: Bool) -> Color {
    switch kind {
    case .bright: Color(hex: 0x111214)
    case .quiet: Palette.text.opacity(lit ? 1 : 0.78)
    case .picked: Palette.done
    }
  }

  private func fill(_ lit: Bool) -> Color {
    switch kind {
    case .bright: Color(hex: lit ? 0xFFFFFF : 0xEDEDED)
    case .quiet: .white.opacity(lit ? 0.13 : 0.07)
    case .picked: Palette.done.opacity(lit ? 0.24 : 0.18)
    }
  }
}

extension AgentKind {
  /// "Claude", on a card's header.
  fileprivate var name: String {
    switch self {
    case .claudeCode: "Claude"
    case .codex: "Codex"
    case .cursor: "Cursor"
    }
  }
}

/// The request itself, scrolling past 150 pt.
private struct ApprovalBody: View {
  let request: PendingApproval.Body

  var body: some View {
    ScrollView(.vertical) {
      content
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .scrollIndicators(.automatic)
    .frame(maxHeight: 150)
    .fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder private var content: some View {
    switch request {
    case let .plan(markdown):
      MarkdownView(blocks: MarkdownBlock.parse(markdown))
    case let .diff(removed, added):
      VStack(alignment: .leading, spacing: 5) {
        ScrollView(.horizontal) {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(removed.enumerated()), id: \.offset) { _, line in
              DiffLine(text: "- \(line)", color: Color(hex: 0xFF8F88), fill: Palette.failed.opacity(0.1))
            }
            ForEach(Array(added.enumerated()), id: \.offset) { _, line in
              DiffLine(text: "+ \(line)", color: Color(hex: 0x7EE0A6), fill: Palette.done.opacity(0.1))
            }
          }
          .padding(.vertical, 6)
        }
        .codeBox()
        HStack(spacing: 4) {
          Text("+\(added.count)").foregroundStyle(Palette.done)
          Text("-\(removed.count)").foregroundStyle(Palette.failed)
        }
        .islandFont(10.5)
        .monospacedDigit()
      }
    case let .command(text), let .raw(text):
      Text(text)
        .islandFont(11.5, design: .monospaced)
        .foregroundStyle(Palette.textDim)
        .multilineTextAlignment(.center)
        .lineSpacing(3)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }
  }
}

private struct DiffLine: View {
  let text: String
  let color: Color
  let fill: Color

  var body: some View {
    Text(text)
      .islandFont(11, design: .monospaced)
      .foregroundStyle(color)
      .fixedSize()
      .padding(.horizontal, 10)
      // 1.55 line height.
      .padding(.vertical, 2)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(fill)
  }
}

extension View {
  fileprivate func codeBox(_ shade: Double = 0.4) -> some View {
    background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(shade)))
  }
}

/// A plan, block by block, with inline code, bold and italic.
struct MarkdownView: View {
  let blocks: [MarkdownBlock]

  @Environment(\.uiScale) private var scale

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        switch block {
        case let .heading(_, text):
          inline(text).islandFont(12.5, weight: .semibold).padding(.top, 4)
        case let .bullet(text):
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•")
            inline(text)
          }
          .padding(.leading, 6)
        case let .code(text):
          Text(text)
            .islandFont(11, design: .monospaced)
            .padding(.init(top: 8, leading: 10, bottom: 8, trailing: 10))
            .frame(maxWidth: .infinity, alignment: .leading)
            .codeBox(0.35)
        case let .quote(text):
          inline(text)
            .foregroundStyle(Palette.textDim)
            .padding(.leading, 8)
            .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.18)).frame(width: 2) }
        case .rule:
          Divider().overlay(.white.opacity(0.12))
        case let .paragraph(text):
          inline(text)
        }
      }
    }
    .islandFont(12)
    .foregroundStyle(Palette.text)
    .lineSpacing(3)
    .textSelection(.enabled)
  }

  /// Inline marks only; anything else stays literal text.
  private func inline(_ text: String) -> Text {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    var parsed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    // Inline code sits on a faint tile, a hair of room either side.
    let codes = parsed.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }.map(\.range)
    for range in codes.reversed() {
      var code = AttributedString("\u{2009}" + String(parsed[range].characters) + "\u{2009}")
      code.font = .system(size: 11 * scale, design: .monospaced)
      code.backgroundColor = .white.opacity(0.08)
      parsed.replaceSubrange(range, with: code)
    }
    return Text(parsed)
  }
}

/// "Claude asks": the question(s) an agent waits on. One single-select
/// question answers on a click (or ⌘1…9); several send once each has a pick;
/// multi-select waits for Send. Clicking the card itself jumps to the terminal.
struct QuestionCard: View {
  let session: SessionSnapshot
  let question: PendingQuestion
  let model: IslandModel

  /// The answer under the pointer: its description shows beneath the chips.
  private let peek = State<(question: Int, option: Int)?>(initialValue: nil)

  var body: some View {
    let picks = model.picks(for: question)
    VStack(spacing: 16) {
      CardTop(session: session)
      ForEach(Array(question.questions.enumerated()), id: \.offset) { index, item in
        block(item, index: index, picks: picks)
      }
      if picks.anyMulti {
        Button("Send") {
          if picks.isComplete { model.actions.answer(session, selections: picks.picked) }
        }
        .buttonStyle(Pill(kind: picks.isComplete ? .bright : .quiet))
        .disabled(!picks.isComplete)
        .opacity(picks.isComplete ? 1 : 0.4)
        .animation(.easeInOut(duration: 0.15), value: picks.isComplete)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.init(top: 10, leading: 18, bottom: 14, trailing: 18))
    .contentShape(Rectangle())
    .onTapGesture { JumpBack.jump(to: session) }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private func block(_ item: PendingQuestion.Item, index: Int, picks: QuestionPicks) -> some View {
    let multi = item.multiSelect == true
    // "Redis — fast, in-memory": the name on the chip, the rest underneath.
    let options = item.options.prefix(9).map { label in
      let parts = label.components(separatedBy: " — ")
      return (title: parts[0], detail: parts.dropFirst().joined(separator: " — "), label: label)
    }
    // Long answers read as rows; short ones sit side by side as chips.
    let wide = options.contains { $0.title.count > 30 }
    let described = !wide && options.contains { !$0.detail.isEmpty }
    VStack(spacing: 10) {
      Text(item.question)
        .islandFont(15, weight: .semibold)
        .foregroundStyle(Palette.text)
        // A long question reads better ragged-left than centred.
        .multilineTextAlignment(item.question.count > 110 ? .leading : .center)
        .lineSpacing(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 400)
      let chips = ForEach(Array(options.enumerated()), id: \.offset) { option, entry in
        let on = picks.picked.indices.contains(index) && picks.picked[index].contains(option)
        Button {
          model.choose(session, question: index, option: option)
        } label: {
          HStack(spacing: 6) {
            // Pick-any shows its ticks: the only hint that more than one goes.
            if multi {
              Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .islandFont(11, weight: .medium)
                .opacity(on ? 1 : 0.55)
            }
            if wide && !entry.detail.isEmpty {
              VStack(spacing: 2) {
                Text(entry.title)
                Text(entry.detail).islandFont(10.5).foregroundStyle(Palette.textDim)
              }
            } else {
              Text(entry.title)
            }
          }
        }
        .buttonStyle(Pill(kind: on ? .picked : .quiet, wide: wide))
        .onHover { inside in
          if inside { peek.wrappedValue = (index, option) } else if peek.wrappedValue?.question == index && peek.wrappedValue?.option == option { peek.wrappedValue = nil }
        }
        .accessibilityLabel(entry.label)
        .accessibilityAddTraits(on ? .isSelected : [])
      }
      if wide {
        VStack(spacing: 6) { chips }.frame(maxWidth: 380)
      } else {
        FlowLayout(spacing: 6, centered: true) { chips }
      }
      if described {
        // One quiet line, the hovered answer's description; room kept so nothing jumps.
        let shown = peek.wrappedValue.flatMap { $0.question == index ? options[$0.option].detail : nil } ?? ""
        Text(shown.isEmpty ? " " : shown)
          .islandFont(10.5)
          .foregroundStyle(Palette.textDim)
          .lineLimit(1)
          .animation(.easeOut(duration: 0.12), value: shown)
      }
    }
  }
}

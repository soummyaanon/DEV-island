import IslandCore
import SwiftUI

/// "Permission Request": what the agent wants to do (a diff, a command, a
/// plan to review) with Deny ⌘N and Allow ⌘Y. The daemon holds the agent's
/// hook open until one is pressed.
struct ApprovalCard: View {
  let session: SessionSnapshot
  let approval: PendingApproval
  let model: IslandModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      CardTop(session: session, kicker: "Permission Request")
      Text(approval.title)
        .islandFont(13.5, weight: .semibold)
        .foregroundStyle(Palette.text)
        .padding(.bottom, 9)
      ApprovalBody(request: approval.body)
        .padding(.bottom, 11)
      HStack(spacing: 8) {
        Button { model.actions.decide(approval.id, allow: false) } label: {
          KeyLabel(title: "Deny", key: "⌘N")
        }
        .buttonStyle(CardButton(kind: .deny))
        .accessibilityLabel("Deny")
        Button { model.actions.decide(approval.id, allow: true) } label: {
          KeyLabel(title: "Allow", key: "⌘Y")
        }
        .buttonStyle(CardButton(kind: .allow))
        .accessibilityLabel("Allow")
      }
    }
    .padding(.init(top: 11, leading: 13, bottom: 12, trailing: 13))
    .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.03)))
    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
    .padding(.init(top: 2, leading: 9, bottom: 8, trailing: 9))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Permission request from \(session.projectName): \(approval.title)")
  }
}

/// The robot, the kicker, and the project.
private struct CardTop: View {
  let session: SessionSnapshot
  let kicker: String

  var body: some View {
    HStack(spacing: 8) {
      HStack(spacing: 7) {
        AgentAvatar(session: session, now: .now, size: 26, badge: false)
          .padding(.init(top: -6, leading: -4, bottom: -6, trailing: 0))
        Text(kicker.uppercased())
          .islandFont(10, weight: .semibold)
          .tracking(0.6)
          .foregroundStyle(Palette.textDim)
      }
      Spacer(minLength: 8)
      Text(session.projectName)
        .islandFont(10.5)
        .foregroundStyle(Palette.textDim)
        .lineLimit(1)
    }
    .padding(.bottom, 8)
  }
}

private struct KeyLabel: View {
  let title: String
  let key: String

  var body: some View {
    HStack(spacing: 7) {
      Text(title)
      Text(key).islandFont(10).monospacedDigit().opacity(0.55)
    }
  }
}

private struct CardButton: ButtonStyle {
  enum Kind { case allow, deny }
  let kind: Kind

  func makeBody(configuration: Configuration) -> some View {
    Hovering { hovered in
      let lit = hovered || configuration.isPressed
      configuration.label
        .islandFont(12.5, weight: .semibold)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .foregroundStyle(kind == .allow ? Color(hex: 0x111214) : Palette.text)
        .background(
          RoundedRectangle(cornerRadius: 10)
            .fill(kind == .allow ? Color(hex: lit ? 0xFFFFFF : 0xECECEC) : .white.opacity(lit ? 0.1 : 0.06))
        )
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(kind == .deny ? .white.opacity(0.1) : .clear))
        .scaleEffect(configuration.isPressed ? 0.98 : 1)
        .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
        .animation(.easeInOut(duration: 0.15), value: lit)
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
        .islandFont(11, design: .monospaced)
        .foregroundStyle(Palette.text)
        .lineSpacing(3)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.init(top: 8, leading: 10, bottom: 8, trailing: 10))
        .codeBox()
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
    background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(shade)))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.06)))
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

  var body: some View {
    let picks = model.picks(for: question)
    ScrollView(.vertical) {
      VStack(alignment: .leading, spacing: 0) {
        CardTop(session: session, kicker: session.agent.asks)
        ForEach(Array(question.questions.enumerated()), id: \.offset) { index, item in
          block(item, index: index, picks: picks)
            .padding(.top, index == 0 ? 0 : 10)
        }
        HStack(spacing: 8) {
          Spacer(minLength: 0)
          Text(picks.hint)
            .islandFont(10)
            .foregroundStyle(Palette.textDim)
            .multilineTextAlignment(.trailing)
          if picks.anyMulti {
            Button("Send") {
              if picks.isComplete { model.actions.answer(session, selections: picks.picked) }
            }
            .buttonStyle(SendPill())
            .disabled(!picks.isComplete)
          }
        }
        // `.q-options { margin-bottom: 8px }`
        .padding(.top, 8)
      }
      .padding(.init(top: 11, leading: 13, bottom: 10, trailing: 13))
    }
    .frame(maxHeight: 285)
    .fixedSize(horizontal: false, vertical: true)
    .background(RoundedRectangle(cornerRadius: 14).fill(Palette.working.opacity(model.hovered == question.id ? 0.1 : 0.06)))
    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.working.opacity(0.22)))
    .contentShape(RoundedRectangle(cornerRadius: 14))
    .onTapGesture { JumpBack.jump(to: session) }
    .onHover { inside in model.hovered = inside ? question.id : (model.hovered == question.id ? nil : model.hovered) }
    .padding(.init(top: 2, leading: 9, bottom: 8, trailing: 9))
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private func block(_ item: PendingQuestion.Item, index: Int, picks: QuestionPicks) -> some View {
    let multi = item.multiSelect == true
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(item.question)
          .islandFont(13, weight: .semibold)
          .foregroundStyle(Palette.text)
          .lineSpacing(3)
          .fixedSize(horizontal: false, vertical: true)
        if multi {
          Text("choose any")
            .islandFont(10, weight: .semibold)
            .foregroundStyle(Palette.working)
            .padding(.horizontal, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(Palette.working.opacity(0.14)))
        }
      }
      VStack(spacing: 4) {
        ForEach(Array(item.options.prefix(9).enumerated()), id: \.offset) { option, label in
          let on = picks.picked.indices.contains(index) && picks.picked[index].contains(option)
          Button {
            model.choose(session, question: index, option: option)
          } label: {
            HStack(spacing: 8) {
              if picks.isInstant {
                Text("⌘\(option + 1)")
                  .islandFont(10, weight: .bold)
                  .foregroundStyle(Palette.working)
                  .padding(.horizontal, 5)
                  .background(RoundedRectangle(cornerRadius: 5).fill(Palette.working.opacity(0.14)))
              } else if multi {
                RoundedRectangle(cornerRadius: 2.5)
                  .strokeBorder(on ? Palette.done : Palette.textDim, lineWidth: 1.5)
                  .background(RoundedRectangle(cornerRadius: 2.5).fill(on ? Palette.done : .clear))
                  .overlay { if on { Image(systemName: "checkmark").islandFont(6, weight: .heavy).foregroundStyle(.black) } }
                  .frame(width: 9, height: 9)
              } else {
                Circle()
                  .strokeBorder(on ? Palette.done : Palette.textDim, lineWidth: 1.5)
                  .background(Circle().fill(on ? Palette.done : .clear))
                  .frame(width: 8, height: 8)
              }
              Text(label)
                .islandFont(12)
                .foregroundStyle(Palette.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.init(top: 5, leading: 9, bottom: 5, trailing: 9))
            .contentShape(Rectangle())
          }
          .buttonStyle(OptionButton(picked: on))
          .accessibilityAddTraits(on ? .isSelected : [])
        }
      }
    }
  }
}

private struct OptionButton: ButtonStyle {
  let picked: Bool

  func makeBody(configuration: Configuration) -> some View {
    Hovering { hovered in
      let lit = hovered || configuration.isPressed
      configuration.label
        .background(
          RoundedRectangle(cornerRadius: 8).fill(
            picked ? Palette.done.opacity(0.16) : lit ? Palette.working.opacity(0.16) : .white.opacity(0.05)
          )
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(picked ? Palette.done.opacity(0.55) : lit ? Palette.accent.opacity(0.55) : .clear)
        )
        .animation(.easeInOut(duration: 0.1), value: lit)
    }
  }
}

private struct SendPill: ButtonStyle {
  @Environment(\.isEnabled) private var enabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .islandFont(10.5, weight: .semibold)
      .foregroundStyle(.black)
      .padding(.init(top: 2, leading: 11, bottom: 2, trailing: 11))
      .background(Capsule().fill(Palette.done))
      .opacity(enabled ? 1 : 0.35)
  }
}

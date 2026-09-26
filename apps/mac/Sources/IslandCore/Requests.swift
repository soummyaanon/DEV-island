import Foundation

// What the approval and question cards show and how their picks work
// (1.x's ApprovalCard.tsx, QuestionCard.tsx and markdown.ts).

extension PendingApproval {
  /// "Edit src/middleware.ts", "Run command", "Review plan"…
  public var title: String {
    let file = toolInput["file_path"]?.string.map(Self.shortPath)
    return switch toolName {
    case "Edit", "MultiEdit": file.map { "Edit \($0)" } ?? "Edit file"
    case "Write": file.map { "Write \($0)" } ?? "Write file"
    case "Read": file.map { "Read \($0)" } ?? "Read file"
    case "Bash": "Run command"
    case "ExitPlanMode": "Review plan"
    default: toolName
    }
  }

  /// The last two path components.
  static func shortPath(_ path: String) -> String {
    let parts = path.split(separator: "/").suffix(2)
    return parts.isEmpty ? path : parts.joined(separator: "/")
  }

  /// What the card's body shows.
  public enum Body: Equatable, Sendable {
    case plan(String)
    case diff(removed: [String], added: [String])
    case command(String)
    /// Anything else, pretty-printed; "no details" when empty.
    case raw(String)
  }

  public var body: Body {
    if let plan, !plan.isEmpty { return .plan(plan) }
    let old = toolInput["old_string"]?.string ?? ""
    let new = toolInput["new_string"]?.string ?? ""
    let content = toolInput["content"]?.string ?? ""
    let added = new.isEmpty ? content : new
    if !old.isEmpty || !added.isEmpty {
      return .diff(
        removed: old.isEmpty ? [] : old.components(separatedBy: "\n"),
        added: added.isEmpty ? [] : added.components(separatedBy: "\n")
      )
    }
    if let command = toolInput["command"]?.string { return .command(command) }
    guard !toolInput.isEmpty else { return .raw("no details") }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(toolInput)) ?? Data()
    return .raw(String(decoding: data, as: UTF8.self))
  }
}

/// Markdown for plan review, as blocks: headings, lists, fenced code, quotes,
/// rules, paragraphs. Inline marks (code, bold, italic) are left in the text
/// for the view's `AttributedString(markdown:)`. Nothing is ever rendered as
/// HTML, so agent output can't inject anything.
public enum MarkdownBlock: Equatable, Sendable {
  case heading(level: Int, text: String)
  case bullet(String)
  case code(String)
  case quote(String)
  case rule
  case paragraph(String)

  public static func parse(_ source: String) -> [MarkdownBlock] {
    var blocks: [MarkdownBlock] = []
    var code: [String]?
    for line in source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
      if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
        if let lines = code {
          blocks.append(.code(lines.joined(separator: "\n")))
          code = nil
        } else {
          code = []
        }
        continue
      }
      if code != nil {
        code?.append(line)
        continue
      }
      if let heading = line.wholeMatch(of: /(#{1,4})\s+(.*)/) {
        blocks.append(.heading(level: heading.1.count, text: String(heading.2)))
      } else if let item = line.wholeMatch(of: /\s*[-*+]\s+(.*)/) {
        blocks.append(.bullet(String(item.1)))
      } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
        continue
      } else if let quote = line.wholeMatch(of: /\s*>\s?(.*)/) {
        blocks.append(.quote(String(quote.1)))
      } else if line.wholeMatch(of: /\s*(-{3,}|\*{3,})\s*/) != nil {
        blocks.append(.rule)
      } else {
        blocks.append(.paragraph(line))
      }
    }
    if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
    return blocks
  }
}

/// The picks on a question card. One single-select question answers on the
/// first click; several single-select questions send once each has a pick;
/// any multi-select question waits for Send.
public struct QuestionPicks: Equatable, Sendable {
  public let question: PendingQuestion
  public private(set) var picked: [[Int]]

  public init(_ question: PendingQuestion) {
    self.question = question
    picked = question.questions.map { _ in [] }
  }

  public var anyMulti: Bool { question.questions.contains { $0.multiSelect == true } }

  /// One single-select question: a click (or ⌘1…9) answers at once.
  public var isInstant: Bool { question.questions.count == 1 && !anyMulti }

  /// Every question has at least one pick.
  public var isComplete: Bool { picked.count == question.questions.count && picked.allSatisfy { !$0.isEmpty } }

  /// Picks an option; returns the answer when the card should send itself now.
  public mutating func choose(question index: Int, option: Int) -> [[Int]]? {
    if isInstant { return [[option]] }
    guard picked.indices.contains(index) else { return nil }
    if question.questions[index].multiSelect == true {
      if let at = picked[index].firstIndex(of: option) {
        picked[index].remove(at: at)
      } else {
        picked[index].append(option)
        picked[index].sort()
      }
    } else {
      picked[index] = [option]
    }
    return !anyMulti && isComplete ? picked : nil
  }

  public var hint: String {
    if isInstant { return "⌘n or click to answer · click card to jump" }
    if anyMulti { return "tick all that apply, then Send · click card to jump" }
    return "pick one per question — sends itself · click card to jump"
  }
}

extension AgentKind {
  /// "Claude asks", on a question card.
  public var asks: String {
    switch self {
    case .claudeCode: "Claude asks"
    case .codex: "Codex asks"
    case .cursor: "Cursor asks"
    }
  }
}

/// Sending a prompt or an answer into a terminal (1.x's jump-back.ts).
public enum TerminalInput {
  /// Single-line only: newlines flatten, so a stray Enter never splits a send.
  public static func flatten(_ text: String) -> String {
    text.replacing(/\s*\n\s*/, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// An AppleScript string literal body: backslashes first, then quotes.
  public static func appleScriptEscaped(_ text: String) -> String {
    text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
  }

  /// Types `text` and Enter into whatever just came to the front.
  public static func typeScript(_ text: String) -> String {
    """
    delay 0.4
    tell application "System Events"
      keystroke "\(appleScriptEscaped(text))"
      key code 36
    end tell
    """
  }

  /// Claude's question UI moves with arrow keys and confirms with Enter; it
  /// ignores number keys.
  public static func answerScript(option: Int) -> String? {
    guard (0..<9).contains(option) else { return nil }
    return """
      delay 0.4
      tell application "System Events"
        repeat \(option) times
          key code 125
        end repeat
        key code 36
      end tell
      """
  }

  /// Cursor's agent input is Composer: focus it by command id (a toggle
  /// shortcut would close an open side panel), paste, then ⌘↩ to force-send.
  public static let cursorComposerScript = """
    delay 0.55
    tell application "System Events"
      keystroke "p" using {command down, shift down}
      delay 0.35
      keystroke "composer.focusComposer"
      delay 0.2
      key code 36
      delay 0.4
      keystroke "v" using command down
      delay 0.12
      keystroke return using command down
    end tell
    """
}

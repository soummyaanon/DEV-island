import Foundation
import IslandCore
import Testing

// Ported from 1.x's ApprovalCard / QuestionCard behaviour and jump-back tests.

private let date = Date(timeIntervalSince1970: 1_790_000_000)

private func approval(_ tool: String, _ input: [String: JSONValue] = [:], plan: String? = nil) -> PendingApproval {
  PendingApproval(id: "a1", toolName: tool, toolInput: input, plan: plan, createdAt: date)
}

private func question(_ items: [PendingQuestion.Item]) -> PendingQuestion {
  PendingQuestion(id: "q1", questions: items, createdAt: date)
}

@Suite struct ApprovalTests {
  @Test(arguments: [
    ("Edit", "Edit src/middleware.ts"), ("MultiEdit", "Edit src/middleware.ts"), ("Write", "Write src/middleware.ts"),
    ("Read", "Read src/middleware.ts"),
  ])
  func `titles file tools with the last two path parts`(tool: String, title: String) {
    #expect(approval(tool, ["file_path": .string("/Users/me/app/src/middleware.ts")]).title == title)
  }

  @Test func `titles the rest`() {
    #expect(approval("Edit").title == "Edit file")
    #expect(approval("Bash").title == "Run command")
    #expect(approval("ExitPlanMode").title == "Review plan")
    #expect(approval("WebFetch").title == "WebFetch")
  }

  @Test func `shows a plan, a diff, a command, or the raw input`() {
    #expect(approval("ExitPlanMode", plan: "# Plan").body == .plan("# Plan"))
    #expect(approval("Edit", ["old_string": .string("a\nb"), "new_string": .string("c")]).body
      == .diff(removed: ["a", "b"], added: ["c"]))
    #expect(approval("Write", ["content": .string("x")]).body == .diff(removed: [], added: ["x"]))
    #expect(approval("Bash", ["command": .string("ls -la")]).body == .command("ls -la"))
    #expect(approval("Tool").body == .raw("no details"))
    #expect(approval("Tool", ["url": .string("https://a.b/c")]).body == .raw("{\n  \"url\" : \"https://a.b/c\"\n}"))
  }
}

@Suite struct MarkdownTests {
  @Test func `splits a plan into blocks`() {
    let source = """
      # Plan
      Some **bold** text
      - one
      * two
      > note
      ---
      ```
      let x = 1
      ```
      """
    #expect(MarkdownBlock.parse(source) == [
      .heading(level: 1, text: "Plan"), .paragraph("Some **bold** text"), .bullet("one"), .bullet("two"),
      .quote("note"), .rule, .code("let x = 1"),
    ])
  }

  @Test func `closes an unterminated code fence`() {
    #expect(MarkdownBlock.parse("```\n<script>") == [.code("<script>")])
  }
}

@Suite struct QuestionPickTests {
  @Test func `one single-select question answers on the first click`() {
    var picks = QuestionPicks(question([.init(question: "Deploy?", options: ["Prod", "Staging"])]))
    #expect(picks.isInstant)
    #expect(picks.choose(question: 0, option: 1) == [[1]])
  }

  @Test func `several single-select questions send once each has a pick`() {
    var picks = QuestionPicks(question([
      .init(question: "A?", options: ["1", "2"]), .init(question: "B?", options: ["3", "4"]),
    ]))
    #expect(!picks.isInstant)
    #expect(picks.choose(question: 0, option: 0) == nil)
    #expect(picks.choose(question: 0, option: 1) == nil)
    #expect(picks.choose(question: 1, option: 0) == [[1], [0]])
  }

  @Test func `a multi-select question ticks and unticks, and waits for Send`() {
    var picks = QuestionPicks(question([.init(question: "Which?", options: ["a", "b", "c"], multiSelect: true)]))
    #expect(picks.choose(question: 0, option: 2) == nil)
    #expect(picks.choose(question: 0, option: 0) == nil)
    #expect(picks.picked == [[0, 2]])
    #expect(picks.isComplete)
    _ = picks.choose(question: 0, option: 2)
    #expect(picks.picked == [[0]])
    #expect(picks.hint.hasPrefix("tick all"))
  }
}

@Suite struct TerminalInputTests {
  @Test func `flattens newlines and escapes for AppleScript`() {
    #expect(TerminalInput.flatten("  fix\n  the test \n") == "fix the test")
    #expect(TerminalInput.typeScript(#"say "hi""#).contains(#"keystroke "say \"hi\"""#))
    #expect(TerminalInput.typeScript("x").contains("key code 36"))
  }

  @Test func `answers with arrow keys and Enter, never a number key`() {
    let script = TerminalInput.answerScript(option: 1)!
    #expect(script.contains("repeat 1 times") && script.contains("key code 125") && script.contains("key code 36"))
    #expect(!script.contains(#"keystroke "2""#))
    #expect(TerminalInput.answerScript(option: 9) == nil)
  }

  @Test func `sends to Cursor through Composer with a paste and cmd-return`() {
    let script = TerminalInput.cursorComposerScript
    #expect(script.contains("composer.focusComposer"))
    #expect(script.contains(#"keystroke "v" using command down"#))
    #expect(script.contains("keystroke return using command down"))
  }
}

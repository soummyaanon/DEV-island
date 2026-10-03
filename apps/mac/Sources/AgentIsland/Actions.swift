import AppKit
import ApplicationServices
import IslandCore

/// What the island does for you: allow or deny a held tool call, answer a
/// question, send a prompt into the agent's terminal (1.x's main-process
/// handlers and jump-back.ts).
final class IslandActions {
  private let daemon: DaemonClient
  private let store: SessionStore
  /// Allowing and answering chime and bloom; wired to sounds and haptics.
  var feedback: (Feedback) -> Void = { _ in }

  enum Feedback {
    /// Allowed, or answered through the hook.
    case approve
    /// Any decision, felt as a single tap.
    case commit
  }

  enum PromptResult {
    case sent, noAccessibility, empty
  }

  init(daemon: DaemonClient, store: SessionStore) {
    self.daemon = daemon
    self.store = store
  }

  func decide(_ approvalId: String, allow: Bool) {
    if allow {
      store.firePulse(.approve)
      feedback(.approve)
    }
    feedback(.commit)
    Task { await daemon.resolveApproval(id: approvalId, decision: allow ? "allow" : "deny") }
  }

  /// Claude's questions go back through the daemon's held hook; Codex, or a
  /// hold that has expired, falls back to the terminal: arrow keys for one
  /// pick of one question, a plain jump for anything else.
  func answer(_ session: SessionSnapshot, selections: [[Int]]) {
    let question = session.pendingQuestion
    Task {
      if let question, session.agent == .claudeCode,
        await daemon.answerQuestion(id: question.id, selections: selections)
      {
        JumpBack.log("answered \(question.id) via hook (\(selections.map { $0.map(String.init).joined(separator: "+") }.joined(separator: ",")))")
        store.firePulse(.approve)
        feedback(.approve)
        return
      }
      let single = selections.count == 1 && selections[0].count == 1 && question?.questions.first?.multiSelect != true
      if single, let script = TerminalInput.answerScript(option: selections[0][0]) {
        JumpBack.jump(to: session)
        guard Accessibility.isTrusted else {
          JumpBack.log("Accessibility not granted — jumped without typing the answer")
          return
        }
        Script.run(script)
      } else {
        JumpBack.jump(to: session)
      }
    }
  }

  /// Puts dropped files' paths into the agent's prompt, unsent, as a
  /// terminal drag would.
  func insertPaths(_ paths: [String], into session: SessionSnapshot) -> PromptResult {
    guard !paths.isEmpty else { return .empty }
    JumpBack.jump(to: session)
    guard Accessibility.isTrusted else {
      Accessibility.requestOnce()
      return .noAccessibility
    }
    let text = terminalPaths(paths) + " "
    Task {
      // Let the terminal come forward first.
      try? await Task.sleep(for: .milliseconds(350))
      Script.run(TerminalInput.insertScript(text))
    }
    return .sent
  }

  /// Types a one-line prompt into the session's terminal, or into Cursor's
  /// Composer for Cursor's own agent.
  func sendPrompt(_ text: String, to session: SessionSnapshot) -> PromptResult {
    let prompt = TerminalInput.flatten(text)
    guard !prompt.isEmpty else { return .empty }
    JumpBack.log("send-prompt (\(prompt.count) chars) for \(session.key)")
    JumpBack.jump(to: session)
    guard Accessibility.isTrusted else {
      JumpBack.log("Accessibility not granted — jumped without typing the prompt")
      Accessibility.requestOnce()
      return .noAccessibility
    }
    if session.agent == .cursor {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(prompt, forType: .string)
      Script.run(TerminalInput.cursorComposerScript)
    } else {
      Script.run(TerminalInput.typeScript(prompt))
    }
    return .sent
  }
}

/// The Accessibility grant, which typing into another app needs.
enum Accessibility {
  static var isTrusted: Bool { AXIsProcessTrusted() }

  private static let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
  private static var prompted = false

  /// Once per run, so a blocked send guides rather than nags.
  static func requestOnce() {
    guard !prompted else { return }
    prompted = true
    request()
  }

  /// Asks for the grant, clearing a stale entry first. An ad-hoc build gets a
  /// new signature each update, and macOS keeps showing the old grant as on
  /// while it no longer applies; dropping our row lets the prompt register
  /// this binary.
  static func request() {
    guard !isTrusted else {
      NSWorkspace.shared.open(pane)
      return
    }
    guard let bundleId = Bundle.main.bundleIdentifier else {
      prompt()
      return
    }
    let reset = Process()
    reset.executableURL = URL(filePath: "/usr/bin/tccutil")
    reset.arguments = ["reset", "Accessibility", bundleId]
    reset.terminationHandler = { _ in Task { @MainActor in prompt() } }
    do { try reset.run() } catch { prompt() }
  }

  private static func prompt() {
    let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
    NSWorkspace.shared.open(pane)
  }
}

/// AppleScript through `osascript`, off the main thread.
enum Script {
  static func run(_ source: String) {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    process.terminationHandler = { finished in
      let status = finished.terminationStatus
      Task { @MainActor in JumpBack.log(status == 0 ? "keystrokes sent" : "osascript exited \(status)") }
    }
    do { try process.run() } catch { JumpBack.log("osascript failed: \(error.localizedDescription)") }
  }
}

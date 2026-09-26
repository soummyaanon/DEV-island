import Foundation
import IslandCore
import Testing

// Ported from 1.x's assistant-context tests.

@Suite struct AssistantContextTests {
  let now = Date(timeIntervalSince1970: 1_790_000_000)

  private func session(_ project: String, _ state: SessionState = .working, title: String = "Editing  index.ts", minutesAgo: Double = 3) -> SessionSnapshot {
    SessionSnapshot(key: project, agent: .claudeCode, sessionId: project, cwd: "/Users/me/\(project)", state: state, title: title, startedAt: now, updatedAt: now.addingTimeInterval(-minutesAgo * 60))
  }

  @Test func `says one line per session, nothing when there are none`() {
    #expect(AssistantContext.text([], now: now) == "")
    #expect(AssistantContext.text([session("web")], now: now) == #"- web (Claude Code): working, "Editing index.ts", updated 3 min ago"#)
    #expect(AssistantContext.text([session("api", .waitingForApproval, minutesAgo: 0)], now: now).hasSuffix("waiting for your approval, \"Editing index.ts\", updated just now"))
  }

  @Test func `keeps to eight sessions`() {
    let many = (0..<12).map { session("p\($0)") }
    #expect(AssistantContext.text(many, now: now).split(separator: "\n").count == 8)
  }

  @Test func `finds a session by exact project, then prefix`() {
    let sessions = [session("website"), session("web")]
    #expect(AssistantContext.session(named: "Web", in: sessions)?.projectName == "web")
    #expect(AssistantContext.session(named: "webs", in: sessions)?.projectName == "website")
    #expect(AssistantContext.session(named: " ", in: sessions) == nil)
  }

  @Test func `the orb says what the assistant is doing`() {
    #expect(AssistantContext.orb(.init(tool: "searchWeb")) == .searching)
    #expect(AssistantContext.orb(.init(tool: "openApp")) == .working)
    #expect(AssistantContext.orb(.init(streaming: true)) == .composing)
    #expect(AssistantContext.orb(.init(sent: true)) == .connecting)
    #expect(AssistantContext.orb(.init(sent: true, settled: true)) == .solving)
    #expect(AssistantContext.orb(.init(proposing: true)) == .shaping)
    #expect(AssistantContext.orb(.init()) == .listening)
  }

  @Test func `opens only web links`() {
    #expect(AssistantContext.isWebURL("https://apple.com/x"))
    #expect(!AssistantContext.isWebURL("file:///etc/passwd"))
    #expect(!AssistantContext.isWebURL("javascript:alert(1)"))
  }
}

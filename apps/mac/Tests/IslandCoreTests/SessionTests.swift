import CoreGraphics
import Foundation
import IslandCore
import Testing

// Ported from 1.x's agent-avatar, wing-priority, WorkCrew, IdleCrew,
// SessionRow, StatusFooter, a11y and jump-back tests, plus the wire format.

private func date(_ iso: String) -> Date {
  try! Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(iso)
}

private func session(
  key: String = "claude-code:s1", agent: AgentKind = .claudeCode, cwd: String = "/Users/me/web",
  state: SessionState = .working, title: String = "Editing index.ts",
  started: String = "2026-09-23T11:00:00.000Z", updated: String = "2026-09-23T11:59:00.000Z",
  meta: [String: JSONValue] = [:], question: Bool = false, requiresAction: Bool = false
) -> SessionSnapshot {
  SessionSnapshot(
    key: key, agent: agent, sessionId: String(key.split(separator: ":").last ?? ""), cwd: cwd, state: state,
    title: title, requiresAction: requiresAction, startedAt: date(started), updatedAt: date(updated), meta: meta,
    pendingQuestion: question
      ? PendingQuestion(id: "q1", questions: [.init(question: "Deploy where?", options: ["Prod", "Staging"])], createdAt: date(updated))
      : nil
  )
}

private let now = date("2026-09-23T12:00:00.000Z")

@Suite struct AvatarStateTests {
  @Test func `hops while working or starting`() {
    #expect(session(state: .working).avatarState(now: now) == .working)
    #expect(session(state: .starting).avatarState(now: now) == .working)
  }

  @Test func `stays awake while it needs you, however long it's been`() {
    let old = now.addingTimeInterval(-SessionSnapshot.sleepAfter * 3)
    var s = session(state: .waitingForApproval)
    s.updatedAt = old
    #expect(s.avatarState(now: now) == .idle)
  }

  @Test func `falls asleep once a finished session has been quiet a while`() {
    #expect(session(state: .done).avatarState(now: now) == .idle)
    for state in [SessionState.done, .idle] {
      var s = session(state: state)
      s.updatedAt = now.addingTimeInterval(-SessionSnapshot.sleepAfter - 1)
      #expect(s.avatarState(now: now) == .sleeping)
    }
  }
}

@Suite struct OrbStateTests {
  @Test(arguments: [
    ("Searching for useEffect", OrbState.searching), ("Grep TODO", .searching), ("Editing index.ts", .composing),
    ("Reading package.json", .searching), ("Running pnpm test", .working), ("Thinking", .solving),
    ("Planning the migration", .weaving),
  ])
  func `reads the activity line`(title: String, orb: OrbState) {
    #expect(session(title: title).orbState == orb)
  }

  @Test func `lets the lifecycle win over the text`() {
    #expect(session(state: .starting, title: "Editing").orbState == .connecting)
    #expect(session(state: .waitingForApproval, title: "Run command").orbState == .listening)
  }

  @Test func `works, never breathing, when nothing matches`() {
    #expect(session(title: "…").orbState == .working)
  }
}

@Suite struct SeedTests {
  @Test func `is stable, in 0 to 1, and differs per session`() {
    let a = SessionSnapshot.seed("claude-code:s1")
    #expect(a == SessionSnapshot.seed("claude-code:s1"))
    #expect((0...1).contains(a))
    #expect(SessionSnapshot.seed("claude-code:s2") != a)
  }
}

@Suite struct WingContentTests {
  typealias I = WingContent.Inputs

  @Test func `attention beats everything`() {
    #expect(WingContent(I(needsYou: 1, active: 2, activity: true, lowBattery: true, weather: true)) == .attention)
  }

  @Test func `an agent's moment beats other agents working, but not attention`() {
    #expect(WingContent(I(active: 2, moment: true, activity: true)) == .moment)
    #expect(WingContent(I(needsYou: 1, moment: true)) == .attention)
  }

  @Test func `working agents beat ambience and live activities`() {
    #expect(WingContent(I(active: 1, activity: true, lowBattery: true, weather: true)) == .working)
  }

  @Test func `the charger beats working agents, but not attention or a moment`() {
    #expect(WingContent(I(active: 2, activity: true, powerMoment: true)) == .activity)
    #expect(WingContent(I(needsYou: 1, activity: true, powerMoment: true)) == .attention)
    #expect(WingContent(I(moment: true, activity: true, powerMoment: true)) == .moment)
  }

  @Test func `then activity, low battery, weather, empty`() {
    #expect(WingContent(I(activity: true, lowBattery: true, weather: true)) == .activity)
    #expect(WingContent(I(lowBattery: true, weather: true)) == .lowBattery)
    #expect(WingContent(I(weather: true)) == .weather)
    #expect(WingContent(I()) == .empty)
  }
}

@Suite struct CrewTests {
  @Test func `draws one bot per working session, folding past three into +n`() {
    let two = WorkCrew(["a", "b"])
    #expect(two.shown == ["a", "b"] && two.more == 0)
    let five = WorkCrew(["a", "b", "c", "d", "e"])
    #expect(five.shown.count == 3 && five.more == 2)
  }

  @Test func `code review: write, toss, review, toss, approve, cheer, every round`() {
    let writing = CodeReview(at: 1.2)
    #expect(writing.typing && writing.code == 1 && writing.commit == nil && writing.leans == [0, -7, -7])
    let tossed = CodeReview(at: 2.7)
    #expect(!tossed.typing && tossed.commit!.at > 0 && tossed.commit!.at < 1 && tossed.commit!.lift > 0.9)
    let review = CodeReview(at: 4)
    #expect(review.reviewing && review.commit!.at == 1 && review.commit!.lift == 0 && review.leans[0] == 7 && review.leans[2] == -7)
    let approved = CodeReview(at: 7)
    #expect(approved.approved == 1 && approved.commit == nil && approved.leans == [0, 0, 0])
    #expect(CodeReview(at: 6.3 + 0.225).hops[0] == 1 && CodeReview(at: 6.3 + 0.225).hops[2] > 0)
    #expect(CodeReview(at: 9.5) == CodeReview())
    #expect(CodeReview(at: CodeReview.round + 4) == CodeReview(at: 4))
  }

  @Test func `one orb per running agent kind, amber when one waits on you`() {
    let active = [
      session(key: "codex:a", agent: .codex, title: "Running tests"),
      session(key: "claude-code:b", state: .working),
      session(key: "claude-code:c", state: .waitingForApproval),
    ]
    #expect(WingOrb.shown(active: active) == [
      WingOrb(agent: .claudeCode, state: .listening, waiting: true),
      WingOrb(agent: .codex, state: .working, waiting: false),
    ])
  }
}

@Suite struct RowTests {
  let row = session(
    cwd: "/Users/me/project", state: .waitingForApproval,
    started: "2026-07-19T10:00:00.000Z", updated: "2026-07-19T10:00:01.000Z",
    meta: [
      "model": .string("claude-opus-4-6"), "permission_mode": .string("plan"),
      "app_bundle_id": .string("com.todesktop.230313mzl4w4u92"),
    ]
  )

  @Test func `shows the live model, host app and permission mode`() {
    #expect(row.contextLine == "claude · cursor · claude-opus-4-6 · plan")
  }

  @Test func `carries a spoken label with project, state, activity and elapsed`() {
    #expect(row.spokenDescription(now: date("2026-07-19T10:00:05.000Z")) == "project, waiting for you, Editing index.ts, 5s")
  }

  @Test func `formats elapsed time and memory`() {
    #expect(row.elapsed(now: date("2026-07-19T10:12:00.000Z")) == "12m")
    #expect(row.elapsed(now: date("2026-07-19T11:04:30.000Z")) == "1h 4m")
    #expect(Format.memory(megabytes: 1229) == "1.2 GB")
    #expect(Format.memory(megabytes: 200) == "200 MB")
  }

  @Test func `sorts attention first, then activity, then recency`() {
    let list = SessionList.sorted([
      session(key: "a", state: .done, updated: "2026-09-23T11:59:00.000Z"),
      session(key: "b", state: .working, updated: "2026-09-23T11:00:00.000Z"),
      session(key: "c", state: .working, updated: "2026-09-23T11:30:00.000Z"),
      session(key: "d", state: .waitingForApproval),
    ])
    #expect(list.map(\.key) == ["d", "c", "b", "a"])
  }
}

@Suite struct TransitionTests {
  @Test func `the first snapshot is only a baseline, and brand-new sessions are silent`() {
    let marks = SessionMarks([])
    #expect(marks.transitions(to: [session(state: .done)]).isEmpty)
  }

  @Test func `done and failed win the glow over needs-you cues`() {
    let marks = SessionMarks([session(state: .working)])
    let done = marks.transitions(to: [session(state: .done, requiresAction: true)])
    #expect(done.first?.kinds == [.done, .attention])
    #expect(done.first?.primary == .done)
    #expect(marks.transitions(to: [session(state: .working, question: true)]).first?.primary == .question)
    #expect(marks.transitions(to: [session(state: .working)]).isEmpty)
  }

  @Test func `says one sentence per update`() {
    let marks = SessionMarks([session(key: "a"), session(key: "b", cwd: "/x/api")])
    let one = marks.transitions(to: [session(key: "a"), session(key: "b", cwd: "/x/api", state: .failed)])
    #expect(SessionMarks.summary(one)! == ("api failed", false))
    let two = marks.transitions(to: [session(key: "a", state: .done), session(key: "b", cwd: "/x/api", question: true)])
    #expect(SessionMarks.summary(two)! == ("1 session is asking a question, 1 session finished", true))
  }
}

@Suite struct FooterTests {
  @Test func `reads minutes, hours and days until a reset`() {
    let at = { (minutes: Double) in now.timeIntervalSince1970 + minutes * 60 }
    #expect(Format.resetIn(at(12), now: now) == "12m")
    #expect(Format.resetIn(at(130), now: now) == "2h 10m")
    #expect(Format.resetIn(at(60 * 24 * 3 + 240), now: now) == "3d 4h")
    #expect(Format.resetIn(at(-5), now: now) == "0m")
  }

  @Test func `shows the 5-hour window before the weekly one`() {
    let usage = AgentUsage(
      agent: .claudeCode,
      windows: [UsageWindow(label: "weekly", usedPercent: 18.4), UsageWindow(label: "5h", usedPercent: 42)],
      updatedAt: now
    )
    let quota = QuotaSummary.from([usage], now: now)[0]
    #expect(quota.windows.map(\.short) == ["5h", "wk"])
    #expect(quota.windows.map(\.used) == [42, 18])
    #expect(quota.windows[0].detail == "claude 5-hour limit: 42% used · as of just now")
  }
}

@Suite struct JumpTargetTests {
  let cursor = JumpTarget.cursorBundleId

  @Test func `opens the project's own window for a session hosted in Cursor`() {
    let hosted = session(cwd: "/Users/me/DEV island", meta: ["app_bundle_id": .string(cursor)])
    #expect(JumpTarget(hosted) == .editorWindow(bundleId: cursor, cwd: "/Users/me/DEV island"))
  }

  @Test func `opens the project in Cursor for Cursor's own agent`() {
    let own = session(agent: .cursor, cwd: "/Users/me/Apex-HealthIQ")
    #expect(JumpTarget(own) == .editorWindow(bundleId: cursor, cwd: "/Users/me/Apex-HealthIQ"))
  }

  @Test func `finds the exact iTerm2 session`() {
    let iterm = session(meta: ["term_program": .string("iTerm.app"), "iterm_session_id": .string("w0t1p0:ABC-123")])
    #expect(JumpTarget(iterm) == .iTerm(sessionId: "ABC-123"))
  }

  @Test func `brings other terminals forward, by bundle id or by name`() {
    #expect(JumpTarget(session(meta: ["term_program": .string("Apple_Terminal")])) == .app(bundleId: "com.apple.Terminal"))
    #expect(JumpTarget(session(meta: ["term_program": .string("Hyper")])) == .appNamed("Hyper"))
    #expect(JumpTarget(session(meta: ["term_program": .string("rm -rf")])) == .none)
  }

  @Test func `picks VS Code or Cursor for a vscode terminal by what's running`() {
    let code = session(cwd: "/Users/me/project", meta: ["term_program": .string("vscode")])
    #expect(JumpTarget(code) == .vsCodeFamily(cwd: "/Users/me/project"))
    #expect(JumpTarget.vsCodeFamilyBundle(vsCodeRunning: false, cursorRunning: true) == cursor)
    #expect(JumpTarget.vsCodeFamilyBundle(vsCodeRunning: true, cursorRunning: true) == JumpTarget.vsCodeBundleId)
    #expect(JumpTarget.vsCodeFamilyBundle(vsCodeRunning: false, cursorRunning: false) == JumpTarget.vsCodeBundleId)
  }
}

@Suite struct WireTests {
  @Test func `decodes a snapshot the way the daemon sends it`() throws {
    let json = #"""
    {"type":"snapshot","sessions":[{"key":"claude-code:s1","agent":"claude-code","session_id":"s1",
    "cwd":"/Users/me/web","state":"waiting-for-approval","title":"Bash","requires_action":true,
    "started_at":"2026-09-23T11:00:00.000Z","updated_at":"2026-09-23T11:59:00Z",
    "last_event_type":"permission_request","event_count":3,"meta":{"model":"opus","n":2,"ok":true},
    "pending_approval":{"id":"a1","tool_name":"Bash","tool_input":{"command":"ls"},"created_at":"2026-09-23T11:59:00.000Z"},
    "pending_question":null}]}
    """#
    guard case let .snapshot(sessions) = try WireMessage(json: Data(json.utf8)) else {
      Issue.record("not a snapshot")
      return
    }
    let s = try #require(sessions.first)
    #expect(s.state == .waitingForApproval)
    #expect(s.metaString("model") == "opus")
    #expect(s.meta["n"] == .number(2))
    #expect(s.pendingApproval?.toolInput["command"] == .string("ls"))
    #expect(s.updatedAt == date("2026-09-23T11:59:00.000Z"))
  }

  @Test func `reads usage and pings, and shrugs at types it doesn't know`() throws {
    let usage = #"{"type":"usage","usage":[{"agent":"codex","plan":null,"windows":[{"label":"5h","used_percent":12.5,"resets_at":1790000000}],"credits":null,"updated_at":"2026-09-23T11:59:00.000Z"}]}"#
    guard case let .usage(entries) = try WireMessage(json: Data(usage.utf8)) else {
      Issue.record("not usage")
      return
    }
    #expect(entries.first?.windows.first?.resetsAt == 1_790_000_000)
    #expect(try WireMessage(json: Data(#"{"type":"ping","t":"2026-09-23T11:59:00.000Z"}"#.utf8)) == .ping)
    #expect(try WireMessage(json: Data(#"{"type":"future"}"#.utf8)) == .unknown("future"))
  }
}

@Suite struct SVGPathTests {
  @Test func `draws a circle from two arcs`() throws {
    let circle = try SVGPath.parse("M50 8A42 42 0 1 1 50 92A42 42 0 1 1 50 8Z").boundingBoxOfPath
    #expect(abs(circle.minX - 8) < 0.01 && abs(circle.maxX - 92) < 0.01)
    #expect(abs(circle.minY - 8) < 0.01 && abs(circle.maxY - 92) < 0.01)
  }

  @Test func `reads relative commands and compact numbers`() throws {
    let box = try SVGPath.parse("m10 10h5v5h-5z").boundingBoxOfPath
    #expect(box == CGRect(x: 10, y: 10, width: 5, height: 5))
    let packed = try SVGPath.parse("M0 0l.5.5-.25.25").currentPoint
    #expect(abs(packed.x - 0.25) < 1e-9 && abs(packed.y - 0.75) < 1e-9)
  }

  @Test(arguments: BotLook.Kind.allCases)
  func `parses every robot, inside its 100-unit box`(kind: BotLook.Kind) throws {
    let look = BotLook(kind)
    let box = try SVGPath.parse(look.outline).boundingBoxOfPath
    #expect(box.minX >= 0 && box.maxX <= 100 && box.minY >= 0 && box.maxY <= 100)
    if let parts = look.parts { _ = try SVGPath.parse(parts) }
  }

  @Test(arguments: AgentKind.allCases)
  func `parses every agent mark inside its view box`(agent: AgentKind) throws {
    let mark = AgentMark.path(agent)
    for data in mark.data {
      let box = try SVGPath.parse(data).boundingBoxOfPath
      #expect(box.minX >= -0.01 && box.maxX <= mark.box + 0.01 && box.maxY <= mark.box + 0.01)
    }
  }

  @Test func `rejects garbage`() {
    #expect(throws: SVGPath.ParseError.self) { try SVGPath.parse("hello") }
  }

  @Test func `picks dark ink for the bright bodies`() {
    #expect(BotLook.agent(.claudeCode).ink == 0x1E1A33)
    #expect(BotLook(.mech, color: 0x222222).ink == 0xF7F5F2)
  }
}

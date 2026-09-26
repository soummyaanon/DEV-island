import Foundation
import IslandCore
import Testing

// Ported from 1.x's daemon suites: session registry, Claude/Cursor/Codex
// mappers, usage, answers, and the rollout tail.

private let now = Date(timeIntervalSince1970: 1_790_000_000)

private func json(_ text: String) -> JSONValue { JSONValue(json: Data(text.utf8))! }

private func event(_ session: String = "s1", agent: AgentKind = .claudeCode, type: EventType = .toolUse, minutesAgo: Double = 1, pid: String? = nil) -> AgentEvent {
  var input = EventInput(agent: agent, sessionId: session, cwd: "/Users/me/web", type: type, title: "Editing")
  if let pid { input.addMeta(["pid": .string(pid)]) }
  return AgentEvent(input, id: "e", at: now.addingTimeInterval(-minutesAgo * 60))
}

@Suite struct RegistryTests {
  let stale: TimeInterval = 30 * 60

  @Test func `drops a Claude session whose process exited, keeps one that's alive`() {
    var r = SessionRegistry()
    r.apply(event("dead", pid: "111"))
    r.apply(event("live", pid: "222"))
    let pruned = r.prune(isAlive: { $0 == 222 }, now: now, stale: stale)
    #expect(pruned == ["claude-code:dead"])
    #expect(r.list.map(\.sessionId) == ["live"])
  }

  @Test func `a live process keeps even a long-quiet session`() {
    var r = SessionRegistry()
    r.apply(event(type: .sessionEnded, minutesAgo: 600, pid: "222"))
    let pruned = r.prune(isAlive: { _ in true }, now: now, stale: stale)
    #expect(pruned.isEmpty)
  }

  @Test func `without a process, drops finished sessions after the stale window, never working ones`() {
    var r = SessionRegistry()
    r.apply(event("old-done", type: .sessionEnded, minutesAgo: 45))
    r.apply(event("new-done", type: .sessionEnded, minutesAgo: 5))
    r.apply(event("old-working", type: .toolUse, minutesAgo: 45))
    let pruned = r.prune(isAlive: { _ in false }, now: now, stale: stale)
    #expect(pruned == ["claude-code:old-done"])
  }

  @Test func `never trusts a Cursor pid`() {
    var r = SessionRegistry()
    r.apply(event(agent: .cursor, minutesAgo: 2, pid: "333"))
    let pruned = r.prune(isAlive: { _ in false }, now: now, stale: stale)
    #expect(pruned.isEmpty)
  }

  @Test func `keeps a session holding an approval, and forgets on remove`() {
    var r = SessionRegistry()
    r.apply(event("held", pid: "111"))
    _ = r.setPendingApproval(.claudeCode, "held", PendingApproval(id: "a", toolName: "Bash", createdAt: now), at: now)
    let pruned = r.prune(isAlive: { _ in false }, now: now, stale: stale)
    #expect(pruned.isEmpty)
    let removed = r.remove("claude-code:held")
    #expect(removed)
    #expect(r.list.isEmpty)
  }

  @Test func `folds state, keeps metadata and the start time across events`() {
    var r = SessionRegistry()
    r.apply(event(type: .sessionStarted, minutesAgo: 10, pid: "5"))
    let s = r.apply(event(type: .permissionRequest))
    #expect(s.state == .waitingForApproval && s.eventCount == 2)
    #expect(s.meta["pid"] == .string("5"))
    #expect(s.startedAt == now.addingTimeInterval(-600))
    #expect(nextState(.notification, requiresAction: false) == .idle)
  }

  @Test func `encodes snapshots with explicit nulls, the way 1.x's UI reads them`() throws {
    var r = SessionRegistry()
    let s = r.apply(event())
    let text = String(decoding: WireMessage.snapshot([s]).encoded(), as: UTF8.self)
    #expect(text.contains(#""pending_approval":null"#) && text.contains(#""pending_question":null"#))
    #expect(text.contains(#""type":"snapshot""#))
    // …and our own client reads it back.
    guard case let .snapshot(decoded) = try WireMessage(json: Data(text.utf8)) else { Issue.record("not a snapshot"); return }
    #expect(decoded == [s])
  }
}

@Suite struct ClaudeAdapterTests {
  @Test func `surfaces AskUserQuestion permission events as questions, not approvals`() throws {
    let mapped = try #require(ClaudeAdapter.map("PermissionRequest", payload: json(#"{"session_id":"s","cwd":"/p","tool_name":"AskUserQuestion","tool_input":{"questions":[]}}"#), fallbackCwd: "x"))
    #expect(mapped.type == .notification && mapped.title == "Claude asks a question" && mapped.requiresAction)
  }

  @Test func `only a permission ask requires action among notifications`() {
    let untypedIdle = ClaudeAdapter.map("Notification", payload: json(#"{"session_id":"s","message":"Claude is waiting for your input"}"#), fallbackCwd: "/p")
    #expect(untypedIdle?.requiresAction == false && untypedIdle?.cwd == "/p")
    #expect(ClaudeAdapter.map("Notification", payload: json(#"{"session_id":"s","notification_type":"idle_prompt","message":"x"}"#), fallbackCwd: "/p")?.requiresAction == false)
    #expect(ClaudeAdapter.map("Notification", payload: json(#"{"session_id":"s","message":"Claude needs your permission to use Bash"}"#), fallbackCwd: "/p")?.requiresAction == true)
    #expect(ClaudeAdapter.map("Notification", payload: json(#"{"session_id":"s","notification_type":"permission_prompt","message":"x"}"#), fallbackCwd: "/p")?.requiresAction == true)
  }

  @Test func `persists the SessionStart model and permission mode as metadata`() throws {
    let mapped = try #require(ClaudeAdapter.map("SessionStart", payload: json(#"{"session_id":"s","cwd":"/p","source":"startup","model":"opus","permission_mode":"plan"}"#), fallbackCwd: "x"))
    #expect(mapped.type == .sessionStarted && mapped.title == "session startup")
    #expect(mapped.detail["_meta"] == .object(["model": .string("opus"), "permission_mode": .string("plan")]))
  }

  @Test func `describes tools like the rows show them`() {
    #expect(ClaudeAdapter.map("PreToolUse", payload: json(#"{"session_id":"s","cwd":"/p","tool_name":"Bash","tool_input":{"command":"pnpm test"}}"#), fallbackCwd: "")?.title == "Running pnpm test")
    #expect(ClaudeAdapter.map("PreToolUse", payload: json(#"{"session_id":"s","cwd":"/p","tool_name":"Edit","tool_input":{"file_path":"/a/b/index.ts"}}"#), fallbackCwd: "")?.title == "Editing index.ts")
    #expect(ClaudeAdapter.map("Stop", payload: json(#"{"session_id":"s","cwd":"/p"}"#), fallbackCwd: "")?.type == .sessionEnded)
    #expect(ClaudeAdapter.eventName(slug: "pre-tool", payload: json(#"{"session_id":"s"}"#)) == "PreToolUse")
  }

  @Test func `joins multi-select picks like Claude's picker and rejects bad picks`() {
    let multi = ClaudeAdapter.Answerable(question: "Q", labels: ["A", "B", "C"], multi: true)
    let single = ClaudeAdapter.Answerable(question: "Q", labels: ["A", "B"], multi: false)
    #expect(ClaudeAdapter.answerLabel(multi, picks: [2, 0, 2]) == "A, C")
    #expect(ClaudeAdapter.answerLabel(single, picks: [1]) == "B")
    #expect(ClaudeAdapter.answerLabel(single, picks: [0, 1]) == nil)
    #expect(ClaudeAdapter.answerLabel(single, picks: [5]) == nil)
    #expect(ClaudeAdapter.answerLabel(multi, picks: []) == nil)
  }

  @Test func `reads the card with descriptions, and the raw labels for the answer`() throws {
    let input = json(#"{"questions":[{"question":"Where?","options":[{"label":"Prod","description":"live"},{"label":"Staging"}],"multiSelect":true}]}"#)
    let card = try #require(ClaudeAdapter.question(from: input))
    #expect(card.questions[0].options == ["Prod — live", "Staging"] && card.questions[0].multiSelect == true)
    #expect(ClaudeAdapter.answerable(input) == [.init(question: "Where?", labels: ["Prod", "Staging"], multi: true)])
    #expect(ClaudeAdapter.answerable(json(#"{"questions":[{"question":"x","options":[]}]}"#)) == nil)
  }

  @Test func `accepts per-question selections and the legacy one-index form`() {
    #expect(parseSelections(json(#"{"selections":[[0,2],[1]]}"#)) == [[0, 2], [1]])
    #expect(parseSelections(json(#"{"options":[1,0]}"#)) == [[1], [0]])
    #expect(parseSelections(json(#"{"selections":[[]]}"#)) == nil)
    #expect(parseSelections(json(#"{"selections":[[-1]]}"#)) == nil)
    #expect(parseSelections(json(#"{}"#)) == nil)
  }

  @Test func `keeps only plausible bundle ids and pids from hook headers`() {
    let headers = ["x-app-bundle-id": "undleIdentifier", "x-agent-pid": "12a", "x-term-program": "$TERM_PROGRAM", "x-iterm-session-id": "w0t0p0:ABC"]
    #expect(ClaudeAdapter.terminalMeta { headers[$0] } == ["iterm_session_id": .string("w0t0p0:ABC")])
    let good = ["x-app-bundle-id": "com.googlecode.iterm2", "x-agent-pid": "4242", "x-term-program": "iTerm.app"]
    #expect(ClaudeAdapter.terminalMeta { good[$0] } == ["app_bundle_id": .string("com.googlecode.iterm2"), "pid": .string("4242"), "term_program": .string("iTerm.app")])
  }

  @Test func `reads Claude's limits and ages them out past their reset`() throws {
    let body = json(#"{"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1790003600},"seven_day":{"used_percentage":18,"resets_at":1789000000}}}"#)
    let usage = try #require(ClaudeAdapter.usage(from: body, now: now))
    #expect(usage.windows.map(\.label) == ["5h"])
    #expect(ClaudeAdapter.usage(from: json("{}"), now: now) == nil)
    #expect(ClaudeAdapter.fresh(usage, now: now.addingTimeInterval(7200)) == nil)
  }
}

@Suite struct CursorAdapterTests {
  @Test func `keys on conversation_id, takes cwd from workspace_roots, falls back`() throws {
    let a = try #require(CursorAdapter.map("preToolUse", payload: json(#"{"conversation_id":"c1","workspace_roots":["/w"],"tool_name":"Shell","tool_input":"{\"command\":\"ls\"}"}"#), fallbackCwd: "x"))
    #expect(a.sessionId == "c1" && a.cwd == "/w" && a.title == "Running ls")
    #expect(a.detail["_meta"]?["app_bundle_id"] == .string("com.todesktop.230313mzl4w4u92"))
    let b = CursorAdapter.map("stop", payload: json(#"{"generation_id":"g","cwd":"/c","status":"aborted"}"#), fallbackCwd: "x")
    #expect(b?.sessionId == "g" && b?.cwd == "/c" && b?.title == "aborted" && b?.type == .sessionEnded)
    #expect(CursorAdapter.map("stop", payload: json("{}"), fallbackCwd: "x") == nil)
  }

  @Test func `maps failures, subagents, compaction and unknowns`() {
    #expect(CursorAdapter.map("postToolUseFailure", payload: json(#"{"conversation_id":"c","is_interrupt":true}"#), fallbackCwd: "/")?.title == "interrupted")
    #expect(CursorAdapter.map("postToolUseFailure", payload: json(#"{"conversation_id":"c","error_message":"boom"}"#), fallbackCwd: "/")?.type == .error)
    #expect(CursorAdapter.map("subagentStop", payload: json(#"{"conversation_id":"c","status":"error","summary":"no"}"#), fallbackCwd: "/")?.type == .error)
    #expect(CursorAdapter.map("preCompact", payload: json(#"{"conversation_id":"c","context_usage_percent":81.6}"#), fallbackCwd: "/")?.title == "compacting context (82%)")
    #expect(CursorAdapter.map("sessionStart", payload: json(#"{"session_id":"c","composer_mode":"agent","model":"gpt"}"#), fallbackCwd: "/")?.detail["_meta"]?["permission_mode"] == .string("agent"))
    #expect(CursorAdapter.map("somethingNew", payload: json(#"{"conversation_id":"c"}"#), fallbackCwd: "/") == nil)
  }
}

@Suite struct CodexAdapterTests {
  @Test func `learns identity from session_meta and turn_context`() throws {
    var ctx = CodexAdapter.Context()
    let early = CodexAdapter.map(json(#"{"type":"event_msg","payload":{"type":"task_started"}}"#), &ctx)
    #expect(early == nil)
    let started = try #require(CodexAdapter.map(json(#"{"type":"session_meta","payload":{"id":"abc","cwd":"/p"}}"#), &ctx))
    #expect(started.sessionId == "abc" && started.cwd == "/p" && started.type == .sessionStarted)
    let turn = CodexAdapter.map(json(#"{"type":"turn_context","payload":{"cwd":"/q","model":"gpt-5","approval_policy":"on-request"}}"#), &ctx)
    #expect(turn == nil)
    let working = try #require(CodexAdapter.map(json(#"{"type":"event_msg","payload":{"type":"task_started"}}"#), &ctx))
    #expect(working.cwd == "/q" && working.detail["_meta"] == .object(["model": .string("gpt-5"), "permission_mode": .string("on-request")]))
  }

  @Test func `titles tool activity like Claude's`() {
    var ctx = CodexAdapter.Context(fallbackSessionId: "s")
    let title = { (text: String) in CodexAdapter.map(json(text), &ctx)?.title }
    #expect(title(#"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"ls -la\"}"}}"#) == "Running ls -la")
    #expect(title(#"{"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"*** Update File: src/a.ts\n"}}"#) == "Editing a.ts")
    #expect(title(#"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.exec_command({\"cmd\":\"pnpm build\"})"}}"#) == "Running pnpm build")
    #expect(title(#"{"type":"event_msg","payload":{"type":"exec_command_end","parsed_cmd":[{"type":"read","name":"a.ts"}]}}"#) == "Reading a.ts")
    #expect(title(#"{"type":"event_msg","payload":{"type":"patch_apply_end","changes":{"a":{},"b":{}}}}"#) == "Edited 2 files")
    #expect(title(#"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"did it"}}"#) == "did it")
    let noise = CodexAdapter.map(json(#"{"type":"event_msg","payload":{"type":"token_count"}}"#), &ctx)
    #expect(noise == nil)
    let asks = CodexAdapter.map(json(#"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{}"}}"#), &ctx)
    #expect(asks?.requiresAction == true)
  }

  @Test func `extracts the question request_user_input waits on`() {
    let entry = json(#"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{\"questions\":[{\"question\":\"Which?\",\"options\":[{\"label\":\"A\"}]}]}"}}"#)
    #expect(CodexAdapter.question(entry)?.questions == [.init(question: "Which?", options: ["A"])])
    #expect(CodexAdapter.question(json(#"{"type":"response_item","payload":{"type":"function_call","name":"x"}}"#)) == nil)
  }

  @Test func `picks a pid only when it can be sure`() {
    #expect(CodexAdapter.pickPid(lsof: "123\n", pgrep: "") == 123)
    #expect(CodexAdapter.pickPid(lsof: "", pgrep: "77\n") == 77)
    #expect(CodexAdapter.pickPid(lsof: "", pgrep: "1\n2\n") == nil)
    #expect(CodexAdapter.pickPid(lsof: "junk", pgrep: "") == nil)
  }

  @Test func `reads quota from the last token_count`() {
    let rollout = """
      {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":10,"window_minutes":300},"plan_type":"pro"}}}
      {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":20,"window_minutes":300,"resets_at":1790001000},"secondary":{"used_percent":5,"window_minutes":10080}}}}
      """
    let usage = CodexAdapter.usage(fromRollout: rollout, now: now)
    #expect(usage?.windows.map(\.label) == ["5h", "weekly"])
    #expect(usage?.windows.first?.usedPercent == 20)
  }

  @Test func `tails a file: compact catch-up, live appends, partial lines, questions`() {
    let uuid = "019f790e-889e-7370-a86b-b7e9b65e13e8"
    var tail = CodexAdapter.Tail(fileName: "rollout-2026-07-19T06-00-00-\(uuid).jsonl")
    let history = """
      {"type":"session_meta","payload":{"session_id":"\(uuid)","cwd":"/Users/me/proj"}}
      {"type":"event_msg","payload":{"type":"task_started"}}
      {"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\\"cmd\\":\\"ls -la\\"}"}}

      """
    let caught = tail.attach(Data(history.utf8))
    #expect(caught.map(\.type) == [.sessionStarted, .toolUse])
    #expect(caught.last?.cwd == "/Users/me/proj")
    let ask = #"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","arguments":"{\"questions\":[{\"question\":\"Which?\",\"options\":[{\"label\":\"A\"}]}]}"}}"# + "\n"
    let partial = #"{"type":"event_msg","payload":{"type":"task_comp"#
    let out = tail.append(Data((ask + partial).utf8))
    #expect(out.count == 2)
    guard case .question(_, let q?) = out.last else { Issue.record("no question"); return }
    #expect(q.questions.first?.question == "Which?")
    // The rest of the partial line arrives: it ingests and clears the question.
    let rest = #"lete","last_agent_message":"done"}}"# + "\n"
    let more = tail.append(Data((partial + rest).utf8))
    #expect(more == [.ingest(more.first.flatMap { if case let .ingest(e) = $0 { e } else { nil } }!), .question(sessionId: uuid, nil)])
  }
}

import Foundation
import IslandCore
import Testing

// 1.x's daemon fixtures, verbatim, for the cases DaemonTests.swift doesn't
// already check: both implementations answer to the same inputs.

private func json(_ text: String) -> JSONValue { JSONValue(json: Data(text.utf8))! }

/// A rollout entry the way the files store them.
private func entry(_ type: String, _ payload: [String: JSONValue]) -> JSONValue {
  .object(["timestamp": .string("2026-07-19T06:27:24.046Z"), "type": .string(type), "payload": .object(payload)])
}

/// The same entry as one JSONL line.
private func line(_ type: String, _ payload: [String: JSONValue]) -> String {
  let value: JSONValue = .object(["timestamp": .string("2026-07-19T06:00:00.000Z"), "type": .string(type), "payload": .object(payload)])
  return String(decoding: try! JSONEncoder().encode(value), as: UTF8.self) + "\n"
}

private let codexId = "019f790e-889e-7370-a86b-b7e9b65e13e8"

private let sessionMeta = entry("session_meta", [
  "session_id": .string(codexId), "cwd": .string("/Users/me/proj"), "originator": .string("codex-tui"),
  "cli_version": .string("0.144.6"), "source": .string("cli"),
])

private func codexContext() -> CodexAdapter.Context {
  var ctx = CodexAdapter.Context()
  _ = CodexAdapter.map(sessionMeta, &ctx)
  return ctx
}

@Suite struct ClaudeUsageParityTests {
  let now = Date(timeIntervalSince1970: 1_790_164_800)  // 2026-09-23T12:00:00Z
  var later: Double { 1_790_164_800 + 3600 }
  var earlier: Double { 1_790_164_800 - 60 }

  @Test func `reads the 5-hour and weekly windows from the status line JSON`() throws {
    let body = json(#"{"model":{"id":"claude-opus"},"rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":\#(Int(later))},"seven_day":{"used_percentage":18,"resets_at":\#(Int(later) + 86400)}}}"#)
    let usage = try #require(ClaudeAdapter.usage(from: body, now: now))
    #expect(usage.agent == .claudeCode)
    #expect(usage.windows == [
      UsageWindow(label: "5h", usedPercent: 42.5, resetsAt: later),
      UsageWindow(label: "weekly", usedPercent: 18, resetsAt: later + 86400),
    ])
  }

  @Test func `drops a window that already reset, and is null with nothing usable`() {
    let body = json(#"{"rate_limits":{"five_hour":{"used_percentage":90,"resets_at":\#(Int(earlier))},"seven_day":{"used_percentage":5,"resets_at":\#(Int(later))}}}"#)
    #expect(ClaudeAdapter.usage(from: body, now: now)?.windows.map(\.label) == ["weekly"])
    #expect(ClaudeAdapter.usage(from: json(#"{"model":{}}"#), now: now) == nil)
    #expect(ClaudeAdapter.usage(from: json(#"{"rate_limits":{"five_hour":{"used_percentage":"lots"}}}"#), now: now) == nil)
    #expect(ClaudeAdapter.usage(from: .null, now: now) == nil)
  }
}

@Suite struct CursorParityTests {
  let base = #""conversation_id":"conv-1","workspace_roots":["/Users/me/proj"]"#
  func map(_ event: String, _ extra: String = "", cwd: String = "x") -> EventInput? {
    CursorAdapter.map(event, payload: json("{\(base)\(extra.isEmpty ? "" : ",")\(extra)}"), fallbackCwd: cwd)
  }

  @Test func `prefers the payload's hook_event_name, falling back to the slug`() {
    #expect(CursorAdapter.eventName(slug: "stop", payload: json(#"{"hook_event_name":"afterFileEdit"}"#)) == "afterFileEdit")
    #expect(CursorAdapter.eventName(slug: "stop", payload: json("{}")) == "stop")
  }

  @Test func `keys the session on conversation_id and takes cwd from workspace_roots`() throws {
    let mapped = try #require(map("beforeSubmitPrompt", cwd: "(unknown)"))
    #expect(mapped.agent == .cursor && mapped.sessionId == "conv-1" && mapped.cwd == "/Users/me/proj")
    #expect(mapped.type == .taskProgress && mapped.title == "working…")
    #expect(mapped.detail["_meta"]?["app_bundle_id"] == .string("com.todesktop.230313mzl4w4u92"))
  }

  @Test func `falls back to session_id then generation_id, and prefers payload.cwd`() {
    let a = CursorAdapter.map("sessionStart", payload: json(#"{"session_id":"sess-9","cwd":"/from/payload"}"#), fallbackCwd: "/known")
    #expect(a?.sessionId == "sess-9" && a?.cwd == "/from/payload" && a?.type == .sessionStarted)
    let b = CursorAdapter.map("stop", payload: json(#"{"generation_id":"gen-9"}"#), fallbackCwd: "/known/dir")
    #expect(b?.sessionId == "gen-9" && b?.cwd == "/known/dir")
  }

  @Test func `maps sessionStart with composer mode and model meta`() throws {
    let mapped = try #require(map("sessionStart", #""composer_mode":"agent","model":"claude-opus-4","is_background_agent":false"#))
    #expect(mapped.type == .sessionStarted && mapped.title == "session agent")
    #expect(mapped.detail["composer_mode"] == .string("agent"))
    let meta = mapped.detail["_meta"]
    #expect(meta?["model"] == .string("claude-opus-4"))
    #expect(meta?["permission_mode"] == .string("agent"))
    #expect(meta?["app_bundle_id"] == .string("com.todesktop.230313mzl4w4u92"))
  }

  @Test func `maps beforeSubmitPrompt to a truncated prompt title when present`() {
    let mapped = map("beforeSubmitPrompt", #""prompt":"fix the flaky test""#)
    #expect(mapped?.type == .taskProgress && mapped?.title == "fix the flaky test")
  }

  @Test func `maps preToolUse with Claude-like activity titles`() {
    let shell = map("preToolUse", #""tool_name":"Shell","tool_input":{"command":"pnpm test --run"}"#)
    #expect(shell?.type == .toolUse && shell?.title == "Running pnpm test --run")
    let grep = map("preToolUse", #""tool_name":"Grep","tool_input":{"pattern":"sessionKey"}"#)
    #expect(grep?.type == .toolUse && grep?.title == "Searching for sessionKey")
    let write = map("preToolUse", #""tool_name":"Write","tool_input":{"file_path":"/a/b/index.ts"}"#)
    #expect(write?.type == .toolUse && write?.title == "Editing index.ts")
    let task = map("preToolUse", #""tool_name":"Task","tool_input":{"description":"explore auth"}"#)
    #expect(task?.type == .toolUse && task?.title == "Delegating: explore auth")
  }

  @Test func `maps postToolUseFailure to error, or interrupted when cancelled`() {
    let failed = map("postToolUseFailure", #""tool_name":"Shell","error_message":"timed out","failure_type":"timeout""#)
    #expect(failed?.type == .error && failed?.title == "timed out")
    let interrupted = map("postToolUseFailure", #""is_interrupt":true,"failure_type":"error""#)
    #expect(interrupted?.type == .taskProgress && interrupted?.title == "interrupted")
  }

  @Test func `maps specialized tool hooks with friendly titles`() {
    let shell = map("beforeShellExecution", #""command":"pnpm test --run""#)
    #expect(shell?.type == .toolUse && shell?.title == "Running pnpm test --run")
    let read = map("beforeReadFile", #""file_path":"/a/b/notes.md""#)
    #expect(read?.type == .toolUse && read?.title == "Reading notes.md")
    let edit = map("afterFileEdit", #""file_path":"/a/b/index.ts""#)
    #expect(edit?.type == .toolUse && edit?.title == "Editing index.ts")
    let mcp = map("beforeMCPExecution", #""server_name":"linear","tool_name":"create_issue""#)
    #expect(mcp?.type == .toolUse && mcp?.title == "linear.create_issue")
  }

  @Test func `maps subagent lifecycle with task text and failure status`() {
    let start = map("subagentStart", #""task":"Explore the authentication flow","subagent_type":"explore""#)
    #expect(start?.type == .toolUse && start?.title == "Delegating: Explore the authentication flow")
    let failed = map("subagentStop", #""status":"error","summary":"could not find auth""#)
    #expect(failed?.type == .error && failed?.title == "could not find auth")
    let done = map("subagentStop", #""status":"completed","summary":"found 3 files""#)
    #expect(done?.type == .taskProgress && done?.title == "found 3 files")
  }

  @Test func `maps preCompact and lifecycle stop and sessionEnd`() {
    let compact = map("preCompact", #""context_usage_percent":85.4,"trigger":"auto""#)
    #expect(compact?.type == .taskProgress && compact?.title == "compacting context (85%)")
    #expect(map("afterAgentThought")?.title == "thinking…")
    #expect(map("afterShellExecution")?.type == .taskProgress)
    let stop = map("stop", #""status":"completed""#)
    #expect(stop?.type == .sessionEnded && stop?.title == "finished responding")
    let error = map("stop", #""status":"error""#)
    #expect(error?.type == .error && error?.title == "agent error")
    let closed = map("sessionEnd", #""reason":"user_close""#)
    #expect(closed?.type == .sessionEnded && closed?.title == "session closed")
  }
}

@Suite struct CodexMapperParityTests {
  @Test func `parses a JSONL line`() {
    #expect(CodexAdapter.parse(#"{"type":"event_msg","payload":{"type":"task_started"}}"#) == .object(["type": .string("event_msg"), "payload": .object(["type": .string("task_started")])]))
  }

  @Test func `returns null for malformed JSON, blanks, and non-objects`() {
    #expect(CodexAdapter.parse("{oops") == nil)
    #expect(CodexAdapter.parse("") == nil)
    #expect(CodexAdapter.parse("   ") == nil)
    #expect(CodexAdapter.parse(#""just a string""#) == nil)
    #expect(CodexAdapter.parse("42") == nil)
  }

  @Test func `maps session_meta to session_started and learns id and cwd`() throws {
    var ctx = CodexAdapter.Context()
    let mapped = try #require(CodexAdapter.map(sessionMeta, &ctx))
    #expect(mapped.agent == .codex && mapped.sessionId == codexId && mapped.cwd == "/Users/me/proj")
    #expect(mapped.type == .sessionStarted && mapped.title == "session started" && !mapped.requiresAction)
    #expect(ctx.sessionId == codexId && ctx.cwd == "/Users/me/proj")
  }

  @Test func `uses the filename-derived fallback session id until session_meta arrives`() {
    var ctx = CodexAdapter.Context(fallbackSessionId: "file-uuid")
    let mapped = CodexAdapter.map(entry("event_msg", ["type": .string("task_started")]), &ctx)
    #expect(mapped?.sessionId == "file-uuid" && mapped?.cwd == "(unknown)")
  }

  @Test func `task_started means working`() {
    var ctx = codexContext()
    let mapped = CodexAdapter.map(entry("event_msg", ["type": .string("task_started")]), &ctx)
    #expect(mapped?.type == .taskProgress && mapped?.title == "working…")
  }

  @Test func `task_complete becomes session_ended titled from last_agent_message, truncated`() throws {
    var ctx = codexContext()
    let long = String(repeating: "Implemented the whole feature. ", count: 10)
    let mapped = try #require(CodexAdapter.map(entry("event_msg", ["type": .string("task_complete"), "last_agent_message": .string(long)]), &ctx))
    #expect(mapped.type == .sessionEnded)
    #expect(mapped.title.count <= 64 && mapped.title.hasSuffix("…"))
  }

  @Test func `task_complete without a message falls back to a stock title`() {
    var ctx = codexContext()
    let mapped = CodexAdapter.map(entry("event_msg", ["type": .string("task_complete")]), &ctx)
    #expect(mapped?.title == "finished responding")
  }

  @Test func `turn_aborted maps to a non-attention notification`() {
    var ctx = codexContext()
    let mapped = CodexAdapter.map(entry("event_msg", ["type": .string("turn_aborted"), "reason": .string("interrupted")]), &ctx)
    #expect(mapped?.type == .notification && mapped?.title == "turn interrupted" && mapped?.requiresAction == false)
  }

  @Test func `error events map to error`() {
    var ctx = codexContext()
    let mapped = CodexAdapter.map(entry("event_msg", ["type": .string("error"), "message": .string("stream disconnected")]), &ctx)
    #expect(mapped?.type == .error && mapped?.title == "stream disconnected")
  }

  @Test func `apply_patch custom_tool_call names the first touched file`() {
    var ctx = codexContext()
    let mapped = CodexAdapter.map(entry("response_item", [
      "type": .string("custom_tool_call"), "name": .string("apply_patch"),
      "input": .string("*** Begin Patch\n*** Update File: src/deep/dir/thing.ts\n+x\n*** End Patch"),
    ]), &ctx)
    #expect(mapped?.type == .toolUse && mapped?.title == "Editing thing.ts")
  }

  @Test func `custom exec unwraps the cmd from the JS-harness wrapper`() {
    var ctx = codexContext()
    let mapped = CodexAdapter.map(entry("response_item", [
      "type": .string("custom_tool_call"), "name": .string("exec"),
      "input": .string(#"const r = await tools.exec_command({"cmd":"rg -n \"crab|codex\" .","workdir":"/x","yield_time_ms":1000})"#),
    ]), &ctx)
    #expect(mapped?.type == .toolUse && mapped?.title == #"Running rg -n "crab|codex" ."#)
  }

  @Test func `update_plan reads as planning`() {
    var ctx = codexContext()
    let mapped = CodexAdapter.map(entry("response_item", ["type": .string("function_call"), "name": .string("update_plan"), "arguments": .string("{}")]), &ctx)
    #expect(mapped?.type == .toolUse && mapped?.title == "Updating the plan")
  }

  @Test func `request_user_input is an attention notification`() {
    var ctx = codexContext()
    let mapped = CodexAdapter.map(entry("response_item", [
      "type": .string("function_call"), "name": .string("request_user_input"),
      "arguments": .string(#"{"questions":[{"question":"Which one?","options":[{"label":"A"}]}]}"#),
    ]), &ctx)
    #expect(mapped?.type == .notification && mapped?.title == "Codex asks a question" && mapped?.requiresAction == true)
  }

  @Test func `exec_command_end derives a friendly title from parsed_cmd`() throws {
    var ctx = codexContext()
    let read = try #require(CodexAdapter.map(entry("event_msg", [
      "type": .string("exec_command_end"),
      "parsed_cmd": .array([.object(["type": .string("read"), "name": .string("STATUS.md")])]),
      "stdout": .string(String(repeating: "x", count: 10_000)),
    ]), &ctx))
    #expect(read.type == .taskProgress && read.title == "Reading STATUS.md")
    // Big command output never rides along into detail.
    let size = try JSONEncoder().encode(read.detail).count
    #expect(size < 1_000)
    let search = CodexAdapter.map(entry("event_msg", ["type": .string("exec_command_end"), "parsed_cmd": .array([.object(["type": .string("search")])])]), &ctx)
    #expect(search?.title == "Searching")
    let unknown = CodexAdapter.map(entry("event_msg", ["type": .string("exec_command_end"), "parsed_cmd": .array([.object(["type": .string("unknown")])])]), &ctx)
    #expect(unknown?.title == "working…")
  }

  @Test func `mcp and web-search ends surface as progress`() {
    var ctx = codexContext()
    let mcp = CodexAdapter.map(entry("event_msg", [
      "type": .string("mcp_tool_call_end"), "invocation": .object(["server": .string("vaani"), "tool": .string("list_agents")]),
    ]), &ctx)
    #expect(mcp?.title == "vaani.list_agents")
    let web = CodexAdapter.map(entry("event_msg", ["type": .string("web_search_end"), "query": .string("x")]), &ctx)
    #expect(web?.title == "Searching the web")
  }

  @Test func `returns null for token_count, messages, reasoning, outputs and unknowns`() {
    var ctx = codexContext()
    let ignored: [JSONValue] = [
      entry("event_msg", ["type": .string("token_count"), "rate_limits": .object([:])]),
      entry("event_msg", ["type": .string("agent_message"), "message": .string("hi")]),
      entry("event_msg", ["type": .string("user_message"), "message": .string("yo")]),
      entry("response_item", ["type": .string("reasoning")]),
      entry("response_item", ["type": .string("message")]),
      entry("response_item", ["type": .string("function_call_output"), "call_id": .string("c1")]),
      entry("response_item", ["type": .string("custom_tool_call_output"), "call_id": .string("c2")]),
      entry("response_item", ["type": .string("function_call"), "name": .string("write_stdin"), "arguments": .string("{}")]),
      entry("world_state", [:]),
      entry("event_msg", ["type": .string("brand_new_thing")]),
      .object([:]),
    ]
    for e in ignored {
      let mapped = CodexAdapter.map(e, &ctx)
      #expect(mapped == nil)
    }
  }

  @Test func `parses questions and options from request_user_input arguments`() throws {
    let q = try #require(CodexAdapter.question(entry("response_item", [
      "type": .string("function_call"), "name": .string("request_user_input"),
      "arguments": .string(#"{"questions":[{"question":"Deploy now?","options":[{"label":"Yes"},{"label":"No"}]}]}"#),
    ])))
    #expect(q.questions == [.init(question: "Deploy now?", options: ["Yes", "No"])])
    #expect(!q.id.isEmpty)
  }

  @Test func `extracts no question from anything else or malformed arguments`() {
    #expect(CodexAdapter.question(entry("event_msg", ["type": .string("task_started")])) == nil)
    #expect(CodexAdapter.question(entry("response_item", ["type": .string("function_call"), "name": .string("request_user_input"), "arguments": .string("{nope")])) == nil)
    #expect(CodexAdapter.question(entry("response_item", ["type": .string("function_call"), "name": .string("request_user_input"), "arguments": .string("{}")])) == nil)
  }

  @Test func `prefers whoever holds the rollout file open, and ignores junk`() {
    #expect(CodexAdapter.pickPid(lsof: "4242\n", pgrep: "1\n2\n") == 4242)
    #expect(CodexAdapter.pickPid(lsof: "", pgrep: "777\n") == 777)
    #expect(CodexAdapter.pickPid(lsof: "", pgrep: "777\n778\n") == nil)
    #expect(CodexAdapter.pickPid(lsof: "lsof: WARNING\n", pgrep: "not-a-pid") == nil)
  }
}

/// 1.x's CodexRolloutReader cases that are about the bytes, not the watcher.
@Suite struct RolloutTailParityTests {
  let fileName = "rollout-2026-07-19T06-00-00-\(codexId).jsonl"
  let meta = line("session_meta", ["session_id": .string(codexId), "cwd": .string("/Users/me/proj")])
  let started = line("event_msg", ["type": .string("task_started")])
  let complete = line("event_msg", ["type": .string("task_complete"), "last_agent_message": .string("did it")])
  let exec = line("response_item", ["type": .string("function_call"), "name": .string("exec_command"), "arguments": .string(#"{"cmd":"ls -la"}"#)])

  private func ingested(_ out: [CodexAdapter.Tail.Output]) -> [EventInput] {
    out.compactMap { if case let .ingest(e) = $0 { e } else { nil } }
  }

  @Test func `catch-up compacts an existing file to session_started and latest state`() {
    var tail = CodexAdapter.Tail(fileName: fileName)
    let events = tail.attach(Data((meta + started + exec + complete).utf8))
    #expect(events.count == 2)
    #expect(events.first?.type == .sessionStarted && events.first?.sessionId == codexId && events.first?.cwd == "/Users/me/proj")
    #expect(events.last?.type == .sessionEnded && events.last?.title == "did it")
  }

  @Test func `streams appended lines live`() {
    var tail = CodexAdapter.Tail(fileName: fileName)
    let first = tail.attach(Data(meta.utf8))
    #expect(first.count == 1)
    let events = ingested(tail.append(Data((started + exec).utf8)))
    #expect(events.map(\.type) == [.taskProgress, .toolUse])
    #expect(events.map(\.title) == ["working…", "Running ls -la"])
  }

  @Test func `buffers a partial line until its newline arrives`() {
    var tail = CodexAdapter.Tail(fileName: fileName)
    _ = tail.attach(Data(meta.utf8))
    let head = String(started.prefix(25))
    let none = tail.append(Data(head.utf8))
    #expect(none.isEmpty)  // half a line is not an event
    // The reader re-reads from `offset`, so the head arrives again with the tail.
    let events = ingested(tail.append(Data(started.utf8)))
    #expect(events.count == 1 && events.first?.type == .taskProgress && events.first?.title == "working…")
  }

  @Test func `skips malformed lines without dying`() {
    var tail = CodexAdapter.Tail(fileName: fileName)
    _ = tail.attach(Data(meta.utf8))
    let events = ingested(tail.append(Data(("{not json at all\n" + started).utf8)))
    #expect(events.map(\.type) == [.taskProgress])
  }

  @Test func `falls back to the filename uuid when a file has no session_meta yet`() {
    var tail = CodexAdapter.Tail(fileName: fileName)
    let events = tail.attach(Data(started.utf8))
    #expect(events.count == 1 && events.first?.sessionId == codexId && events.first?.cwd == "(unknown)")
  }
}

/// routes-claude's pure parts: what the hook route builds its state and
/// answers from. The route itself lives in the app target.
@Suite struct ClaudeRouteParityTests {
  let deploy = json(#"{"questions":[{"question":"Deploy where?","options":[{"label":"Production","description":"Deploy the current release"},{"label":"Staging","description":"Run a final smoke test"}]}]}"#)

  @Test func `turns an AskUserQuestion permission request into selectable question state`() throws {
    let payload: JSONValue = .object([
      "session_id": .string("session-1"), "cwd": .string("/Users/me/project"), "hook_event_name": .string("PermissionRequest"),
      "tool_name": .string("AskUserQuestion"), "tool_input": deploy,
    ])
    let mapped = try #require(ClaudeAdapter.map("PermissionRequest", payload: payload, fallbackCwd: "(unknown)"))
    // A question, not an approval.
    #expect(mapped.type == .notification)
    let card = try #require(ClaudeAdapter.question(from: deploy))
    #expect(card.questions.map(\.question) == ["Deploy where?"])
    #expect(card.questions.first?.options == ["Production — Deploy the current release", "Staging — Run a final smoke test"])
  }

  @Test func `answers a held AskUserQuestion with the raw label of the pick`() throws {
    let answerable = try #require(ClaudeAdapter.answerable(deploy))
    let picks = try #require(parseSelections(json(#"{"options":[1]}"#)))
    #expect(picks == [[1]])
    #expect(answerable.map(\.question) == ["Deploy where?"])
    #expect(ClaudeAdapter.answerLabel(answerable[0], picks: picks[0]) == "Staging")
  }

  @Test func `answers every question of a multi-question ask`() throws {
    let input = json(#"{"questions":[{"question":"Deploy where?","options":[{"label":"Production"},{"label":"Staging"}]},{"question":"Notify the team?","options":[{"label":"Yes"},{"label":"No"}]}]}"#)
    #expect(ClaudeAdapter.question(from: input)?.questions.count == 2)
    let answerable = try #require(ClaudeAdapter.answerable(input))
    let picks = try #require(parseSelections(json(#"{"options":[0,1]}"#)))
    let answers = zip(answerable, picks).map { ($0.question, ClaudeAdapter.answerLabel($0, picks: $1)) }
    #expect(answers.map(\.0) == ["Deploy where?", "Notify the team?"])
    #expect(answers.map(\.1) == ["Production", "No"])
  }

  @Test func `maps the question's lifecycle hooks: asked, notified while waiting, answered`() {
    let ask = ClaudeAdapter.map("PreToolUse", payload: json(#"{"session_id":"session-1","cwd":"/Users/me/project","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Deploy where?","options":[{"label":"Production"}]}]}}"#), fallbackCwd: "x")
    #expect(ask?.type == .notification && ask?.title == "Claude asks a question" && ask?.requiresAction == true)
    let waiting = ClaudeAdapter.map("Notification", payload: json(#"{"session_id":"session-1","cwd":"/Users/me/project","message":"Claude is waiting for your input"}"#), fallbackCwd: "x")
    #expect(waiting?.type == .notification && waiting?.requiresAction == false)
    let answered = ClaudeAdapter.map("PostToolUse", payload: json(#"{"session_id":"session-1","cwd":"/Users/me/project","tool_name":"AskUserQuestion"}"#), fallbackCwd: "x")
    #expect(answered?.type == .taskProgress)
  }

  @Test func `stores only plausible app bundle ids and pids from hook headers`() {
    #expect(ClaudeAdapter.terminalMeta { $0 == "x-app-bundle-id" ? "undleIdentifier" : nil }["app_bundle_id"] == nil)
    #expect(ClaudeAdapter.terminalMeta { $0 == "x-app-bundle-id" ? "com.todesktop.230313mzl4w4u92" : nil }["app_bundle_id"] == .string("com.todesktop.230313mzl4w4u92"))
    #expect(ClaudeAdapter.terminalMeta { $0 == "x-agent-pid" ? "not-a-pid" : nil }["pid"] == nil)
    #expect(ClaudeAdapter.terminalMeta { $0 == "x-agent-pid" ? "48213" : nil }["pid"] == .string("48213"))
  }

  @Test func `joins multi-select picks like Claude's picker and rejects bad picks`() {
    let multi = ClaudeAdapter.Answerable(question: "Q", labels: ["Lint", "Types", "Tests"], multi: true)
    #expect(ClaudeAdapter.answerLabel(multi, picks: [2, 0]) == "Lint, Tests")
    #expect(ClaudeAdapter.answerLabel(multi, picks: []) == nil)
    #expect(ClaudeAdapter.answerLabel(multi, picks: [5]) == nil)
    let single = ClaudeAdapter.Answerable(question: "Q", labels: ["Yes", "No"], multi: false)
    #expect(ClaudeAdapter.answerLabel(single, picks: [1]) == "No")
    #expect(ClaudeAdapter.answerLabel(single, picks: [0, 1]) == nil)
  }

  @Test func `rejects a negative legacy option index`() {
    #expect(parseSelections(json(#"{"options":[-1]}"#)) == nil)
  }
}

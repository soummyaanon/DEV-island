import Darwin
import Foundation
import IslandCore

/// The daemon (1.x's packages/daemon) in-process: normalises hook input into
/// events, folds them into sessions, holds approvals and questions open for
/// the notch, and streams it all over `/stream`. Same routes, auth and wire
/// format on 127.0.0.1:7433, so hooks already installed keep working and
/// 1.x's own UI can connect too.
final class EventHub {
  private(set) var registry = SessionRegistry()
  private var log: [AgentEvent] = []
  private var subscribers: [UUID: (Data) -> Void] = [:]
  private(set) var usage: [AgentUsage] = []
  private var approvals: [String: CheckedContinuation<String, Never>] = [:]
  private var questions: [String: CheckedContinuation<[[Int]]?, Never>] = [:]
  let holdFor: Duration
  let ringSize: Int

  init(holdFor: Duration, ringSize: Int) {
    self.holdFor = holdFor
    self.ringSize = ringSize
  }

  var subscriberCount: Int { subscribers.count }

  @discardableResult
  func ingest(_ input: EventInput) -> SessionSnapshot {
    let event = AgentEvent(input)
    let session = registry.apply(event)
    log.append(event)
    if log.count > ringSize { log.removeFirst(log.count - ringSize) }
    broadcast(WireMessage.event(event, session))
    return session
  }

  /// A new subscriber gets the snapshot (and usage) straight away.
  func subscribe(_ send: @escaping (Data) -> Void) -> UUID {
    let id = UUID()
    subscribers[id] = send
    send(WireMessage.snapshot(registry.list).encoded())
    if !usage.isEmpty { send(WireMessage.usage(usage).encoded()) }
    return id
  }

  func unsubscribe(_ id: UUID) { subscribers[id] = nil }

  func broadcast(_ data: Data) {
    for send in subscribers.values { send(data) }
  }

  private func broadcastSnapshot() { broadcast(WireMessage.snapshot(registry.list).encoded()) }

  /// Replaces one agent's quota, keeping the others (they refresh on different clocks).
  func setUsage(_ agent: AgentKind, _ next: AgentUsage?) {
    var all = usage.filter { $0.agent != agent }
    if let next { all.append(next) }
    let strip = { (list: [AgentUsage]) in list.map { "\($0.agent)\($0.windows)\(String(describing: $0.credits))\(String(describing: $0.plan))" } }
    let changed = strip(all) != strip(usage)
    usage = all
    if changed { broadcast(WireMessage.usage(all).encoded()) }
  }

  func endSession(_ agent: AgentKind, _ sessionId: String) {
    if registry.remove(SessionRegistry.key(agent, sessionId)) { broadcastSnapshot() }
  }

  func prune(stale: TimeInterval) -> [String] {
    let removed = registry.prune(isAlive: Self.isAlive, now: .now, stale: stale)
    if !removed.isEmpty { broadcastSnapshot() }
    return removed
  }

  /// Signal 0: does it exist? EPERM means yes, just not ours.
  static func isAlive(_ pid: Int) -> Bool {
    kill(pid_t(pid), 0) == 0 || errno == EPERM
  }

  func setPendingQuestion(_ agent: AgentKind, _ sessionId: String, _ question: PendingQuestion?) {
    if registry.setPendingQuestion(agent, sessionId, question, at: .now) != nil { broadcastSnapshot() }
  }

  func recent(_ limit: Int?) -> [AgentEvent] {
    guard let limit, limit < log.count else { return log }
    return Array(log.suffix(max(0, limit)))
  }

  // MARK: Holds

  /// Holds a tool call for the notch until allow, deny or the timeout.
  func requestApproval(_ agent: AgentKind, _ sessionId: String, tool: String, input: [String: JSONValue], plan: String?) async -> String {
    let id = UUID().uuidString.lowercased()
    let approval = PendingApproval(id: id, toolName: tool, toolInput: input, plan: plan, createdAt: .now)
    if registry.setPendingApproval(agent, sessionId, approval, at: .now) != nil { broadcastSnapshot() }
    let outcome = await withCheckedContinuation { continuation in
      approvals[id] = continuation
      expire(id)
    }
    if registry.setPendingApproval(agent, sessionId, nil, at: .now) != nil { broadcastSnapshot() }
    return outcome
  }

  func resolveApproval(_ id: String, _ decision: String) -> Bool {
    guard let continuation = approvals.removeValue(forKey: id) else { return false }
    continuation.resume(returning: decision)
    return true
  }

  /// Holds an AskUserQuestion open; nil on timeout (Claude's own picker takes over).
  func requestAnswer(_ agent: AgentKind, _ sessionId: String, _ question: PendingQuestion) async -> [[Int]]? {
    setPendingQuestion(agent, sessionId, question)
    let outcome = await withCheckedContinuation { continuation in
      questions[question.id] = continuation
      expire(question.id)
    }
    if outcome != nil { setPendingQuestion(agent, sessionId, nil) }
    return outcome
  }

  func answer(_ id: String, _ selections: [[Int]]) -> Bool {
    guard let continuation = questions.removeValue(forKey: id) else { return false }
    continuation.resume(returning: selections)
    return true
  }

  /// A held hook never hangs its agent: each hold resumes exactly once.
  private func expire(_ id: String) {
    Task { [weak self, holdFor] in
      try? await Task.sleep(for: holdFor)
      guard let self else { return }
      approvals.removeValue(forKey: id)?.resume(returning: "timeout")
      questions.removeValue(forKey: id)?.resume(returning: nil)
    }
  }
}

/// Configuration, with 1.x's environment overrides.
struct DaemonConfig {
  var port: UInt16 = 7433
  /// Reject requests without the token; lenient mode logs and allows.
  var strict = false
  var ringSize = 500
  var heartbeat: Duration = .seconds(30)
  var hold: Duration = .seconds(110)
  var codexHome: URL
  var usageEvery: Duration = .seconds(45)
  var codexActive: TimeInterval = 600
  var codexPoll: Duration = .milliseconds(1500)
  var codexScan: Duration = .seconds(10)

  static var standard: DaemonConfig {
    let env = ProcessInfo.processInfo.environment
    func int(_ key: String) -> Int? { env[key].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
    var config = DaemonConfig(codexHome: env["CODEX_HOME"].map { URL(filePath: $0) } ?? URL.homeDirectory.appending(path: ".codex"))
    config.port = int("AGENT_ISLAND_PORT").flatMap(UInt16.init(exactly:)) ?? 7433
    config.strict = env["AGENT_ISLAND_STRICT"] == "1"
    if let ring = int("AGENT_ISLAND_RING_SIZE") { config.ringSize = ring }
    if let ms = int("AGENT_ISLAND_HEARTBEAT_MS") { config.heartbeat = .milliseconds(ms) }
    if let ms = int("AGENT_ISLAND_APPROVAL_HOLD_MS") { config.hold = .milliseconds(ms) }
    if let ms = int("AGENT_ISLAND_USAGE_POLL_MS") { config.usageEvery = .milliseconds(ms) }
    if let ms = int("AGENT_ISLAND_CODEX_ACTIVE_MS") { config.codexActive = Double(ms) / 1000 }
    if let ms = int("AGENT_ISLAND_CODEX_POLL_MS") { config.codexPoll = .milliseconds(ms) }
    if let ms = int("AGENT_ISLAND_CODEX_SCAN_MS") { config.codexScan = .milliseconds(ms) }
    return config
  }
}

/// Runs the daemon, unless one is already listening (1.x, or `pnpm dev`),
/// which it then reuses like 1.x's daemon-manager did.
final class Daemon {
  private let config: DaemonConfig
  private let hub: EventHub
  private var server: HTTPServer?
  private var codex: CodexReader?
  private var timers: [Task<Void, Never>] = []
  private let token: String
  private let started = Date.now
  /// Open streams, kept until they close.
  private var peers: [UUID: WebSocketPeer] = [:]
  /// True once we're the one serving.
  private(set) var isRunning = false

  init(config: DaemonConfig = .standard) {
    self.config = config
    hub = EventHub(holdFor: config.hold, ringSize: config.ringSize)
    token = (try? ZeroConfig.standard.ensureToken()) ?? ""
  }

  func start() async {
    if await Self.isUp(port: config.port) {
      Log.daemon.notice("reusing the daemon already on :\(self.config.port)")
      return
    }
    do {
      let server = try HTTPServer(port: config.port, handler: { [weak self] in await self?.handle($0) ?? .json(500, ["error": "gone"]) }) { [weak self] request, peer in
        self?.stream(request, peer)
      }
      server.onReady = { [weak self] in
        guard let self else { return }
        isRunning = true
        Log.daemon.notice("daemon ready on 127.0.0.1:\(self.config.port), auth \(self.config.strict ? "strict" : "lenient", privacy: .public)")
      }
      server.onFailure = { error in Log.daemon.error("daemon failed: \(error.localizedDescription, privacy: .public)") }
      server.start()
      self.server = server
    } catch {
      Log.daemon.error("daemon could not listen: \(error.localizedDescription, privacy: .public)")
      return
    }
    let codex = CodexReader(home: config.codexHome, hub: hub, active: config.codexActive)
    self.codex = codex
    timers = [
      every(config.heartbeat) { [hub] in hub.broadcast(WireMessage.ping.encoded()) },
      every(config.usageEvery, now: true) { [weak self] in await self?.refreshUsage() },
      every(.seconds(5)) { [hub] in
        let gone = hub.prune(stale: 30 * 60)
        if !gone.isEmpty { Log.daemon.notice("pruned ended sessions: \(gone.joined(separator: ", "), privacy: .public)") }
      },
      every(config.codexScan, now: true) { await codex.scan() },
      every(config.codexPoll) { await codex.poll() },
    ]
  }

  func stop() {
    timers.forEach { $0.cancel() }
    server?.stop()
  }

  private func every(_ interval: Duration, now: Bool = false, _ work: @escaping () async -> Void) -> Task<Void, Never> {
    Task {
      if now { await work() }
      while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        if Task.isCancelled { return }
        await work()
      }
    }
  }

  static func isUp(port: UInt16) async -> Bool {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
    request.timeoutInterval = 1.2
    guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
    return (response as? HTTPURLResponse)?.statusCode == 200
  }

  /// Codex's quota from its newest rollout (while in use); Claude's pushed
  /// reading only ages out past its reset.
  private func refreshUsage() async {
    hub.setUsage(.codex, await codex?.usage())
    if let claude = hub.usage.first(where: { $0.agent == .claudeCode }) {
      hub.setUsage(.claudeCode, ClaudeAdapter.fresh(claude))
    }
  }

  // MARK: Routes

  private func authorized(_ request: HTTPRequest) -> Bool {
    let provided = request.header("x-agent-island-token")?.nilIfEmpty
      ?? request.header("authorization")?.firstMatch(of: /(?i)^Bearer\s+(.+)$/).map { String($0.1).trimmingCharacters(in: .whitespaces) }
    if let provided, !token.isEmpty, provided == token { return true }
    if config.strict { return false }
    Log.daemon.debug("\(request.method, privacy: .public) \(request.path, privacy: .public) accepted without a valid token (lenient)")
    return true
  }

  private func handle(_ request: HTTPRequest) async -> HTTPResponse {
    let parts = request.path.split(separator: "/").map(String.init)
    let body = JSONValue(json: request.body)
    switch (request.method, parts.first, parts.count) {
    case ("GET", "health", 1):
      return .json(200, ["status": "ok", "sessions": hub.registry.list.count, "subscribers": hub.subscriberCount, "uptime_s": Int(Date.now.timeIntervalSince(started))])
    case ("GET", "sessions", 1):
      return .json(200, encode(["sessions": hub.registry.list]))
    case ("GET", "usage", 1):
      return .json(200, encode(["usage": hub.usage]))
    case ("GET", "events", 1):
      return .json(200, encode(["events": hub.recent(request.query["limit"].flatMap { Int($0) }.map { max(0, $0) })]))
    case ("POST", "events", 1):
      guard authorized(request) else { return .json(401, ["error": "invalid or missing token"]) }
      guard let body, let input = EventInput(body: body) else { return .json(400, ["error": "invalid event"]) }
      hub.ingest(input)
      return .json(202, ["ok": true])
    case ("POST", "events", 3) where parts[1] == "claude":
      guard authorized(request) else { return .json(401, ["error": "invalid or missing token"]) }
      return await claudeHook(parts[2], body, request)
    case ("POST", "events", 3) where parts[1] == "cursor":
      guard authorized(request) else { return .json(401, ["error": "invalid or missing token"]) }
      return cursorHook(parts[2], body ?? .object([:]), request)
    case ("POST", "usage", 2) where parts[1] == "claude":
      guard authorized(request) else { return .json(401, ["error": "invalid or missing token"]) }
      if let body, let usage = ClaudeAdapter.usage(from: body) { hub.setUsage(.claudeCode, usage) }
      return .empty
    case ("POST", "approvals", 2):
      guard let decision = body?["decision"]?.string, decision == "allow" || decision == "deny" else {
        return .json(400, ["error": "decision must be 'allow' or 'deny'"])
      }
      let resolved = hub.resolveApproval(parts[1], decision)
      return .json(resolved ? 200 : 404, ["ok": resolved])
    case ("POST", "questions", 2):
      guard let selections = parseSelections(body) else {
        return .json(400, ["error": "selections must be a non-empty array of non-empty arrays of non-negative integers"])
      }
      let resolved = hub.answer(parts[1], selections)
      return .json(resolved ? 200 : 404, ["ok": resolved])
    default:
      return .json(404, ["error": "not found"])
    }
  }

  private func encode<T: Encodable>(_ value: T) -> Data {
    (try? WireMessage.encoder().encode(value)) ?? Data()
  }

  /// Claude Code hooks. ALWAYS an empty 204 unless we're answering a held
  /// approval or question: Claude reads any 2xx JSON as a decision.
  private func claudeHook(_ slug: String, _ body: JSONValue?, _ request: HTTPRequest) async -> HTTPResponse {
    guard let payload = body, let session = payload["session_id"]?.string else { return .empty }
    let event = ClaudeAdapter.eventName(slug: slug, payload: payload)
    // The session closed: it leaves the island now.
    if event == "SessionEnd" {
      hub.endSession(.claudeCode, session)
      return .empty
    }
    let fallback = hub.registry.get(.claudeCode, session)?.cwd ?? "(unknown)"
    guard var mapped = ClaudeAdapter.map(event, payload: payload, fallbackCwd: fallback) else { return .empty }
    var meta = ClaudeAdapter.terminalMeta { request.header($0) }
    if let mode = payload["permission_mode"]?.string { meta["permission_mode"] = .string(mode) }
    mapped.addMeta(meta)
    hub.ingest(mapped)

    let tool = payload["tool_name"]?.string
    let input = payload["tool_input"]
    // "Claude asks": held while a UI can answer; any later activity clears it.
    if tool == "AskUserQuestion", event == "PermissionRequest" || event == "PreToolUse" {
      let question = ClaudeAdapter.question(from: input)
      if let question, let answerable = ClaudeAdapter.answerable(input), event == "PermissionRequest", hub.subscriberCount > 0 {
        if let picks = await hub.requestAnswer(.claudeCode, session, question), picks.count == answerable.count {
          let labels = zip(answerable, picks).map { ClaudeAdapter.answerLabel($0, picks: $1) }
          if labels.allSatisfy({ $0 != nil }) {
            var updated = input?.object ?? [:]
            updated["answers"] = .object(Dictionary(zip(answerable.map(\.question), labels.map { JSONValue.string($0!) }), uniquingKeysWith: { _, b in b }))
            return decision(["behavior": .string("allow"), "updatedInput": .object(updated)])
          }
        }
        return .empty
      }
      hub.setPendingQuestion(.claudeCode, session, question)
    } else if event != "Notification" {
      // Notifications fire WHILE the question is open; only real activity answers it.
      hub.setPendingQuestion(.claudeCode, session, nil)
    }

    // Interactive approval, only when a UI is connected; otherwise Claude's own
    // prompt takes over at once, so the session never hangs.
    if event == "PermissionRequest", tool != "AskUserQuestion", hub.subscriberCount > 0 {
      let outcome = await hub.requestApproval(.claudeCode, session, tool: tool ?? "tool", input: input?.object ?? [:], plan: ClaudeAdapter.plan(from: input))
      if outcome == "allow" || outcome == "deny" { return decision(["behavior": .string(outcome)]) }
    }
    return .empty
  }

  private func decision(_ decision: [String: JSONValue]) -> HTTPResponse {
    let output: JSONValue = .object(["hookSpecificOutput": .object(["hookEventName": .string("PermissionRequest"), "decision": .object(decision)])])
    return .json(200, (try? JSONEncoder().encode(output)) ?? Data())
  }

  /// Cursor hooks, fire-and-forget from the bridge: always an empty 204.
  private func cursorHook(_ slug: String, _ payload: JSONValue, _ request: HTTPRequest) -> HTTPResponse {
    let event = CursorAdapter.eventName(slug: slug, payload: payload)
    let fallback = CursorAdapter.sessionId(payload).flatMap { hub.registry.get(.cursor, $0)?.cwd } ?? "(unknown)"
    guard var mapped = CursorAdapter.map(event, payload: payload, fallbackCwd: fallback) else { return .empty }
    // The bridge's $PPID is Cursor's hook runner: the meter's root.
    if let pid = request.header("x-agent-pid")?.trimmingCharacters(in: .whitespaces), pid.wholeMatch(of: /\d{1,7}/) != nil {
      mapped.addMeta(["pid": .string(pid)])
    }
    hub.ingest(mapped)
    return .empty
  }

  private func stream(_ request: HTTPRequest, _ peer: WebSocketPeer) {
    guard request.path == "/stream" else {
      peer.close()
      return
    }
    let id = hub.subscribe { [weak peer] in peer?.send($0) }
    peers[id] = peer
    peer.onClose = { [weak self, weak hub] in
      hub?.unsubscribe(id)
      self?.peers[id] = nil
    }
  }
}

/// Tails Codex's rollout logs into the hub: read-only and never fatal.
final class CodexReader {
  private let home: URL
  private let hub: EventHub
  private let active: TimeInterval
  private var tails: [String: CodexAdapter.Tail] = [:]

  init(home: URL, hub: EventHub, active: TimeInterval) {
    self.home = home
    self.hub = hub
    self.active = active
  }

  private var sessions: URL { home.appending(path: "sessions") }

  private func rollouts() -> [(path: String, modified: Date, size: Int)] {
    guard let walker = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return [] }
    var out: [(String, Date, Int)] = []
    for case let url as URL in walker where CodexAdapter.isRollout(url.lastPathComponent) {
      let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
      out.append((url.path, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0))
    }
    return out
  }

  /// Attaches recently written rollouts not yet tailed, with a compact catch-up.
  func scan() async {
    let cutoff = Date.now.addingTimeInterval(-active)
    for file in rollouts() where tails[file.path] == nil && file.modified >= cutoff {
      guard let data = FileManager.default.contents(atPath: file.path) else { continue }
      var tail = CodexAdapter.Tail(fileName: URL(filePath: file.path).lastPathComponent)
      var events = tail.attach(data)
      // Which process this is, for the meter: once per attach.
      if let pid = await Self.pid(for: file.path) {
        tail.context.meta["pid"] = String(pid)
        if let index = events.firstIndex(where: { $0.type == .sessionStarted }) { events[index].addMeta(["pid": .string(String(pid))]) }
      }
      for event in events { hub.ingest(event) }
      tails[file.path] = tail
    }
  }

  /// Reads appended bytes; idle files let go (a later write re-attaches).
  func poll() async {
    let cutoff = Date.now.addingTimeInterval(-active)
    for (path, var tail) in tails {
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
        let size = attributes[.size] as? Int
      else {
        tails[path] = nil
        continue
      }
      if size < tail.offset {
        tails[path] = nil
      } else if size > tail.offset, let handle = FileHandle(forReadingAtPath: path) {
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(tail.offset))
        let data = (try? handle.read(upToCount: size - tail.offset)) ?? Data()
        for output in tail.append(data) {
          switch output {
          case let .ingest(event): hub.ingest(event)
          case let .question(session, question): hub.setPendingQuestion(.codex, session, question)
          }
        }
        tails[path] = tail
      } else if (attributes[.modificationDate] as? Date ?? .distantPast) < cutoff {
        tails[path] = nil
      }
    }
  }

  /// Codex's quota, only while it's been used recently.
  func usage() async -> AgentUsage? {
    guard let newest = rollouts().max(by: { $0.modified < $1.modified }), Date.now.timeIntervalSince(newest.modified) <= active,
      let data = FileManager.default.contents(atPath: newest.path)
    else { return nil }
    return CodexAdapter.usage(fromRollout: String(decoding: data, as: UTF8.self))
  }

  @concurrent
  nonisolated static func pid(for file: String) async -> Int? {
    func run(_ tool: String, _ arguments: [String]) -> String {
      let process = Process()
      process.executableURL = URL(filePath: tool)
      process.arguments = arguments
      let pipe = Pipe()
      process.standardOutput = pipe
      process.standardError = FileHandle.nullDevice
      guard (try? process.run()) != nil else { return "" }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return String(decoding: data, as: UTF8.self)
    }
    let lsof = run("/usr/sbin/lsof", ["-t", file])
    let pgrep = lsof.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? run("/usr/bin/pgrep", ["-x", "codex"]) : ""
    return CodexAdapter.pickPid(lsof: lsof, pgrep: pgrep)
  }
}

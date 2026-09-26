import Foundation
import IslandCore
import Observation

/// A one-shot bloom along the island's edge, one colour and rhythm per event.
struct EdgePulse: Equatable, Identifiable {
  enum Kind: Equatable {
    case done, failed, question, attention, approve, hello
  }

  let id = UUID()
  let kind: Kind
  let at = Date.now
}

/// A session that just finished or failed takes a bow in the wing.
struct SessionMoment: Equatable, Identifiable {
  enum Kind: Equatable { case done, failed }

  let id = UUID()
  let key: String
  let kind: Kind

  /// How long its avatar holds the wing.
  static let duration: Duration = .milliseconds(3500)
}

/// Every session and each agent's usage, as the daemon last said, plus what
/// just happened. One source of truth for the island, on the main actor.
@Observable
final class SessionStore {
  /// Attention first, then the most active, then the most recent.
  private(set) var sessions: [SessionSnapshot] = []
  private(set) var usage: [AgentUsage] = []
  private(set) var connected = false
  private(set) var pulse: EdgePulse?
  private(set) var moment: SessionMoment?

  /// Everything that changed in an update, for sounds, haptics and
  /// VoiceOver (phases 4–5 subscribe here).
  @ObservationIgnored var onTransitions: (([SessionTransition]) -> Void)?

  /// Integrations switched off in Settings disappear everywhere the UI looks.
  @ObservationIgnored var enabledAgents: Set<AgentKind> = Set(AgentKind.allCases) {
    didSet { publish(); usage = allUsage.filter { enabledAgents.contains($0.agent) } }
  }

  @ObservationIgnored private var byKey: [String: SessionSnapshot] = [:]
  @ObservationIgnored private var allUsage: [AgentUsage] = []
  /// Nil until the first snapshot, which only primes it: a relaunch never
  /// replays history.
  @ObservationIgnored private var marks: SessionMarks?
  @ObservationIgnored private var momentEnd: Task<Void, Never>?

  func apply(_ message: WireMessage) {
    switch message {
    case let .snapshot(all):
      byKey = Dictionary(all.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
      publish()
    case let .event(session):
      byKey[session.key] = session
      publish()
    case let .usage(entries):
      allUsage = entries
      usage = entries.filter { enabledAgents.contains($0.agent) }
    case .ping, .unknown:
      break
    }
  }

  func setConnected(_ value: Bool) {
    if connected != value { connected = value }
  }

  func firePulse(_ kind: EdgePulse.Kind) {
    pulse = EdgePulse(kind: kind)
  }

  func clearPulse(_ id: UUID) {
    if pulse?.id == id { pulse = nil }
  }

  var momentSession: SessionSnapshot? {
    moment.flatMap { moment in sessions.first { $0.key == moment.key } }
  }

  private func publish() {
    let next = SessionList.sorted(byKey.values.filter { enabledAgents.contains($0.agent) })
    sessions = next
    defer { marks = SessionMarks(next) }
    guard let marks else { return }

    let transitions = marks.transitions(to: next)
    guard !transitions.isEmpty else { return }
    for transition in transitions {
      // One burst per session; done and failed win over needs-you cues.
      let kind: EdgePulse.Kind = switch transition.primary {
      case .done: .done
      case .failed: .failed
      case .question: .question
      case .attention: .attention
      }
      firePulse(kind)
      if transition.kinds.contains(.done) { show(SessionMoment(key: transition.key, kind: .done)) }
      else if transition.kinds.contains(.failed) { show(SessionMoment(key: transition.key, kind: .failed)) }
    }
    onTransitions?(transitions)
  }

  private func show(_ next: SessionMoment) {
    moment = next
    momentEnd?.cancel()
    momentEnd = Task { [weak self] in
      do { try await Task.sleep(for: SessionMoment.duration) } catch { return }
      if self?.moment?.id == next.id { self?.moment = nil }
    }
  }
}

/// The daemon's stream (`ws://127.0.0.1:7433/stream`): a snapshot on connect,
/// then every event. Reconnects on its own, backing off while nothing's there.
final class DaemonClient {
  private let store: SessionStore
  private var loop: Task<Void, Never>?

  init(store: SessionStore) {
    self.store = store
  }

  /// `~/.agent-island`, or `$AGENT_ISLAND_HOME`.
  static var home: URL {
    if let custom = ProcessInfo.processInfo.environment["AGENT_ISLAND_HOME"], !custom.isEmpty {
      return URL(filePath: custom)
    }
    return URL.homeDirectory.appending(path: ".agent-island")
  }

  static var port: Int {
    ProcessInfo.processInfo.environment["AGENT_ISLAND_PORT"].flatMap(Int.init) ?? 7433
  }

  /// The shared token the hooks send too; the daemon only insists on it in strict mode.
  private static var token: String? {
    let text = try? String(contentsOf: home.appending(path: "token"), encoding: .utf8)
    return text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  /// Resolves a held approval.
  func resolveApproval(id: String, decision: String) async {
    _ = await post("/approvals/\(id)", body: ["decision": decision])
  }

  /// Answers a held question with 0-based picks per question. False when the
  /// hold is gone (expired or unknown): the caller falls back to the terminal.
  func answerQuestion(id: String, selections: [[Int]]) async -> Bool {
    await post("/questions/\(id)", body: ["selections": selections])
  }

  private func post(_ path: String, body: [String: Any]) async -> Bool {
    guard let id = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
      let url = URL(string: "http://127.0.0.1:\(Self.port)\(id)"),
      let data = try? JSONSerialization.data(withJSONObject: body)
    else { return false }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = data
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    if let token = Self.token { request.setValue(token, forHTTPHeaderField: "X-Agent-Island-Token") }
    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
      Log.daemon.notice("POST \(path, privacy: .public) → \(ok ? "ok" : "refused", privacy: .public)")
      return ok
    } catch {
      Log.daemon.error("POST \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
      return false
    }
  }

  func start() {
    guard loop == nil else { return }
    loop = Task { [weak self] in
      var delay: Duration = .milliseconds(1500)
      while !Task.isCancelled {
        guard let self else { return }
        if await self.stream() { delay = .milliseconds(1500) }
        self.store.setConnected(false)
        do { try await Task.sleep(for: delay) } catch { return }
        delay = min(delay * 2, .seconds(15))
      }
    }
  }

  /// One connection, until it drops. True if it ever got a message.
  private func stream() async -> Bool {
    var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(Self.port)/stream")!)
    if let token = Self.token { request.setValue(token, forHTTPHeaderField: "X-Agent-Island-Token") }
    let socket = URLSession.shared.webSocketTask(with: request)
    socket.resume()
    defer { socket.cancel(with: .goingAway, reason: nil) }

    var heard = false
    while !Task.isCancelled {
      let message: URLSessionWebSocketTask.Message
      do {
        message = try await socket.receive()
      } catch {
        if heard { Log.daemon.notice("stream closed: \(error.localizedDescription, privacy: .public)") }
        return heard
      }
      if !heard {
        heard = true
        store.setConnected(true)
        Log.daemon.notice("stream connected")
      }
      let data: Data
      switch message {
      case let .string(text): data = Data(text.utf8)
      case let .data(bytes): data = bytes
      @unknown default: continue
      }
      do {
        store.apply(try WireMessage(json: data))
      } catch {
        Log.daemon.error("undecodable message: \(error.localizedDescription, privacy: .public)")
      }
    }
    return heard
  }
}

extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}

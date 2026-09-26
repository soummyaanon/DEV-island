import AppKit
import Foundation
import IslandCore
import Observation
import UserNotifications

/// The Ask bar's conversation (1.x's AssistantBar.tsx): the island's Siri.
/// It answers and acts, showing each step; anything that does real work for
/// you (typing into an agent, running one of your Shortcuts) is only
/// proposed, and waits for your click.
@Observable
final class AssistantState {
  struct Turn: Identifiable {
    enum Status { case thinking, streaming, done, error }

    let id: String
    let question: String
    /// When it went out: the field's loading glow starts from here.
    let askedAt = Date.now
    var answer = ""
    var status = Status.thinking
    var error: String?
    /// What it did along the way ("Opening Safari").
    var steps: [String] = []
    /// The tool running right now; cleared when words arrive.
    var tool: String?
    /// Web results the answer was written from.
    var sources: [(title: String, url: URL)] = []
  }

  /// Waiting for the user's click before anything happens.
  struct Proposal: Identifiable {
    enum Kind { case draft(project: String, message: String), shortcut(name: String) }
    enum Status { case waiting, running, failed }

    let id: String
    let kind: Kind
    var status = Status.waiting
  }

  enum VoicePhase { case starting, downloading, listening }

  var isOpen = false
  var text = ""
  var focused = false
  private(set) var turns: [Turn] = []
  private(set) var proposals: [Proposal] = []
  /// A question has been out long enough to call it thinking, not connecting.
  private(set) var settled = false
  private(set) var voice: (id: String, phase: VoicePhase)?
  private(set) var speaking = false
  private(set) var voiceNote: String?

  /// How many exchanges stay on screen; the model keeps the rest.
  static let visibleTurns = 3

  @ObservationIgnored let engine: AssistantEngine
  @ObservationIgnored let voiceIO = Voice()
  /// The island's facts and deeds, wired by the model.
  @ObservationIgnored var sessions: () -> [SessionSnapshot] = { [] }
  @ObservationIgnored var sendPrompt: (String, SessionSnapshot) -> Void = { _, _ in }
  @ObservationIgnored var onTimer: (String) -> Void = { _ in }
  @ObservationIgnored var haptic: (Haptic) -> Void = { _ in }
  @ObservationIgnored var speakReplies: () -> Bool = { true }
  @ObservationIgnored private var spokenTurns: Set<String> = []
  @ObservationIgnored private var settleTask: Task<Void, Never>?
  @ObservationIgnored private var sequence = 0
  @ObservationIgnored private var timers: [Task<Void, Never>] = []

  init(engine: AssistantEngine) {
    self.engine = engine
    engine.onEvent = { [weak self] in self?.handle($0) }
    voiceIO.onEvent = { [weak self] in self?.handle($0) }
  }

  var live: Turn? { turns.last { $0.status == .thinking || $0.status == .streaming } }

  var orb: OrbState {
    AssistantContext.orb(.init(sent: live?.status == .thinking, settled: settled, tool: live?.tool, streaming: live?.status == .streaming, proposing: !proposals.isEmpty))
  }

  /// At rest the orb holds still: it only moves while something happens.
  var orbResting: Bool { live == nil && proposals.isEmpty && voice == nil && !(focused && !text.isEmpty) }

  var placeholder: String {
    if let voice {
      return switch voice.phase {
      case .downloading: "Getting the speech model…"
      case .listening: "Listening…"
      case .starting: "Starting the mic…"
      }
    }
    if speaking { return "Speaking…" }
    return engine.support.isAvailable ? "Ask anything…" : "Open, search, set a timer…"
  }

  // MARK: Open and close

  func open() {
    isOpen = true
  }

  /// Closing ends the conversation, so the next starts with the model's
  /// whole (small) context.
  func close() {
    isOpen = false
    focused = false
    text = ""
    engine.reset()
    if let voice { voiceIO.stop(id: voice.id) }
    voice = nil
    voiceIO.stopSpeaking()
    speaking = false
  }

  // MARK: Asking

  func ask(spoken: String? = nil) {
    let question = (spoken ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty else { return }
    voiceIO.stopSpeaking()
    speaking = false
    sequence += 1
    let id = "q\(Int(Date.now.timeIntervalSince1970 * 1000))\(sequence)"
    if spoken != nil { spokenTurns.insert(id) }
    turns = Array((turns + [Turn(id: id, question: question)]).suffix(Self.visibleTurns))
    text = ""
    haptic(.tick)
    settled = false
    settleTask?.cancel()
    settleTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(900))
      if self?.live?.id == id { self?.settled = true }
    }
    engine.ask(id: id, prompt: question, context: AssistantContext.text(sessions(), now: .now))
  }

  func cancel() {
    if let live { engine.cancel(live.id) }
  }

  func copyAnswer(_ turn: Turn) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(turn.answer, forType: .string)
    haptic(.tick)
  }

  func accept(_ proposal: Proposal) {
    haptic(.commit)
    switch proposal.kind {
    case let .draft(project, message):
      proposals.removeAll { $0.id == proposal.id }
      if let target = AssistantContext.session(named: project, in: sessions()) { sendPrompt(message, target) }
    case let .shortcut(name):
      setStatus(proposal.id, .running)
      Task { [weak self] in
        let ok = await Self.runShortcut(name)
        if ok { self?.proposals.removeAll { $0.id == proposal.id } } else { self?.setStatus(proposal.id, .failed) }
      }
    }
  }

  func dismiss(_ proposal: Proposal) {
    proposals.removeAll { $0.id == proposal.id }
  }

  private func setStatus(_ id: String, _ status: Proposal.Status) {
    if let index = proposals.firstIndex(where: { $0.id == id }) { proposals[index].status = status }
  }

  /// Only ever reached from the user's click on a proposal. The name is an
  /// argument, never interpreted by a shell.
  @concurrent
  nonisolated static func runShortcut(_ name: String) async -> Bool {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/shortcuts")
    process.arguments = ["run", name]
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
  }

  // MARK: Voice

  /// Typing over a spoken answer silences it, quietly.
  func stopSpeaking() {
    guard speaking else { return }
    voiceIO.stopSpeaking()
    speaking = false
  }

  func toggleVoice() {
    haptic(.tick)
    if let voice {
      voiceIO.stop(id: voice.id)
      return
    }
    if speaking {
      voiceIO.stopSpeaking()
      speaking = false
      return
    }
    voiceNote = nil
    text = ""
    sequence += 1
    let id = "v\(Int(Date.now.timeIntervalSince1970 * 1000))\(sequence)"
    voice = (id, .starting)
    voiceIO.start(id: id)
  }

  private func handle(_ event: VoiceEvent) {
    if case .spoken = event {
      speaking = false
      return
    }
    guard let current = voice else { return }
    switch event {
    case let .listening(id) where id == current.id: voice = (id, .listening)
    case let .downloading(id) where id == current.id: voice = (id, .downloading)
    case let .partial(id, words) where id == current.id: text = words
    case let .final(id, words) where id == current.id:
      voice = nil
      text = ""
      if !words.trimmingCharacters(in: .whitespaces).isEmpty { ask(spoken: words) }
    case let .error(id, reason) where id == current.id:
      voice = nil
      guard reason != "superseded" else { return }
      voiceNote = switch reason {
      case "mic-denied": "Allow the microphone for Agent Island in System Settings → Privacy & Security."
      case "model-unavailable": "The on-device speech model isn't available yet."
      case "no-microphone": "No microphone found."
      case "os": "Voice needs macOS 26 or later."
      default: "Voice isn't available right now."
      }
    default: break
    }
  }

  // MARK: Events

  private func handle(_ event: AssistantEvent) {
    switch event {
    case let .action(id, payload):
      act(id: id, payload)
    case let .tool(id, name, detail):
      update(id) {
        $0.tool = name
        $0.steps.append(detail)
      }
    case let .delta(id, answer):
      update(id) {
        $0.answer = answer
        $0.status = .streaming
        $0.tool = nil
      }
    case let .done(id):
      update(id) { turn in
        if spokenTurns.remove(id) != nil, !turn.answer.trimmingCharacters(in: .whitespaces).isEmpty, speakReplies() {
          voiceIO.speak(turn.answer)
          speaking = true
        }
        turn.status = .done
        turn.tool = nil
      }
    case let .error(id, reason):
      update(id) {
        $0.status = .error
        $0.tool = nil
        $0.error = switch reason {
        case "guardrail": "Apple Intelligence declined to answer that."
        case "context-full": "That chat got too long — starting fresh."
        case "cancelled": "Stopped."
        case "timeout": "That took too long, so I stopped. Try asking again."
        case "model-failed": "Apple Intelligence couldn't answer that one. Try rephrasing."
        default: "Apple Intelligence isn't available right now."
        }
      }
    }
  }

  private func update(_ id: String, _ change: (inout Turn) -> Void) {
    guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
    change(&turns[index])
  }

  /// Harmless actions happen at once (open a session, start a timer); real
  /// work for the user waits here as a proposal.
  private func act(id: String, _ payload: [String: String]) {
    switch payload["kind"] {
    case "open":
      let project = payload["project"] ?? ""
      if let target = AssistantContext.session(named: project, in: sessions()) { JumpBack.jump(to: target) }
    case "timer":
      guard let minutes = Int(payload["minutes"] ?? ""), (1...720).contains(minutes) else { return }
      startTimer(minutes: minutes, label: payload["label"] ?? "")
    case "sources":
      let urls = (payload["urls"] ?? "").split(separator: "\n").map(String.init)
      let titles = (payload["titles"] ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      let sources = urls.enumerated().compactMap { i, url -> (title: String, url: URL)? in
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard AssistantContext.isWebURL(trimmed), let link = URL(string: trimmed) else { return nil }
        return (i < titles.count ? titles[i] : "", link)
      }
      update(id) { $0.sources = Array(sources.prefix(5)) }
    case "draft":
      let message = payload["message"] ?? ""
      guard !message.trimmingCharacters(in: .whitespaces).isEmpty else { return }
      propose(Proposal(id: "\(id)-d", kind: .draft(project: payload["project"] ?? "", message: message)))
    case "shortcut":
      guard let name = payload["name"]?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
      propose(Proposal(id: "\(id)-s-\(name)", kind: .shortcut(name: name)))
    default:
      break
    }
  }

  private func propose(_ proposal: Proposal) {
    proposals.removeAll { $0.id == proposal.id }
    proposals.append(proposal)
    haptic(.tick)
  }

  // MARK: Timers

  /// "Remind me in 10 minutes": a notification, a chime and a bloom when it ends.
  private func startTimer(minutes: Int, label: String) {
    let timer = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(minutes * 60)) } catch { return }
      let content = UNMutableNotificationContent()
      content.title = label.isEmpty ? "Timer done" : "Timer: \(label)"
      content.body = "\(minutes) minute\(minutes == 1 ? "" : "s") are up."
      if Bundle.main.bundleIdentifier != nil {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
      }
      self?.onTimer(label)
    }
    timers.append(timer)
  }
}

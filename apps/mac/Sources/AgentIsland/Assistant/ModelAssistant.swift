#if canImport(FoundationModels)
import AppKit
import Foundation
import FoundationModels

/// The request a tool belongs to, so its actions carry the right id, and the
/// user's own words, so tools the model over-uses can check they were asked.
@available(macOS 26.0, *)
nonisolated final class RequestBox: @unchecked Sendable {
  // Written on the main actor before a request starts, read by its tools.
  var id = ""
  /// The latest session snapshot, for getAgentSessions.
  var context = ""
  var prompt = ""
  let send: @Sendable (AssistantEvent) -> Void

  init(send: @escaping @Sendable (AssistantEvent) -> Void) {
    self.send = send
  }

  func mentions(_ words: [String]) -> Bool {
    let p = prompt.lowercased()
    return words.contains { p.contains($0) }
  }

  func tool(_ name: String, _ detail: String) { send(.tool(id: id, name: name, detail: detail)) }
  func action(_ payload: [String: String]) { send(.action(id: id, payload: payload)) }
}

@available(macOS 26.0, *)
nonisolated private func arg(_ args: GeneratedContent, _ key: String) -> String {
  ((try? args.value(String.self, forProperty: key)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

@available(macOS 26.0, *)
nonisolated private func schema(_ props: [(String, String, Bool)]) -> GenerationSchema {
  GenerationSchema(
    type: GeneratedContent.self,
    properties: props.map { name, description, isInt in
      isInt
        ? GenerationSchema.Property(name: name, description: description, type: Int.self)
        : GenerationSchema.Property(name: name, description: description, type: String.self)
    })
}

// MARK: Tools
//
// Harmless, instantly reversible tools run straight away (open an app or a
// page, copy text, change the volume, start a timer). Anything that could do
// real work for the user (a Shortcut, a message to an agent) only PROPOSES:
// the island shows it and waits for a click.

@available(macOS 26.0, *)
nonisolated private struct OpenSessionTool: Tool {
  let box: RequestBox
  let name = "openSession"
  let description = "Bring one coding-agent session's terminal or editor to the front. Use when the user asks to open, show, go to or jump to a project."
  var parameters: GenerationSchema { schema([("project", "The session's project folder name, exactly as listed", false)]) }
  func call(arguments: GeneratedContent) async throws -> String {
    let project = arg(arguments, "project")
    box.action(["kind": "open", "project": project])
    return "Brought \(project) to the front."
  }
}

@available(macOS 26.0, *)
nonisolated private struct DraftAgentPromptTool: Tool {
  let box: RequestBox
  let name = "draftAgentPrompt"
  let description = "Draft a message to send to one coding agent (Claude Code, Codex or Cursor). Use when the user wants to tell, ask or instruct an agent. The user reviews and confirms it before it is sent."
  var parameters: GenerationSchema {
    schema([("project", "The session's project folder name, exactly as listed", false), ("message", "The message for the agent, in the user's words", false)])
  }
  func call(arguments: GeneratedContent) async throws -> String {
    let project = arg(arguments, "project")
    box.action(["kind": "draft", "project": project, "message": arg(arguments, "message")])
    return "Drafted the message for \(project); the user will confirm before it is sent."
  }
}

@available(macOS 26.0, *)
nonisolated private struct OpenAppTool: Tool {
  let box: RequestBox
  let name = "openApp"
  let description = "Open (launch or bring forward) an application on this Mac by its name, e.g. Safari, Notes, Music, Xcode."
  var parameters: GenerationSchema { schema([("name", "The application's name", false)]) }
  func call(arguments: GeneratedContent) async throws -> String {
    let app = arg(arguments, "name")
    box.tool("openApp", "Opening \(app)")
    guard let url = AssistantTools.findApplication(app) else { return "No app called \(app) is installed." }
    await MainActor.run { NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) }
    return "Opened \(url.deletingPathExtension().lastPathComponent)."
  }
}

@available(macOS 26.0, *)
nonisolated private struct OpenWebsiteTool: Tool {
  let box: RequestBox
  let name = "openWebsite"
  let description = "Open a web page in the default browser. Use for a specific site or link."
  var parameters: GenerationSchema { schema([("url", "The address, e.g. github.com or https://apple.com", false)]) }
  func call(arguments: GeneratedContent) async throws -> String {
    var raw = arg(arguments, "url")
    if !raw.contains("://") { raw = "https://" + raw }
    // Web pages only: never file://, custom schemes or anything that launches a handler.
    guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil else {
      return "That isn't a web address I can open."
    }
    box.tool("openWebsite", "Opening \(url.host ?? raw)")
    _ = await MainActor.run { NSWorkspace.shared.open(url) }
    return "Opened \(url.absoluteString)."
  }
}

@available(macOS 26.0, *)
nonisolated private struct SearchWebTool: Tool {
  let box: RequestBox
  let name = "searchWeb"
  let description = "Search the web and read the top results. Use for current events, prices, scores, recent facts, or when the user asks to look something up. Returns result titles, snippets and sites to answer from."
  var parameters: GenerationSchema { schema([("query", "What to search for", false)]) }
  func call(arguments: GeneratedContent) async throws -> String {
    let query = arg(arguments, "query")
    guard box.mentions([
      "search", "look up", "lookup", "google", "online", "on the web", "web", "browse", "latest",
      "news", "find out", "current", "today", "right now", "price", "score", "who won", "release",
    ]) else {
      return "Not searched: the user didn't ask for a web search. Answer from your own knowledge instead."
    }
    box.tool("searchWeb", "Searching “\(query)”")
    let results = await AssistantTools.fetchWebResults(query)
    if results.isEmpty {
      // Offline or blocked: at least put the search in front of the user.
      var parts = URLComponents(string: "https://duckduckgo.com/")!
      parts.queryItems = [URLQueryItem(name: "q", value: query)]
      if let url = parts.url { _ = await MainActor.run { NSWorkspace.shared.open(url) } }
      return "Couldn't read results directly, so a web search for \(query) was opened in the browser. Say so."
    }
    let sites = results.compactMap { URL(string: $0.url)?.host?.replacingOccurrences(of: "www.", with: "") }
    box.tool("readWeb", "Reading \(Set(sites).count) sources")
    box.action(["kind": "sources", "urls": results.map(\.url).joined(separator: "\n"), "titles": results.map(\.title).joined(separator: "\n")])
    let body = results.enumerated().map { i, r in "[\(i + 1)] \(r.title) (\(URL(string: r.url)?.host ?? "web"))\n\(r.snippet)" }.joined(separator: "\n\n")
    return """
      Web results for "\(query)":

      \(body)

      Answer the user's question from these results in two or three sentences, and name the site(s) you used. If the results don't answer it, say so.
      """
  }
}

@available(macOS 26.0, *)
nonisolated private struct ReadClipboardTool: Tool {
  let box: RequestBox
  let name = "readClipboard"
  let description = "Read the text on the clipboard. ONLY when the user explicitly mentions the clipboard or something they copied or pasted; never for greetings or other questions."
  var parameters: GenerationSchema { schema([]) }
  func call(arguments: GeneratedContent) async throws -> String {
    guard box.mentions(["clipboard", "copied", "copy", "paste", "pasted"]) else {
      return "Not read: the user didn't mention the clipboard. Answer the question directly."
    }
    box.tool("readClipboard", "Reading the clipboard")
    let text = await MainActor.run { NSPasteboard.general.string(forType: .string) } ?? ""
    if text.isEmpty { return "The clipboard has no text." }
    // The on-device context is small; a long copy is cut, and says so.
    return text.count > 3000 ? String(text.prefix(3000)) + "\n[truncated]" : text
  }
}

@available(macOS 26.0, *)
nonisolated private struct CopyToClipboardTool: Tool {
  let box: RequestBox
  let name = "copyToClipboard"
  let description = "Put text on the clipboard so the user can paste it. Use when asked to copy something, or after writing a draft the user wants to paste."
  var parameters: GenerationSchema { schema([("text", "The exact text to copy", false)]) }
  func call(arguments: GeneratedContent) async throws -> String {
    let text = (try? arguments.value(String.self, forProperty: "text")) ?? ""
    box.tool("copyToClipboard", "Copying to the clipboard")
    await MainActor.run {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    }
    return "Copied."
  }
}

@available(macOS 26.0, *)
nonisolated private struct SetVolumeTool: Tool {
  let box: RequestBox
  let name = "setVolume"
  let description = "Set the Mac's output volume, 0 to 100. 0 mutes."
  var parameters: GenerationSchema { schema([("percent", "Volume from 0 to 100", true)]) }
  func call(arguments: GeneratedContent) async throws -> String {
    let percent = max(0, min(100, (try? arguments.value(Int.self, forProperty: "percent")) ?? 50))
    box.tool("setVolume", "Volume \(percent)%")
    let ok = await MainActor.run { AssistantTools.setVolume(percent) }
    return ok ? "Volume set to \(percent)%." : "Couldn't change the volume."
  }
}

@available(macOS 26.0, *)
nonisolated private struct StartTimerTool: Tool {
  let box: RequestBox
  let name = "startTimer"
  let description = "Start a countdown timer; the island alerts the user when it ends. Use for 'remind me in 10 minutes' or 'set a timer'."
  var parameters: GenerationSchema { schema([("minutes", "How many minutes, 1 to 720", true), ("label", "What it's for, or empty", false)]) }
  func call(arguments: GeneratedContent) async throws -> String {
    let minutes = max(1, min(720, (try? arguments.value(Int.self, forProperty: "minutes")) ?? 5))
    let label = arg(arguments, "label")
    box.tool("startTimer", "Timer · \(minutes) min")
    box.action(["kind": "timer", "minutes": String(minutes), "label": label])
    return "Started a \(minutes)-minute timer\(label.isEmpty ? "" : " for \(label)")."
  }
}

@available(macOS 26.0, *)
nonisolated private struct RunShortcutTool: Tool {
  let box: RequestBox
  let name = "runShortcut"
  let description = "Run one of the user's Shortcuts (the Shortcuts app) by name. This is how to do things like turning on Focus, sending messages, home automation, or anything the user has a shortcut for. The user confirms before it runs."
  var parameters: GenerationSchema { schema([("name", "The shortcut's name", false)]) }
  func call(arguments: GeneratedContent) async throws -> String {
    let wanted = arg(arguments, "name")
    box.tool("runShortcut", "Finding the “\(wanted)” shortcut")
    let names = await MainActor.run { AssistantTools.listShortcuts() }
    let match = names.first { $0.lowercased() == wanted.lowercased() } ?? names.first { $0.lowercased().contains(wanted.lowercased()) }
    guard let match else {
      return names.isEmpty ? "The user has no Shortcuts." : "No shortcut called \(wanted). Some of theirs: \(names.prefix(12).joined(separator: ", "))."
    }
    box.action(["kind": "shortcut", "name": match])
    return "Asked the user to confirm running the \(match) shortcut."
  }
}

@available(macOS 26.0, *)
nonisolated private struct ListShortcutsTool: Tool {
  let box: RequestBox
  let name = "listShortcuts"
  let description = "List the names of the user's Shortcuts, to find one that fits what they asked."
  var parameters: GenerationSchema { schema([]) }
  func call(arguments: GeneratedContent) async throws -> String {
    box.tool("listShortcuts", "Looking through your Shortcuts")
    let names = await MainActor.run { AssistantTools.listShortcuts() }
    return names.isEmpty ? "The user has no Shortcuts." : names.prefix(60).joined(separator: "\n")
  }
}

@available(macOS 26.0, *)
nonisolated private struct AgentSessionsTool: Tool {
  let box: RequestBox
  let name = "getAgentSessions"
  let description = "Get the user's coding-agent sessions (Claude Code, Codex, Cursor) right now: project, state and current activity. Call this for ANY question about their agents or sessions."
  var parameters: GenerationSchema { schema([]) }
  func call(arguments: GeneratedContent) async throws -> String {
    box.tool("getAgentSessions", "Checking your agents")
    return box.context.isEmpty ? "No agent sessions are running." : box.context
  }
}

@available(macOS 26.0, *)
nonisolated private struct DateTimeTool: Tool {
  let box: RequestBox
  let name = "getDateTime"
  let description = "Get the current local date, time and weekday."
  var parameters: GenerationSchema { schema([]) }
  func call(arguments: GeneratedContent) async throws -> String {
    box.tool("getDateTime", "Checking the date")
    return DateFormatter.localizedString(from: .now, dateStyle: .full, timeStyle: .short)
  }
}

// MARK: Session

@available(macOS 26.0, *)
final class ModelAssistant {
  private let box: RequestBox
  private let send: @MainActor @Sendable (AssistantEvent) -> Void
  private var session: LanguageModelSession?
  private var task: Task<Void, Never>?
  private var currentId = ""

  /// Longest the model may go without producing anything before it's stopped.
  private let stall: TimeInterval = 25

  static let instructions = """
    You are the assistant inside Agent Island, the Dynamic Island on the user's Mac — an agent \
    like Siri that can act, not only answer. You are a capable general assistant: answer \
    questions, explain, brainstorm, do quick maths, translate, and draft or rewrite text. When \
    the user asks you to DO something, use your tools rather than telling them how: openApp, \
    openWebsite, searchWeb, readClipboard, copyToClipboard, setVolume, startTimer, \
    listShortcuts and runShortcut for anything else the user has a shortcut for. You also know \
    the user's coding agents (Claude Code, Codex, Cursor) through getAgentSessions. Use openSession to jump to a \
    project and draftAgentPrompt to tell or ask an agent something. You may chain several tools \
    for one request. For anything about the user's agents or sessions, call getAgentSessions \
    first and answer from it; never invent sessions. For the date or time, call getDateTime; \
    never search for it. Only use searchWeb when the user asks to look something up or needs \
    current information you don't have. Only read the clipboard when the user talks about it. For \
    greetings and small talk, just reply. Never claim you did something a tool didn't report. Write plain text \
    without markdown headings; after acting, say what you did in one short sentence.
    """

  init(send: @escaping @MainActor @Sendable (AssistantEvent) -> Void) {
    self.send = send
    box = RequestBox { event in Task { @MainActor in send(event) } }
  }

  private func freshSession() -> LanguageModelSession {
    LanguageModelSession(
      tools: [
        AgentSessionsTool(box: box), DateTimeTool(box: box), OpenSessionTool(box: box), DraftAgentPromptTool(box: box),
        OpenAppTool(box: box), OpenWebsiteTool(box: box), SearchWebTool(box: box), ReadClipboardTool(box: box),
        CopyToClipboardTool(box: box), SetVolumeTool(box: box), StartTimerTool(box: box), ListShortcutsTool(box: box),
        RunShortcutTool(box: box),
      ],
      instructions: Self.instructions
    )
  }

  func reset() {
    task?.cancel()
    session = nil
  }

  func cancel(_ id: String) {
    if id == currentId { task?.cancel() }
  }

  func ask(id: String, prompt: String, context: String) {
    // One answer at a time: a new question supersedes the one in flight.
    task?.cancel()
    currentId = id
    box.id = id
    // Plain commands don't need the model: the reader does them instantly and exactly.
    if CommandReader.run(prompt: prompt, context: context, emit: Emitter(id: id, send: send), modelSearches: true) { return }
    if session == nil || session?.isResponding == true { session = freshSession() }
    // Date and sessions are tools, not text in the question: the small model
    // parroted any background it was handed straight back.
    box.context = context
    box.prompt = prompt
    task = Task { [weak self] in await self?.stream(id: id, prompt: prompt, context: context, attempt: 1) }
  }

  private func stream(id: String, prompt: String, context: String, attempt: Int) async {
    guard let session else { return }
    var last = ""
    var lastActivity = Date.now
    var stalled = false
    // A hung generation must not leave the orb spinning forever.
    let watchdog = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        if Date.now.timeIntervalSince(lastActivity) > (self?.stall ?? 25) {
          stalled = true
          self?.task?.cancel()
          return
        }
      }
    }
    defer { watchdog.cancel() }
    do {
      for try await snapshot in session.streamResponse(to: prompt) {
        if Task.isCancelled { break }
        lastActivity = .now
        let text = AssistantTools.stripBackground(snapshot.content)
        if text != last {
          last = text
          send(.delta(id: id, text: text))
        }
      }
      send(stalled ? .error(id: id, reason: "timeout") : Task.isCancelled ? .error(id: id, reason: "cancelled") : .done(id: id))
    } catch LanguageModelSession.GenerationError.guardrailViolation {
      send(.error(id: id, reason: "guardrail"))
    } catch {
      if stalled { return send(.error(id: id, reason: "timeout")) }
      if Task.isCancelled { return send(.error(id: id, reason: "cancelled")) }
      // A full context, a hiccup, a tool that threw: a fresh session and one
      // more try; then the command reader; only then give up.
      self.session = freshSession()
      if attempt == 1, last.isEmpty {
        await stream(id: id, prompt: prompt, context: context, attempt: 2)
      } else if last.isEmpty, CommandReader.run(prompt: prompt, context: context, emit: Emitter(id: id, send: send)) {
        return
      } else if !last.isEmpty {
        send(.done(id: id))
      } else {
        send(.error(id: id, reason: String(describing: error).contains("exceededContextWindowSize") ? "context-full" : "model-failed"))
      }
    }
  }
}
#endif

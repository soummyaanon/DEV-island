import AppKit
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// What the assistant reports while it answers. The sidecar's line protocol
/// (`ai delta/done/error/tool/action`), now typed and in-process.
enum AssistantEvent: Sendable {
  /// The answer so far (cumulative).
  case delta(id: String, text: String)
  case done(id: String)
  case error(id: String, reason: String)
  /// A tool started: the island shows the step and the orb switches to it.
  case tool(id: String, name: String, detail: String)
  /// Something for the island to do or confirm (open, draft, timer, shortcut, sources).
  case action(id: String, payload: [String: String])
}

/// Whether the on-device model can answer, and if not, why.
enum AssistantSupport: Equatable, Sendable {
  case available
  /// The command reader answers; the reason the model can't.
  case basic(String)

  var isAvailable: Bool { self == .available }
}

/// The assistant behind the Ask bar (moved in from the sidecar): Apple's
/// on-device model with tools that act, and a plain command reader on Macs
/// without Apple Intelligence. Nothing leaves the Mac except a web search the
/// user asked for.
final class AssistantEngine {
  /// Where events go (the Ask bar).
  var onEvent: (AssistantEvent) -> Void = { _ in }
  /// Settings → Apple Intelligence off: commands still work, nothing goes to the model.
  var forceBasic = ProcessInfo.processInfo.environment["AGENT_ISLAND_FORCE_BASIC"] == "1"

  #if canImport(FoundationModels)
  private var modelBox: Any?
  #endif

  var support: AssistantSupport {
    if forceBasic { return .basic("off") }
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
      switch SystemLanguageModel.default.availability {
      case .available: return .available
      case .unavailable(.deviceNotEligible): return .basic("device-not-eligible")
      case .unavailable(.appleIntelligenceNotEnabled): return .basic("not-enabled")
      case .unavailable(.modelNotReady): return .basic("model-not-ready")
      case .unavailable: return .basic("other")
      }
    }
    return .basic("os")
    #else
    return .basic("sdk")
    #endif
  }

  func ask(id: String, prompt: String, context: String) {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *), support.isAvailable {
      model.ask(id: id, prompt: prompt, context: context)
      return
    }
    #endif
    let emitter = Emitter(id: id, send: onEvent)
    if CommandReader.run(prompt: prompt, context: context, emit: emitter) { return }
    emitter.reply("I can open apps, sites and sessions, search the web, set timers and the volume, and run your Shortcuts here. Answering questions needs Apple Intelligence (macOS 26 on a supported Mac).")
  }

  func cancel(_ id: String) {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) { (modelBox as? ModelAssistant)?.cancel(id) }
    #endif
  }

  /// Forgets the conversation.
  func reset() {
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) { (modelBox as? ModelAssistant)?.reset() }
    #endif
  }

  /// One warm line for the hello, from a few plain facts; nil when the model
  /// can't (or takes longer than `timeout`).
  func greet(facts: String, timeout: Duration = .seconds(7)) async -> String? {
    #if canImport(FoundationModels)
    guard #available(macOS 26.0, *), support.isAvailable else { return nil }
    return await withTaskGroup(of: String?.self) { group in
      group.addTask { await Self.greetLine(facts: facts) }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
    #else
    return nil
    #endif
  }

  #if canImport(FoundationModels)
  @available(macOS 26.0, *)
  private var model: ModelAssistant {
    if let existing = modelBox as? ModelAssistant { return existing }
    let created = ModelAssistant(send: { [weak self] in self?.onEvent($0) })
    modelBox = created
    return created
  }

  nonisolated static let greetInstructions = """
    You are the little robot living in the user's Mac notch (Agent Island). Write ONE short, \
    warm, playful line to say hello, like a friendly companion who just woke up. You may mention \
    at most two of the facts listed under Facts. Mention ONLY facts that are listed: if weather \
    or battery is not listed, do not mention weather or battery at all. The user's name is \
    already shown above your line, so don't repeat it. At most 16 words. No emoji, no \
    hashtags, no quotes, no markdown. Don't say you are an AI. At most one question.
    """

  /// A one-shot, tool-less session so the hello never touches the Ask bar's conversation.
  @available(macOS 26.0, *)
  @concurrent
  nonisolated static func greetLine(facts: String) async -> String? {
    do {
      let session = LanguageModelSession(instructions: greetInstructions)
      let reply = try await session.respond(to: "Facts:\n\(facts)\n\nSay hello.", options: GenerationOptions(temperature: 0.9))
      let line = reply.content.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
      return line.isEmpty ? nil : line
    } catch {
      return nil
    }
  }
  #endif
}

/// Sends one request's events.
struct Emitter {
  let id: String
  let send: (AssistantEvent) -> Void

  func tool(_ name: String, _ detail: String) { send(.tool(id: id, name: name, detail: detail)) }
  func action(_ payload: [String: String]) { send(.action(id: id, payload: payload)) }

  /// A whole answer at once.
  func reply(_ text: String) {
    send(.delta(id: id, text: text))
    send(.done(id: id))
  }
}

// MARK: - Helpers shared by the tools and the command reader

nonisolated enum AssistantTools {
  /// An installed app by name, case-insensitively, in the usual places.
  static func findApplication(_ name: String) -> URL? {
    let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
    let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
    var fuzzy: URL?
    for root in roots {
      guard let items = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
      for item in items where item.hasSuffix(".app") {
        let base = String(item.dropLast(4)).lowercased()
        let url = URL(filePath: root).appending(path: item)
        if base == wanted { return url }
        // Fuzzy only on a whole-word prefix, never an arbitrary substring.
        if fuzzy == nil, base.hasPrefix(wanted + " ") || base.hasPrefix(wanted) && wanted.count >= 4 {
          fuzzy = url
        }
      }
    }
    return fuzzy
  }

  @MainActor private static var shortcutNames: [String]?

  /// `shortcuts list`, cached for the run.
  @MainActor static func listShortcuts() -> [String] {
    if let cached = shortcutNames { return cached }
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/shortcuts")
    process.arguments = ["list"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let names = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    shortcutNames = names
    return names
  }

  /// Standard Additions; no Automation permission needed.
  @MainActor static func setVolume(_ percent: Int) -> Bool {
    var error: NSDictionary?
    NSAppleScript(source: "set volume output volume \(percent)")?.executeAndReturnError(&error)
    return error == nil
  }

  struct WebResult: Sendable {
    let title: String
    let snippet: String
    let url: String
  }

  static func decodeEntities(_ html: String) -> String {
    var text = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    for (entity, value) in [("&amp;", "&"), ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
      text = text.replacingOccurrences(of: entity, with: value)
    }
    return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// DuckDuckGo's plain HTML results: titles, snippets and the real URLs.
  @concurrent
  static func fetchWebResults(_ query: String, limit: Int = 5) async -> [WebResult] {
    var parts = URLComponents(string: "https://html.duckduckgo.com/html/")!
    parts.queryItems = [URLQueryItem(name: "q", value: query)]
    guard let url = parts.url else { return [] }
    var request = URLRequest(url: url, timeoutInterval: 8)
    request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
    guard let (data, _) = try? await URLSession.shared.data(for: request), let html = String(data: data, encoding: .utf8) else { return [] }
    let pattern = #"class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>.*?class="result__snippet"[^>]*>(.*?)</a>"#
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
    var out: [WebResult] = []
    for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
      guard let hr = Range(m.range(at: 1), in: html), let tr = Range(m.range(at: 2), in: html), let sr = Range(m.range(at: 3), in: html) else { continue }
      var link = decodeEntities(String(html[hr]))
      if let comps = URLComponents(string: link.hasPrefix("//") ? "https:\(link)" : link),
        let target = comps.queryItems?.first(where: { $0.name == "uddg" })?.value
      {
        link = target
      }
      // Ads come through a y.js redirect.
      if link.contains("duckduckgo.com/y.js") { continue }
      let snippet = decodeEntities(String(html[sr]))
      out.append(WebResult(title: decodeEntities(String(html[tr])), snippet: String(snippet.prefix(280)), url: link))
      if out.count == limit { break }
    }
    return out
  }

  /// Drop any "[Background …]" block the model echoes back.
  static func stripBackground(_ text: String) -> String {
    guard text.hasPrefix("[") else { return text }
    var rest = Substring(text)
    while rest.hasPrefix("[") {
      guard let close = rest.firstIndex(of: "]") else { return "" }
      rest = rest[rest.index(after: close)...].drop(while: \.isWhitespace)
    }
    return String(rest)
  }
}

// MARK: - Command reader (no Apple Intelligence)

/// A small, literal reader for the island's everyday actions, so Macs without
/// the model still open apps, sites and sessions, set timers and the volume,
/// search, and run Shortcuts.
enum CommandReader {
  /// `modelSearches`: the model answers, so "search …" goes to its searchWeb
  /// tool (which reads and answers) instead of opening a browser tab.
  static func run(prompt: String, context: String, emit: Emitter, modelSearches: Bool = false) -> Bool {
    var q = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    for lead in ["hey siri ", "please ", "can you ", "could you ", "would you ", "i want to ", "go ahead and "] where q.hasPrefix(lead) {
      q = String(q.dropFirst(lead.count))
    }
    if q.hasSuffix(" please") { q = String(q.dropLast(7)) }
    func match(_ pattern: String) -> [String]? {
      guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
        let m = re.firstMatch(in: q, range: NSRange(q.startIndex..., in: q))
      else { return nil }
      return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: q).map { String(q[$0]) } ?? "" }
    }

    if let m = match(#"^(?:set (?:a )?)?timer (?:for )?(\d+) ?(m|min|mins|minute|minutes|h|hr|hour|hours)(?: (?:for|to) (.+))?$"#)
      ?? match(#"^remind me in (\d+) ?(m|min|mins|minute|minutes|h|hr|hour|hours)(?: to (.+))?$"#)
    {
      let n = Int(m[1]) ?? 5
      let minutes = max(1, min(720, m[2].hasPrefix("h") ? n * 60 : n))
      emit.tool("startTimer", "Timer · \(minutes) min")
      emit.action(["kind": "timer", "minutes": String(minutes), "label": m[3]])
      emit.reply("Started a \(minutes)-minute timer\(m[3].isEmpty ? "" : " for \(m[3])").")
      return true
    }
    if let m = match(#"^(?:set (?:the )?)?volume (?:to )?(\d+)%?$"#) {
      let v = max(0, min(100, Int(m[1]) ?? 50))
      emit.tool("setVolume", "Volume \(v)%")
      emit.reply(AssistantTools.setVolume(v) ? "Volume set to \(v)%." : "Couldn't change the volume.")
      return true
    }
    if match(#"^(?:mute|mute (?:the )?(?:sound|volume))$"#) != nil {
      emit.tool("setVolume", "Volume 0%")
      emit.reply(AssistantTools.setVolume(0) ? "Muted." : "Couldn't change the volume.")
      return true
    }
    if !modelSearches, let m = match(#"^(?:search(?: the web)?(?: for)?|google|look up) (.+)$"#) {
      emit.tool("searchWeb", "Searching “\(m[1])”")
      var parts = URLComponents(string: "https://www.google.com/search")!
      parts.queryItems = [URLQueryItem(name: "q", value: m[1])]
      if let url = parts.url { NSWorkspace.shared.open(url) }
      emit.reply("Searching the web for \(m[1]).")
      return true
    }
    if let m = match(#"^run (?:the |my )?(?:shortcut )?(.+?)(?: shortcut)?$"#) {
      let names = AssistantTools.listShortcuts()
      if let name = names.first(where: { $0.lowercased() == m[1] }) ?? names.first(where: { $0.lowercased().contains(m[1]) }) {
        emit.tool("runShortcut", "Finding the “\(name)” shortcut")
        emit.action(["kind": "shortcut", "name": name])
        emit.reply("Ready to run \(name) — press Run.")
        return true
      }
    }
    if let m = match(#"^(?:open|launch|start|go to|show) (.+)$"#), m[1].split(separator: " ").count <= 4 {
      // Short names only: a longer request is for the model.
      let target = m[1].hasPrefix("the ") ? String(m[1].dropFirst(4)) : m[1]
      // A session in the snapshot ("- website (Claude Code): …") wins over an app.
      for line in context.split(separator: "\n") {
        guard line.hasPrefix("- "), let paren = line.range(of: " (") else { continue }
        let project = String(line[line.index(line.startIndex, offsetBy: 2)..<paren.lowerBound])
        if project.lowercased() == target || target == "\(project.lowercased()) session" {
          emit.tool("openSession", "Opening \(project)")
          emit.action(["kind": "open", "project": project])
          emit.reply("Opened \(project).")
          return true
        }
      }
      if target.contains("."), !target.contains(" "),
        let url = URL(string: target.contains("://") ? target : "https://\(target)"),
        url.scheme == "https" || url.scheme == "http", url.host != nil
      {
        emit.tool("openWebsite", "Opening \(url.host ?? target)")
        NSWorkspace.shared.open(url)
        emit.reply("Opened \(url.host ?? target).")
        return true
      }
      if let app = AssistantTools.findApplication(target) {
        let name = app.deletingPathExtension().lastPathComponent
        emit.tool("openApp", "Opening \(name)")
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        emit.reply("Opened \(name).")
        return true
      }
    }
    if match(#"^(?:what(?:'s| is) the )?(?:time|date|day)(?: is it)?(?: today| now)?$"#) != nil
      || match(#"^what (?:time|day|date) is it(?: today| now)?$"#) != nil
    {
      emit.reply("It's \(DateFormatter.localizedString(from: .now, dateStyle: .full, timeStyle: .short)).")
      return true
    }
    return false
  }
}

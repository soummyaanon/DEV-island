import Foundation
import IslandCore
import Testing

// Ported from 1.x's zero-config tests, run against temporary directories only.

private func sandbox() throws -> (ZeroConfig, URL) {
  let root = FileManager.default.temporaryDirectory.appending(path: "agent-island-zero-config-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let config = ZeroConfig(home: root.appending(path: "home"), claudeSettings: root.appending(path: "settings.json"), cursorHooks: root.appending(components: "cursor", "hooks.json"))
  return (config, root)
}

private func json(_ url: URL) throws -> OrderedJSON {
  try OrderedJSON(parsing: String(contentsOf: url, encoding: .utf8))
}

@Suite struct OrderedJSONTests {
  @Test func `round-trips exactly like JSON.stringify with two spaces`() throws {
    let text = """
      {
        "zeta": 1.50,
        "alpha": [
          true,
          null,
          "q\\"uote\\n"
        ],
        "empty": {},
        "none": []
      }
      """
    #expect(try OrderedJSON(parsing: text).serialized() == text)
  }

  @Test func `keeps key order and edits in place`() throws {
    var value = try OrderedJSON(parsing: #"{"b":1,"a":2}"#)
    value["b"] = .string("x")
    value["c"] = .bool(true)
    value["a"] = nil
    #expect(value.keys == ["b", "c"])
  }

  @Test func `rejects what doesn't parse`() {
    #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON(parsing: "{ not json") }
  }

  @Test func `compares by content, not order`() throws {
    #expect(try OrderedJSON(parsing: #"{"a":1,"b":2}"#).canonical == OrderedJSON(parsing: #"{"b":2,"a":1}"#).canonical)
  }
}

@Suite struct ClaudeZeroConfigTests {
  @Test func `uses a command bridge for SessionStart, carrying the host app and PID`() throws {
    let (config, root) = try sandbox()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(config.setupClaude() == .installed)
    let handler = try json(config.claudeSettings)["hooks"]?["SessionStart"]?.array?.first?["hooks"]?.array?.first
    #expect(handler?["type"]?.string == "command")
    #expect(handler?["command"]?.string == config.home.appending(components: "bin", "claude-hook.sh").path)
    #expect(handler?["args"] == .array([.string("session-start")]))
    let bridge = try String(contentsOf: config.home.appending(components: "bin", "claude-hook.sh"), encoding: .utf8)
    #expect(bridge.contains("X-App-Bundle-Id: ${__CFBundleIdentifier:-}"))
    #expect(bridge.contains("X-Agent-Pid: ${PPID:-}"))
    #expect(bridge.contains("--data-binary @-"))
    let token = try String(contentsOf: config.home.appending(path: "token"), encoding: .utf8)
    #expect(token.trimmingCharacters(in: .newlines).count == 64)
  }

  @Test func `installs a status line that forwards usage, and removes it cleanly`() throws {
    let (config, root) = try sandbox()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"theme":"dark"}"#.utf8).write(to: config.claudeSettings)
    #expect(config.setupClaude() == .updated)
    let installed = try json(config.claudeSettings)
    #expect(installed["statusLine"] == .object([
      ("type", .string("command")), ("command", .string(config.home.appending(components: "bin", "claude-statusline.sh").path)), ("refreshInterval", .number("10")),
    ]))
    let script = try String(contentsOf: config.home.appending(components: "bin", "claude-statusline.sh"), encoding: .utf8)
    #expect(script.contains("/usage/claude") && script.contains("&!"))
    #expect(config.removeClaude() == .updated)
    let removed = try json(config.claudeSettings)
    #expect(removed["statusLine"] == nil)
    #expect(removed["theme"]?.string == "dark")
  }

  @Test func `wraps the user's own status line and puts it back`() throws {
    let (config, root) = try sandbox()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"statusLine":{"type":"command","command":"~/bin/my-status.sh","padding":1}}"#.utf8).write(to: config.claudeSettings)
    _ = config.setupClaude()
    // Idempotent: a second launch must not save OUR line as "the original".
    #expect(config.setupClaude() == .unchanged)
    let installed = try json(config.claudeSettings)
    #expect(installed["statusLine"]?["padding"] == .number("1"))
    #expect(try String(contentsOf: config.home.appending(path: "statusline-original.cmd"), encoding: .utf8) == "~/bin/my-status.sh")
    _ = config.removeClaude()
    #expect(try json(config.claudeSettings)["statusLine"] == .object([("type", .string("command")), ("command", .string("~/bin/my-status.sh")), ("padding", .number("1"))]))
  }

  @Test func `strips only our hooks, keeping the user's own`() throws {
    let (config, root) = try sandbox()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"echo mine"}]}]}}"#.utf8).write(to: config.claudeSettings)
    #expect(config.setupClaude() == .updated)
    let installed = try json(config.claudeSettings)["hooks"]!.serialized()
    #expect(installed.contains("/events/claude/pre-tool") && installed.contains("echo mine"))
    #expect(config.removeClaude() == .updated)
    let after = try json(config.claudeSettings)["hooks"]?.serialized() ?? ""
    #expect(!after.contains("/events/claude/") && after.contains("echo mine"))
  }

  @Test func `never overwrites settings it can't read, and backs up before writing`() throws {
    let (config, root) = try sandbox()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("{ broken".utf8).write(to: config.claudeSettings)
    #expect(config.setupClaude() == .error)
    #expect(try String(contentsOf: config.claudeSettings, encoding: .utf8) == "{ broken")
    try Data(#"{"theme":"dark"}"#.utf8).write(to: config.claudeSettings)
    _ = config.setupClaude()
    let backups = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains("agent-island-bak") }
    #expect(backups.count == 1)
  }
}

@Suite struct CursorZeroConfigTests {
  @Test func `merges one bridge entry per event, keeps other tools, removes cleanly`() throws {
    let (config, root) = try sandbox()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: config.cursorHooks.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"version":1,"hooks":{"stop":[{"command":"other-tool stop"}]}}"#.utf8).write(to: config.cursorHooks)
    #expect(config.setupCursor() == .updated)
    #expect(config.setupCursor() == .unchanged)
    let merged = try json(config.cursorHooks)
    #expect(merged["hooks"]?.keys.count == HookInstaller.cursorEvents.count)
    #expect(merged["hooks"]?["stop"]?.array?.count == 2)
    #expect(config.removeCursor() == .updated)
    #expect(try json(config.cursorHooks)["hooks"] == .object([("stop", .array([.object([("command", .string("other-tool stop"))])]))]))
  }
}

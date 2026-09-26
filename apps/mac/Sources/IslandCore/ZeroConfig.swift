import Foundation

/// The files behind Zero Config: the shared token, our bridge scripts, and
/// Claude's and Cursor's config, merged with `HookInstaller`'s rules.
public struct ZeroConfig: Sendable {
  public var home: URL
  public var claudeSettings: URL
  public var cursorHooks: URL

  public init(home: URL, claudeSettings: URL, cursorHooks: URL) {
    self.home = home
    self.claudeSettings = claudeSettings
    self.cursorHooks = cursorHooks
  }

  /// The real locations, with 1.x's overrides (AGENT_ISLAND_HOME, …).
  public static var standard: ZeroConfig {
    let env = ProcessInfo.processInfo.environment
    let user = URL.homeDirectory
    return ZeroConfig(
      home: env["AGENT_ISLAND_HOME"].map { URL(filePath: $0) } ?? user.appending(path: ".agent-island"),
      claudeSettings: env["AGENT_ISLAND_CLAUDE_SETTINGS"].map { URL(filePath: $0) } ?? user.appending(components: ".claude", "settings.json"),
      cursorHooks: env["AGENT_ISLAND_CURSOR_HOOKS"].map { URL(filePath: $0) } ?? user.appending(components: ".cursor", "hooks.json")
    )
  }

  var paths: HookInstaller.Paths { HookInstaller.Paths(home: home.path) }
  private var files: FileManager { .default }

  /// The shared token, created (0600) on first run. Adapters send it back.
  @discardableResult
  public func ensureToken() throws -> String {
    let url = home.appending(path: "token")
    if let existing = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
      return existing
    }
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
    let token = bytes.map { String(format: "%02x", $0) }.joined()
    try files.createDirectory(at: home, withIntermediateDirectories: true)
    try Data((token + "\n").utf8).write(to: url, options: .atomic)
    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return token
  }

  private func writeScript(_ path: String, _ contents: String) throws {
    let url = URL(filePath: path)
    try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if (try? String(contentsOf: url, encoding: .utf8)) != contents {
      try Data(contents.utf8).write(to: url, options: .atomic)
    }
    try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
  }

  /// Reads a JSON config; nil when missing, throws when it doesn't parse
  /// (never overwrite what we can't read).
  private func read(_ url: URL) throws -> OrderedJSON? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try OrderedJSON(parsing: String(decoding: data, as: UTF8.self))
  }

  /// A timestamped backup, then the new contents.
  private func write(_ json: OrderedJSON, to url: URL, backup: Bool) throws {
    if backup {
      let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: ".", with: "-")
      try? files.copyItem(at: url, to: URL(filePath: url.path + ".agent-island-bak.\(stamp)"))
    } else {
      try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    try Data((json.serialized() + "\n").utf8).write(to: url, options: .atomic)
  }

  // MARK: Claude Code

  public func setupClaude() -> HookInstaller.Result {
    do {
      let token = try ensureToken()
      try writeScript(paths.claudeBridge, HookInstaller.claudeBridgeScript)
      try writeScript(paths.statusScript, HookInstaller.statusLineScript)
      let existing: OrderedJSON?
      do { existing = try read(claudeSettings) } catch { return .error }
      let before = existing ?? .object([])
      var saved: OrderedJSON?
      let after = HookInstaller.mergeClaude(before, token: token, paths: paths, savedStatusLine: &saved)
      // The user's own status line: kept for removal, and run by our script.
      if !HookInstaller.isOurStatusLine(before["statusLine"], paths: paths) {
        let savedURL = URL(filePath: paths.savedStatusLine), commandURL = URL(filePath: paths.savedStatusCommand)
        if let saved {
          try Data((saved.serialized() + "\n").utf8).write(to: savedURL, options: .atomic)
          try Data((saved["command"]?.string ?? "").utf8).write(to: commandURL, options: .atomic)
        } else {
          try? files.removeItem(at: savedURL)
          try? files.removeItem(at: commandURL)
        }
      }
      guard after.canonical != before.canonical || existing == nil else { return .unchanged }
      try write(after, to: claudeSettings, backup: existing != nil)
      return existing == nil ? .installed : .updated
    } catch {
      return .error
    }
  }

  public func removeClaude() -> HookInstaller.Result {
    do {
      guard let before = try read(claudeSettings) else { return .unchanged }
      let saved = try? read(URL(filePath: paths.savedStatusLine))
      let after = HookInstaller.removeClaude(before, paths: paths, savedStatusLine: saved ?? nil)
      if HookInstaller.isOurStatusLine(before["statusLine"], paths: paths) {
        try? files.removeItem(at: URL(filePath: paths.savedStatusLine))
        try? files.removeItem(at: URL(filePath: paths.savedStatusCommand))
      }
      guard after.canonical != before.canonical else { return .unchanged }
      try write(after, to: claudeSettings, backup: true)
      return .updated
    } catch {
      return .error
    }
  }

  // MARK: Cursor

  public func setupCursor() -> HookInstaller.Result {
    do {
      try ensureToken()
      try writeScript(paths.cursorBridge, HookInstaller.cursorBridgeScript)
      let existing: OrderedJSON?
      do { existing = try read(cursorHooks) } catch { return .error }
      let before = existing ?? .object([])
      let after = HookInstaller.mergeCursor(before, paths: paths)
      guard after.canonical != before.canonical || existing == nil else { return .unchanged }
      try write(after, to: cursorHooks, backup: existing != nil)
      return existing == nil ? .installed : .updated
    } catch {
      return .error
    }
  }

  public func removeCursor() -> HookInstaller.Result {
    do {
      guard let before = try read(cursorHooks) else { return .unchanged }
      let after = HookInstaller.removeCursor(before, paths: paths)
      guard after.canonical != before.canonical else { return .unchanged }
      try write(after, to: cursorHooks, backup: true)
      return .updated
    } catch {
      return .error
    }
  }
}

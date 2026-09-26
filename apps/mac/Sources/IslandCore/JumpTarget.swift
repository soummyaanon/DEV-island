import Foundation

/// Where "jump back" goes for a session, decided without side effects (1.x's
/// `jump-back.ts`). The app carries it out.
public enum JumpTarget: Equatable, Sendable {
  /// The exact iTerm2 session, by its AppleScript id.
  case iTerm(sessionId: String)
  /// This project's own window in a multi-window editor: `open -b <bundle> <cwd>`.
  case editorWindow(bundleId: String, cwd: String)
  /// VS Code or Cursor, whichever is running (their terminals look the same).
  case vsCodeFamily(cwd: String)
  /// Bring an app forward by bundle id.
  case app(bundleId: String)
  /// Bring an app forward by name (an unknown TERM_PROGRAM).
  case appNamed(String)
  /// No idea where it lives.
  case none

  public static let cursorBundleId = "com.todesktop.230313mzl4w4u92"
  public static let vsCodeBundleId = "com.microsoft.VSCode"

  /// TERM_PROGRAM → bundle id.
  static let terminals: [String: String] = [
    "iTerm.app": "com.googlecode.iterm2",
    "Apple_Terminal": "com.apple.Terminal",
    "WarpTerminal": "dev.warp.Warp-Stable",
    "ghostty": "com.mitchellh.ghostty",
    "WezTerm": "com.github.wez.wezterm",
    "vscode": vsCodeBundleId,
    "Cursor": cursorBundleId,
  ]

  /// Editors that hold many projects in separate windows: activating the app
  /// alone lands on whichever window is frontmost.
  static let editors: Set<String> = [vsCodeBundleId, cursorBundleId]

  public init(_ session: SessionSnapshot) {
    let term = session.metaString("term_program") ?? ""
    let safeId = /^[\w:.-]+$/
    let safeTerm = /^[\w.]+$/

    if term == "iTerm.app", let id = session.metaString("iterm_session_id"), id.wholeMatch(of: safeId) != nil {
      // ITERM_SESSION_ID is "w0t0p0:GUID"; AppleScript knows the GUID.
      self = .iTerm(sessionId: id.split(separator: ":").last.map(String.init) ?? id)
      return
    }
    // The host app's own bundle id beats TERM_PROGRAM: Claude in Cursor's
    // terminal says TERM_PROGRAM=vscode, but this points at Cursor.
    if let host = session.metaString("app_bundle_id"), host.wholeMatch(of: safeId) != nil {
      self = Self.editors.contains(host) ? .editorWindow(bundleId: host, cwd: session.cwd) : .app(bundleId: host)
      return
    }
    // Cursor's own agent comes from IDE hooks, with no terminal at all.
    if term.isEmpty && session.agent == .cursor {
      self = .editorWindow(bundleId: Self.cursorBundleId, cwd: session.cwd)
      return
    }
    if term == "vscode" {
      self = .vsCodeFamily(cwd: session.cwd)
      return
    }
    if let bundleId = Self.terminals[term] {
      self = .app(bundleId: bundleId)
    } else if !term.isEmpty, term.wholeMatch(of: safeTerm) != nil {
      self = .appNamed(term)
    } else {
      self = .none
    }
  }

  /// Which editor a `.vsCodeFamily` jump opens: VS Code when it runs (or when
  /// neither can be seen), Cursor when only Cursor runs.
  public static func vsCodeFamilyBundle(vsCodeRunning: Bool, cursorRunning: Bool) -> String {
    !vsCodeRunning && cursorRunning ? cursorBundleId : vsCodeBundleId
  }
}

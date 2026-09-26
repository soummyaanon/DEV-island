import AppKit
import IslandCore

/// Brings a session's terminal or editor to the front: the exact iTerm2 tab,
/// this project's own window in VS Code or Cursor, or the terminal app.
/// IslandCore's `JumpTarget` decides where; this carries it out.
enum JumpBack {
  static func jump(to session: SessionSnapshot) {
    let target = JumpTarget(session)
    log("jump \(session.key) → \(target)")
    switch target {
    case let .iTerm(sessionId):
      // The id passed `JumpTarget`'s safe-character check, so it can't break the script.
      osascript("""
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if (id of s) is "\(sessionId)" then
                  tell w to select
                  tell t to select
                  activate
                  return
                end if
              end repeat
            end repeat
          end repeat
          activate
        end tell
        """)
    case let .editorWindow(bundleId, cwd):
      openWindow(bundleId: bundleId, cwd: cwd)
    case let .vsCodeFamily(cwd):
      let running = { (id: String) in !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }
      let bundleId = JumpTarget.vsCodeFamilyBundle(
        vsCodeRunning: running(JumpTarget.vsCodeBundleId),
        cursorRunning: running(JumpTarget.cursorBundleId)
      )
      openWindow(bundleId: bundleId, cwd: cwd)
    case let .app(bundleId):
      activate(bundleId: bundleId)
    case let .appNamed(name):
      osascript("tell application \"\(name)\" to activate")
    case .none:
      log("no known terminal for \(session.key)")
    }
  }

  /// `open -b <bundle> <folder>`: the editor raises the window already showing
  /// that folder (or opens it). Needs no Accessibility grant.
  private static func openWindow(bundleId: String, cwd: String) {
    guard !cwd.isEmpty, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
      activate(bundleId: bundleId)
      return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.open([URL(filePath: cwd)], withApplicationAt: app, configuration: configuration) { _, error in
      guard let error else { return }
      Task { @MainActor in
        log("open failed: \(error.localizedDescription); activating instead")
        activate(bundleId: bundleId)
      }
    }
  }

  /// Launch Services brings it forward (launching it if needed), with no Apple Events.
  private static func activate(bundleId: String) {
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
      log("no app for \(bundleId)")
      return
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.openApplication(at: app, configuration: configuration)
  }

  private static func osascript(_ script: String) {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    process.terminationHandler = { finished in
      guard finished.terminationStatus != 0 else { return }
      Task { @MainActor in log("osascript exited \(finished.terminationStatus)") }
    }
    do { try process.run() } catch { log("osascript failed: \(error.localizedDescription)") }
  }

  /// Mirrored to ~/.agent-island/app.log, like 1.x, so "clicked and nothing
  /// happened" can be traced after the fact.
  static func log(_ message: String) {
    Log.app.notice("[jump] \(message, privacy: .public)")
    let line = "\(Date.now.ISO8601Format()) [jump] \(message)\n"
    let url = DaemonClient.home.appending(path: "app.log")
    guard let handle = try? FileHandle(forWritingTo: url) else {
      try? line.write(to: url, atomically: true, encoding: .utf8)
      return
    }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data(line.utf8))
  }
}

import Foundation
import IslandCore

/// The first launch after an update from 1.x (see `Migration`). Only the
/// shipped app does this: the side-by-side dev build must never stop a
/// running 1.x's daemon or tidy its folder.
enum MigrationRunner {
  static func run(port: UInt16) async {
    guard Bundle.main.bundleIdentifier == "com.agentisland.app" else { return }
    await Task.detached { stopElectronDaemon(port: port) }.value
    tidyUserData()
  }

  /// 1.x ran its daemon as a child process; if it's still holding the port,
  /// stop it so ours can take over.
  nonisolated private static func stopElectronDaemon(port: UInt16) {
    let pids = run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
      .split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    for pid in pids where Migration.isElectronDaemon(command: run("/bin/ps", ["-o", "command=", "-p", String(pid)])) {
      Log.app.notice("stopping 1.x's daemon (pid \(pid))")
      kill(pid, SIGTERM)
      for _ in 0 ..< 20 where kill(pid, 0) == 0 { usleep(100_000) }
    }
  }

  private static func tidyUserData() {
    let folder = IslandSettings.userData
    let marker = folder.appending(path: Migration.marker)
    let files = FileManager.default
    guard files.fileExists(atPath: folder.path), !files.fileExists(atPath: marker.path) else { return }
    var removed = 0
    for name in Migration.electronLeftovers {
      let item = folder.appending(path: name)
      if (try? files.removeItem(at: item)) != nil { removed += 1 }
    }
    try? Data().write(to: marker)
    Log.app.notice("moved in from 1.x: removed \(removed) Electron leftovers")
  }

  nonisolated private static func run(_ tool: String, _ arguments: [String]) -> String {
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
}

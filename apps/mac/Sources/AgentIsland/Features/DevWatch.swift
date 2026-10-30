import Foundation
import IslandCore
import Observation

/// What the developer strip shows besides session meta: dev servers that are
/// listening, and each session's uncommitted changes. Sampled every few
/// seconds while the panel is open, and never while it's closed.
@Observable
final class DevWatch {
  private(set) var servers: [DevServer] = []
  /// `git diff --shortstat` per session folder.
  private(set) var changes: [String: DiffStat] = [:]

  @ObservationIgnored private var loop: Task<Void, Never>?
  /// Each folder's working directory, remembered: `lsof` for it only runs
  /// when a new server appears.
  @ObservationIgnored private var cwds: [Int: String] = [:]

  /// While the panel is open; Low Power Mode samples far less often.
  static let interval: Duration = .seconds(4)
  static let lowPowerInterval: Duration = .seconds(10)

  /// Starts sampling `sessions`, or keeps the loop already running. The
  /// controller stops it the moment the panel closes or the Mac is locked.
  func start(sessions: @escaping () -> [SessionSnapshot]) {
    guard loop == nil else { return }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refresh(sessions())
        let slow = ProcessInfo.processInfo.isLowPowerModeEnabled
        do { try await Task.sleep(for: slow ? Self.lowPowerInterval : Self.interval) } catch { return }
      }
    }
  }

  func stop() {
    loop?.cancel()
    loop = nil
  }

  func refresh(_ sessions: [SessionSnapshot]) async {
    let roots = sessions.compactMap { session -> (key: String, pid: Int)? in
      switch session.meta["pid"] {
      case let .number(pid)? where pid > 1: (session.key, Int(pid))
      case let .string(text)?: Int(text).flatMap { $0 > 1 ? (session.key, $0) : nil }
      default: nil
      }
    }
    let folders = Array(Set(sessions.map(\.cwd).filter { $0.hasPrefix("/") })).prefix(8)
    let ignoring: Set<Int> = [Int(ProcessInfo.processInfo.processIdentifier), DaemonClient.port]
    let sample = await Self.sample(roots: roots, folders: Array(folders), ignoring: ignoring, known: cwds)
    cwds = sample.cwds
    if sample.servers != servers { servers = sample.servers }
    if sample.changes != changes { changes = sample.changes }
  }

  /// Stops a server: SIGTERM, the polite one. It's gone on the next sample.
  func stop(_ server: DevServer) {
    guard server.pid > 1, server.pid != Int(ProcessInfo.processInfo.processIdentifier) else { return }
    kill(pid_t(server.pid), SIGTERM)
    servers.removeAll { $0.pid == server.pid }
  }

  @concurrent
  private static func sample(
    roots: [(key: String, pid: Int)], folders: [String], ignoring: Set<Int>, known: [Int: String]
  ) async -> (servers: [DevServer], changes: [String: DiffStat], cwds: [Int: String]) {
    let listeners = DevServers.parseListening(run("/usr/sbin/lsof", ["+c", "0", "-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]))
    // Folders only for servers not seen before; gone ones are forgotten.
    let live = Set(listeners.map(\.pid))
    var cwds = known.filter { live.contains($0.key) }
    let fresh = live.subtracting(cwds.keys).map(String.init).joined(separator: ",")
    if !fresh.isEmpty { cwds.merge(DevServers.parseCwds(run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", fresh, "-F", "pn"]))) { _, new in new } }
    // The process tree only when there's something to match it against.
    let rows = roots.isEmpty || listeners.isEmpty ? [] : ProcTotals.parse(run("/bin/ps", ["-axo", "pid,ppid,%cpu,rss"]))
    let servers = DevServers.servers(listeners, cwds: cwds, sessions: roots, rows: rows, ignoring: ignoring)
    var changes: [String: DiffStat] = [:]
    for folder in folders {
      // Against HEAD, so staged changes count too; a repo with no commits yet falls back.
      var output = run("/usr/bin/git", ["-C", folder, "diff", "--shortstat", "HEAD"], ok: true)
      if output == nil { output = run("/usr/bin/git", ["-C", folder, "diff", "--shortstat"], ok: true) }
      if let output { changes[folder] = DiffStat.parse(output) }
    }
    return (servers, changes, cwds)
  }

  /// A command's output, given up on after two seconds. With `ok`, nil when it fails.
  nonisolated private static func run(_ path: String, _ arguments: [String], ok: Bool) -> String? {
    let process = Process()
    process.executableURL = URL(filePath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: watchdog)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    watchdog.cancel()
    if ok, process.terminationStatus != 0 { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  nonisolated private static func run(_ path: String, _ arguments: [String]) -> String {
    run(path, arguments, ok: false) ?? ""
  }
}

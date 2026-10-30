import Foundation

/// A local server listening for connections: what the island's Servers row
/// shows, so a dev server an agent started is one click from the browser.
public struct DevServer: Equatable, Sendable, Identifiable {
  public var port: Int
  public var pid: Int
  public var command: String
  /// The folder it runs in, by name ("website"), when known.
  public var project: String?
  /// The agent session that started it, when it's one of theirs.
  public var sessionKey: String?

  public var id: Int { port }
  public var address: String { "localhost:\(port)" }
  public var url: URL? { URL(string: "http://localhost:\(port)") }

  public init(port: Int, pid: Int, command: String, project: String? = nil, sessionKey: String? = nil) {
    self.port = port
    self.pid = pid
    self.command = command
    self.project = project
    self.sessionKey = sessionKey
  }
}

public enum DevServers {
  /// One listening socket, from `lsof`.
  public struct Listener: Equatable, Sendable {
    public var pid: Int
    public var command: String
    public var port: Int

    public init(pid: Int, command: String, port: Int) {
      self.pid = pid
      self.command = command
      self.port = port
    }
  }

  /// Runtimes and tools that serve a project while you develop it. Anything
  /// else listening (system daemons, chat apps, the island) stays off the row,
  /// unless an agent started it.
  public static let runtimes: Set<String> = [
    "node", "bun", "deno", "python", "python3", "ruby", "java", "php", "go", "dotnet", "beam.smp", "elixir",
    "uvicorn", "gunicorn", "hypercorn", "flask", "rails", "puma", "vite", "next-server", "esbuild", "webpack",
    "cargo", "air", "hugo", "jekyll", "caddy", "http-server", "serve", "wrangler", "workerd", "astro", "remix",
    "nuxt", "streamlit", "jupyter", "jupyter-lab", "postgres", "redis-server", "mongod", "mysqld",
  ]

  /// Parses `lsof -nP -iTCP -sTCP:LISTEN -F pcn` (+c 0 for whole names).
  /// One entry per port; privileged ports (< 1024) are never dev servers.
  public static func parseListening(_ output: String) -> [Listener] {
    var out: [Listener] = []
    var seen = Set<Int>()
    var pid: Int?
    var command = ""
    for line in output.split(separator: "\n") {
      guard let tag = line.first else { continue }
      let value = line.dropFirst()
      switch tag {
      case "p":
        pid = Int(value)
        command = ""
      case "c":
        command = String(value)
      case "n":
        guard let pid, let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]),
          port >= 1024, !seen.contains(port)
        else { continue }
        seen.insert(port)
        out.append(Listener(pid: pid, command: command, port: port))
      default:
        continue
      }
    }
    return out
  }

  /// Parses `lsof -a -d cwd -p … -F pn`: each process's working directory.
  public static func parseCwds(_ output: String) -> [Int: String] {
    var out: [Int: String] = [:]
    var pid: Int?
    for line in output.split(separator: "\n") {
      guard let tag = line.first else { continue }
      if tag == "p" { pid = Int(line.dropFirst()) }
      if tag == "n", let pid { out[pid] = String(line.dropFirst()) }
    }
    return out
  }

  /// The servers worth a chip: whatever an agent's process tree is
  /// listening on, then the user's own dev servers. Agents' first, then by port.
  public static func servers(
    _ listeners: [Listener], cwds: [Int: String], sessions: [(key: String, pid: Int)], rows: [ProcTotals.Row], ignoring: Set<Int>
  ) -> [DevServer] {
    let parents = Dictionary(rows.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { first, _ in first })
    let roots = Dictionary(sessions.map { ($0.pid, $0.key) }, uniquingKeysWith: { first, _ in first })
    /// The session whose process tree holds `pid`, walking up at most 64 parents.
    func owner(_ pid: Int) -> String? {
      var current = pid
      for _ in 0..<64 {
        if let key = roots[current] { return key }
        guard let parent = parents[current], parent > 1, parent != current else { return nil }
        current = parent
      }
      return nil
    }
    let found = listeners.compactMap { listener -> DevServer? in
      guard !ignoring.contains(listener.pid), !ignoring.contains(listener.port) else { return nil }
      let key = owner(listener.pid)
      let name = listener.command.split(separator: "/").last.map(String.init) ?? listener.command
      guard key != nil || runtimes.contains(name.lowercased()) else { return nil }
      let project = cwds[listener.pid].flatMap { cwd -> String? in
        let last = cwd.split(separator: "/").last.map(String.init)
        // A server run from the home folder or root names nothing useful.
        return cwd == NSHomeDirectory() || cwd == "/" ? nil : last
      }
      return DevServer(port: listener.port, pid: listener.pid, command: name, project: project, sessionKey: key)
    }
    return found.sorted { a, b in
      (a.sessionKey != nil) != (b.sessionKey != nil) ? a.sessionKey != nil : a.port < b.port
    }
  }
}

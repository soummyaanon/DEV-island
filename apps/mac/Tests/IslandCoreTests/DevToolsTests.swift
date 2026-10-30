import Foundation
import IslandCore
import Testing

private func json(_ text: String) -> JSONValue { JSONValue(json: Data(text.utf8))! }

@Suite struct RememberTests {
  @Test func `uses Claude's own suggestion when it has one`() throws {
    let suggestions = json(#"[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm run lint"}],"behavior":"allow","destination":"localSettings"}]"#)
    let rule = try #require(Remember.rule(tool: "Bash", input: json(#"{"command":"npm run lint"}"#), suggestions: suggestions))
    #expect(rule.permissions == suggestions)
    #expect(rule.label == "Always allow “npm run lint” in this project")
  }

  @Test func `ignores suggestions that widen directories or change the mode`() {
    let suggestions = json(#"[{"type":"setMode","mode":"acceptEdits","destination":"session"},{"type":"addDirectories","directories":["/"],"destination":"session"}]"#)
    let rule = Remember.rule(tool: "Bash", input: json(#"{"command":"ls -la"}"#), suggestions: suggestions)
    #expect(rule?.permissions == json(#"[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"ls -la"}],"behavior":"allow","destination":"localSettings"}]"#))
  }

  @Test(arguments: ["npm test && rm -rf dist", "cat a | grep b", "echo $(whoami)", "make; make install", "ls > out.txt"])
  func `never remembers a compound shell command on its own`(command: String) {
    #expect(Remember.rule(tool: "Bash", input: .object(["command": .string(command)]), suggestions: nil) == nil)
  }

  @Test func `remembers a web fetch by its domain`() {
    let rule = Remember.rule(tool: "WebFetch", input: json(#"{"url":"https://docs.swift.org/x"}"#), suggestions: nil)
    #expect(rule?.label == "Always allow docs.swift.org in this project")
  }

  @Test func `edits are allowed for this session only`() {
    let rule = Remember.rule(tool: "Edit", input: json(#"{"file_path":"/a.swift"}"#), suggestions: nil)
    #expect(rule?.permissions.array?.first?["destination"]?.string == "session")
  }

  @Test func `never remembers a plan to review`() {
    #expect(Remember.rule(tool: "ExitPlanMode", input: nil, suggestions: nil) == nil)
  }
}

@Suite struct DevCheckTests {
  @Test(arguments: [
    ("pnpm test", DevCheck.test), ("npm run test:unit", .test), ("swift test --parallel", .test), ("pytest -q", .test),
    ("npm run build && npm test", .test), ("npx tsc --noEmit", .typecheck), ("pnpm lint", .lint), ("cargo clippy", .lint),
    ("swift build -c release", .build), ("npm run build", .build), ("make", .build),
  ])
  func `knows what a command checks`(command: String, kind: DevCheck) {
    #expect(DevCheck.kind(of: command) == kind)
  }

  @Test(arguments: ["ls -la", "git status", "cat README.md", "npm install", "attestation"])
  func `everything else is not a check`(command: String) {
    #expect(DevCheck.kind(of: command) == nil)
  }
}

@Suite struct SessionStatsTests {
  @Test func `reads context and cost from the status line`() throws {
    let body = json(#"{"session_id":"s1","cost":{"total_cost_usd":1.23456},"context_window":{"used_percentage":82.4,"context_window_size":200000}}"#)
    let stats = try #require(SessionStats.meta(from: body))
    #expect(stats.sessionId == "s1")
    #expect(stats.meta["cost_usd"] == .number(1.23))
    #expect(stats.meta["context_pct"] == .number(82.4))
    #expect(stats.meta["context_size"] == .number(200_000))
  }

  @Test func `nothing to say, nothing merged`() {
    #expect(SessionStats.meta(from: json(#"{"session_id":"s1","context_window":{"current_usage":null}}"#)) == nil)
    #expect(SessionStats.meta(from: json(#"{"cost":{"total_cost_usd":1}}"#)) == nil)
  }
}

@Suite struct DiffStatTests {
  @Test func `parses git's short stat, singular and plural`() {
    #expect(DiffStat.parse(" 3 files changed, 156 insertions(+), 23 deletions(-)\n") == DiffStat(files: 3, added: 156, removed: 23))
    #expect(DiffStat.parse(" 1 file changed, 1 insertion(+)\n") == DiffStat(files: 1, added: 1, removed: 0))
    #expect(DiffStat.parse("").isEmpty)
  }
}

@Suite struct DevServerTests {
  let lsof = """
    p501
    cnode
    f23
    n*:3000
    f24
    n[::1]:3000
    p777
    cControlCenter
    f9
    n*:7000
    p900
    cpython3
    f5
    n127.0.0.1:8000
    p44
    cpostgres
    f6
    n127.0.0.1:631
    """

  @Test func `one entry per port, never a privileged one`() {
    let listeners = DevServers.parseListening(lsof)
    #expect(listeners.map(\.port) == [3000, 7000, 8000])
    #expect(listeners.first == DevServers.Listener(pid: 501, command: "node", port: 3000))
  }

  @Test func `shows agents' servers first, then known dev runtimes, never system apps`() {
    let rows = ProcTotals.parse("  PID  PPID  %CPU   RSS\n  900   450   0.0   100\n  450   400   0.0   100\n")
    let servers = DevServers.servers(
      DevServers.parseListening(lsof),
      cwds: [501: "/Users/me/web", 900: "/Users/me/api"],
      sessions: [(key: "claude-code:s1", pid: 400)],
      rows: rows,
      ignoring: []
    )
    #expect(servers.map(\.port) == [8000, 3000])
    #expect(servers.first?.sessionKey == "claude-code:s1")
    #expect(servers.last?.project == "web")
  }

  @Test func `never lists the island itself`() {
    let servers = DevServers.servers(DevServers.parseListening(lsof), cwds: [:], sessions: [], rows: [], ignoring: [501, 8000])
    #expect(servers.isEmpty)
  }
}

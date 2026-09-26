import Foundation
import IslandCore
import Testing

// Ported from 1.x's deep-link, haptics, proc-stats and settings tests, plus
// the sound scores.

@Suite struct DeepLinkTests {
  private func link(_ text: String) -> DeepLink? { URL(string: text).flatMap(DeepLink.init) }

  @Test func `focus on with a name, off without`() {
    #expect(link("agent-island://focus/on?name=Work") == .focus(active: true, name: "Work"))
    #expect(link("agent-island://focus/off") == .focus(active: false, name: nil))
  }

  @Test func `decodes and trims the name, capping its length`() {
    #expect(link("agent-island://focus/on?name=Deep%20Work%20") == .focus(active: true, name: "Deep Work"))
    guard case let .focus(_, name)? = link("agent-island://focus/on?name=\(String(repeating: "x", count: 100))") else {
      Issue.record("not a focus link")
      return
    }
    #expect(name?.count == 40)
  }

  @Test func `toggle and settings`() {
    #expect(link("agent-island://toggle") == .toggle)
    #expect(link("agent-island://settings/") == .settings)
  }

  @Test(arguments: ["https://focus/on", "agent-island://focus/maybe", "agent-island://quit", "agent-island://toggle/now"])
  func `rejects other schemes, hosts and paths`(text: String) {
    #expect(link(text) == nil)
  }

  @Test func `the links Settings shows parse`() {
    #expect(link(DeepLink.focusOn) == .focus(active: true, name: "Work"))
    #expect(link(DeepLink.focusOff) == .focus(active: false, name: nil))
  }
}

@Suite struct HapticTests {
  @Test func `the most urgent pattern in a batch wins`() {
    #expect(Haptic.winner([.success, .failure, .tick]) == .failure)
    #expect(Haptic.winner([.whisper, .commit]) == .commit)
    #expect(Haptic.winner([Haptic]()) == nil)
  }

  @Test func `only interaction taps get through a Focus`() {
    #expect(Haptic.allCases.filter(\.isInteraction) == [.commit, .tick])
  }

  @Test func `rumble is set apart from attention only by its spacing`() {
    #expect(Haptic.rumble.rhythm.map(\.tap) == Haptic.attention.rhythm.map(\.tap))
    #expect(Haptic.rumble.rhythm[0].gapAfter > Haptic.attention.rhythm[0].gapAfter)
  }
}

@Suite struct ProcStatsTests {
  let ps = """
      PID  PPID  %CPU    RSS
        1     0   0.1   1024
      100     1  50.0 102400
      101   100  90.5  51200
      102   101  10.0  10240
      200     1   5.0   2048
    garbage line
    """

  @Test func `sums a whole process tree`() {
    let rows = ProcTotals.parse(ps)
    #expect(rows.count == 5)
    #expect(ProcTotals.subtree(rows, root: 100) == ProcTotals(cpu: 151, rssMB: 160, processes: 3))
  }

  @Test func `a vanished root is nothing, not a stranger's load`() {
    #expect(ProcTotals.subtree(ProcTotals.parse(ps), root: 999) == nil)
  }

  @Test func `warms with load`() {
    #expect(ProcTotals(cpu: 34, rssMB: 0, processes: 1).heat == .cool)
    #expect(ProcTotals(cpu: 180, rssMB: 0, processes: 1).heat == .hot)
    #expect(ProcTotals(cpu: 300, rssMB: 0, processes: 1).heat == .burning)
  }
}

@Suite struct FullSettingsTests {
  @Test func `round-trips every key and keeps ones it doesn't know`() throws {
    let stored = #"{"settingsVersion":3,"soundTheme":"zen","soundOverrides":{"approve":"glass","bogus":"zen"},"weather":true,"weatherUnits":"f","textSize":"larger","glass":true,"future":{"x":1}}"#
    let settings = IslandSettings(json: Data(stored.utf8))
    #expect(settings.soundTheme == .zen)
    #expect(settings.soundOverrides == [.approve: .glass])
    #expect(settings.theme(for: .approve) == .glass && settings.theme(for: .success) == .zen)
    #expect(settings.weather && settings.weatherUnits == .f && settings.textSize == .larger && settings.glass)
    let again = IslandSettings(json: settings.json())
    #expect(again == settings)
    let raw = try JSONDecoder().decode([String: JSONValue].self, from: settings.json())
    #expect(raw["future"] == .object(["x": .number(1)]))
    #expect(raw["settingsVersion"] == .number(3))
  }

  @Test func `a v2 file's glass was only the old default`() {
    #expect(!IslandSettings(json: Data(#"{"settingsVersion":2,"glass":true}"#.utf8)).glass)
  }
}

@Suite struct SoundScoreTests {
  @Test(arguments: SoundTheme.allCases.filter { $0 != .anime })
  func `every synthesized theme scores every event`(theme: SoundTheme) {
    for event in SoundEvent.allCases {
      let score = SoundScore.score(theme, event)
      #expect(score?.voices.isEmpty == false)
    }
  }

  @Test func `the anime pack plays files`() {
    #expect(SoundScore.score(.anime, .success) == nil)
    #expect(SoundScore.file(.approve).name == "fahhhhh")
  }

  @Test func `renders 8-bit done as a bounded rising arpeggio`() {
    let score = SoundScore.score(.eightBit, .success)!
    #expect(score.voices.map(\.from) == [523.25, 659.25, 783.99, 1046.5])
    let samples = score.render(rate: 8000)
    #expect(samples.count == Int((score.length * 8000).rounded(.up)))
    #expect(samples.allSatisfy { abs($0) <= 0.2 })
    #expect(samples.contains { abs($0) > 0.03 })
  }
}

@Suite struct TrayTitleTests {
  @Test func `shows attention, then work, then just the island`() {
    let now = Date.now
    func s(_ state: SessionState, action: Bool = false) -> SessionSnapshot {
      SessionSnapshot(key: UUID().uuidString, agent: .codex, sessionId: "x", cwd: "/a", state: state, title: "", requiresAction: action, startedAt: now, updatedAt: now)
    }
    #expect(TrayTitle.title([s(.working), s(.waitingForApproval, action: true)]) == " 🏝 ⚠ 1")
    #expect(TrayTitle.title([s(.working), s(.starting), s(.done)]) == " 🏝 2")
    #expect(TrayTitle.title([s(.done)]) == " 🏝")
  }
}

@Suite struct UpdateTests {
  @Test func `compares versions numerically, with or without a v`() {
    #expect(Updates.isNewer("v0.2.0", than: "0.1.9"))
    #expect(Updates.isNewer("1.10.0", than: "1.9.3"))
    #expect(!Updates.isNewer("1.9.0", than: "1.9.0"))
    #expect(!Updates.isNewer("1.8.9", than: "v1.9"))
    #expect(Updates.isNewer("2", than: "1.9.9"))
  }

  @Test func `the installer only swaps after a successful copy, and quotes its paths`() {
    let script = Updates.installerScript(dmg: "/tmp/it's.dmg", app: "/Applications/Agent Island.app")
    #expect(script.contains(#"DMG='/tmp/it'\''s.dmg'"#))
    #expect(script.contains(#"if ditto "$NEW" "$APP.new"; then"#))
    #expect(script.contains(#"open "$APP""#))
  }
}

@Suite struct SettingsFileTests {
  /// 1.x's own file, as it writes it.
  let file = """
    {
      "settingsVersion": 3,
      "agents": {
        "claude-code": true,
        "codex": true,
        "cursor": true
      },
      "sounds": true,
      "soundTheme": "soft",
      "soundOverrides": {},
      "customSounds": {},
      "customSoundNames": {},
      "tray": false,
      "updateCheck": true,
      "haptics": true,
      "textSize": "default",
      "weather": false,
      "weatherLocation": "",
      "weatherUnits": "auto",
      "openWith": "hover",
      "sessionView": "compact",
      "glass": false,
      "battery": true,
      "procStats": true,
      "respectFocus": true,
      "assistant": true,
      "assistantModel": true,
      "voice": true,
      "speakReplies": true,
      "edgeGlow": true,
      "greeting": true
    }

    """

  @Test func `reads 1.x's file and writes it back byte for byte`() {
    let settings = IslandSettings(json: Data(file.utf8))
    #expect(settings.soundTheme == .soft && settings.openWith == .hover)
    #expect(String(decoding: settings.json(), as: UTF8.self) == file)
  }

  @Test func `lives in 1.x's own folder`() {
    #expect(IslandSettings.defaultURL.path.hasSuffix("Application Support/@agent-island/app/settings.json"))
  }
}

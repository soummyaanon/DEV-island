import Foundation
import IslandCore
import Testing

@Suite struct QuickAccessWingTests {
  typealias I = WingContent.Inputs

  @Test func `a call beats a timer, which beats agents working`() {
    #expect(WingContent(I(active: 2, meeting: true, timer: true, media: true)) == .meeting)
    #expect(WingContent(I(active: 2, timer: true, media: true)) == .timer)
  }

  @Test func `agents working beat music; music beats ambience`() {
    #expect(WingContent(I(active: 1, media: true)) == .working)
    #expect(WingContent(I(activity: true, lowBattery: true, weather: true, media: true)) == .media)
  }

  @Test func `attention, a moment and the charger still come first`() {
    #expect(WingContent(I(needsYou: 1, meeting: true, timer: true)) == .attention)
    #expect(WingContent(I(moment: true, meeting: true)) == .moment)
    #expect(WingContent(I(activity: true, powerMoment: true, meeting: true)) == .activity)
  }
}

@Suite struct TimerTests {
  let t0 = Date(timeIntervalSince1970: 1_000_000)

  @Test func `counts down, pauses and resumes where it left off`() {
    var timer = IslandTimer.countdown(minutes: 5, at: t0)
    #expect(timer.remaining(at: t0.addingTimeInterval(60)) == 240)
    #expect(abs(timer.progress(at: t0.addingTimeInterval(150)) - 0.5) < 0.0001)
    timer.pause(at: t0.addingTimeInterval(60))
    #expect(timer.isPaused && timer.remaining(at: t0.addingTimeInterval(9_999)) == 240)
    timer.resume(at: t0.addingTimeInterval(1000))
    #expect(timer.remaining(at: t0.addingTimeInterval(1100)) == 140)
    #expect(timer.isFinished(at: t0.addingTimeInterval(1240)))
  }

  @Test func `extends, never below a second`() {
    var timer = IslandTimer.countdown(minutes: 1, at: t0)
    timer.extend(by: 60, at: t0)
    #expect(timer.remaining(at: t0) == 120)
    timer.extend(by: -500, at: t0)
    #expect(timer.remaining(at: t0) == 1)
  }

  @Test func `pomodoro alternates focus and breaks, long every fourth`() {
    var timer = IslandTimer.pomodoro(at: t0)
    #expect(timer.title == "Focus 1" && timer.duration == 25 * 60)
    var phases: [IslandTimer.Phase] = []
    for _ in 0..<8 {
      timer = timer.next(at: t0)!
      phases.append(timer.phase)
    }
    #expect(phases == [.shortBreak, .focus, .shortBreak, .focus, .shortBreak, .focus, .longBreak, .focus])
    #expect(timer.round == 5)
    #expect(IslandTimer.countdown(minutes: 1, at: t0).next(at: t0) == nil)
  }

  @Test func `clock text`() {
    #expect(Clock.countdown(299.2) == "5:00")
    #expect(Clock.countdown(59) == "0:59")
    #expect(Clock.countdown(3_725) == "1:02:05")
    #expect(Clock.elapsed(42.9) == "0:42")
  }
}

@Suite struct ConverterTests {
  @Test(arguments: [
    ("10 km to mi", "6.214 mi"),
    ("72f in c", "22.222 °C"),
    ("1 mile = ft", "5,280 ft"),
    ("3 cups to ml", "709.765 ml"),
    ("100 kmh to mph", "62.137 mph"),
    ("2 GB in MB", "2,000 MB"),
    ("convert 5 lb to kg", "2.268 kg"),
    ("90 deg to rad", "1.571 rad"),
    ("1,000 m to km", "1 km"),
    ("2 days to hours", "48 h"),
  ])
  func `converts`(phrase: String, expected: String) {
    #expect(UnitConverter.convert(phrase)?.text == expected)
  }

  @Test func `refuses mixed kinds and nonsense`() {
    #expect(UnitConverter.convert("5 kg to km") == nil)
    #expect(UnitConverter.convert("hello") == nil)
    #expect(UnitConverter.convert("5 parsecs to km") == nil)
  }
}

@Suite struct ClipboardPrivacyTests {
  @Test func `skips concealed types and password managers`() {
    #expect(ClipboardPrivacy.skips(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], sourceBundle: nil))
    #expect(ClipboardPrivacy.skips(types: ["public.utf8-plain-text"], sourceBundle: "com.1password.1password"))
    #expect(!ClipboardPrivacy.skips(types: ["public.utf8-plain-text"], sourceBundle: "com.apple.Safari"))
  }

  @Test(arguments: [
    "4111 1111 1111 1111",
    "482193",
    "sk-ant-api03-abcdefghijklmnopqrstuvwxyz012345",
    "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
    "AKIAIOSFODNN7EXAMPLE",
    "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abc123-_x",
    "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----",
    "Tr0ub4dor&3xyz",
  ])
  func `flags secrets`(text: String) {
    #expect(ClipboardPrivacy.looksSensitive(text))
  }

  @Test(arguments: [
    "Hello, world",
    "https://example.com/Path?a=1&B=2",
    "2026",
    "Meeting at 10:30 with Sam",
    "fooBar1(x)",
    "4111 1111 1111 1112",
    "me@example.com",
  ])
  func `keeps ordinary text`(text: String) {
    #expect(!ClipboardPrivacy.looksSensitive(text))
  }

  @Test func `history is newest first, deduplicated and capped`() {
    var log = ClipboardLog<String>(limit: 3)
    for item in ["a", "b", "c", "a", "d"] { log.add(item) }
    #expect(log.items == ["d", "a", "c"])
  }
}

@Suite struct MeetingTests {
  @Test func `finds call links in event text`() {
    let found = MeetingLink.find(in: [nil, "Room 4", "Join: https://us02web.zoom.us/j/123456789?pwd=abc thanks"])
    #expect(found?.service == .zoom)
    #expect(found?.url.absoluteString == "https://us02web.zoom.us/j/123456789?pwd=abc")
    #expect(MeetingLink.find(in: ["https://meet.google.com/abc-defg-hij"])?.service == .meet)
    #expect(MeetingLink.find(in: ["lunch"]) == nil)
  }

  @Test func `a meet call is a coded room, not the landing page`() {
    #expect(MeetingLink.isMeetCall("https://meet.google.com/abc-defg-hij"))
    #expect(MeetingLink.isMeetCall("https://meet.google.com/abc-defg-hij?authuser=1"))
    #expect(!MeetingLink.isMeetCall("https://meet.google.com/landing"))
    #expect(!MeetingLink.isMeetCall("https://example.com/meet.google.com/abc-defg-hij"))
  }

  @Test func `zoom needs its meeting process, and wins over a meet tab`() {
    #expect(MeetingSignals.source(zoomRunning: true, processNames: ["zoom.us"], meetTab: nil) == nil)
    #expect(MeetingSignals.source(zoomRunning: true, processNames: ["CptHost"], meetTab: ("b", "u")) == .zoom)
    #expect(MeetingSignals.source(zoomRunning: false, processNames: ["CptHost"], meetTab: ("b", "u")) == .meet(browserBundle: "b", url: "u"))
  }
}

@Suite struct BrowserTests {
  @Test func `knows browsers by bundle id`() {
    #expect(Browser.named(bundleId: "com.google.Chrome")?.family == .chromium)
    #expect(Browser.named(bundleId: "com.apple.Safari")?.family == .safari)
    #expect(Browser.named(bundleId: "com.apple.finder") == nil)
  }

  @Test func `chromium scripts history; safari only reloads; firefox uses keys`() {
    let chrome = Browser.named(bundleId: "com.google.Chrome")!
    #expect(chrome.script(.back)?.contains("go back active tab of front window") == true)
    let safari = Browser.named(bundleId: "com.apple.Safari")!
    #expect(safari.script(.back) == nil && safari.script(.reload) != nil)
    #expect(Browser.named(bundleId: "org.mozilla.firefox")!.activeTabScript == nil)
  }

  @Test func `parses the active tab`() {
    #expect(Browser.parseActiveTab("Title\nhttps://a.com")! == ("Title", "https://a.com"))
    #expect(Browser.parseActiveTab("") == nil)
    #expect(displayHost("https://www.github.com/x") == "github.com")
  }

  @Test func `quotes urls it puts in a script`() {
    let chrome = Browser.named(bundleId: "com.google.Chrome")!
    #expect(chrome.focusTabScript(url: "https://a.com/\"x")?.contains(#"https://a.com/\"x"#) == true)
  }
}

@Suite struct WidgetTests {
  @Test func `reads symbols`() {
    #expect(StockQuote.symbols("aapl, MSFT  ^gspc,aapl;bad!") == ["AAPL", "MSFT", "^GSPC"])
  }

  @Test func `parses a chart response`() {
    let json = """
      {"chart":{"result":[{"meta":{"symbol":"AAPL","currency":"USD","regularMarketPrice":210.5,"chartPreviousClose":200},
      "indicators":{"quote":[{"close":[201.0,null,205.5,210.5]}]}}],"error":null}}
      """
    let quote = StockQuote(chartJSON: Data(json.utf8), symbol: "AAPL")
    #expect(quote?.price == 210.5 && quote?.series == [201, 205.5, 210.5])
    #expect(abs((quote?.changePercent ?? 0) - 5.25) < 0.0001)
    #expect(StockQuote(chartJSON: Data("{}".utf8), symbol: "X") == nil)
  }

  @Test func `to-dos keep open items first and ignore blanks`() {
    var list = TodoList()
    let a = list.add("ship it")!
    list.add("  ")
    let b = list.add("write tests")!
    list.toggle(a.id)
    #expect(list.sorted.map(\.text) == ["write tests", "ship it"])
    #expect(list.openCount == 1)
    list.clearDone()
    #expect(list.items.map(\.id) == [b.id])
  }

  @Test func `to-dos round-trip through their file`() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "todos-\(UUID()).json")
    var list = TodoList()
    list.add("one")
    try list.save(to: url)
    #expect(TodoList.load(from: url).items.map(\.text) == ["one"])
  }

  @Test func `shelf names never clash`() {
    #expect(ShelfItem.freeName("Note.txt", existing: []) == "Note.txt")
    #expect(ShelfItem.freeName("Note.txt", existing: ["Note.txt", "Note 2.txt"]) == "Note 3.txt")
    let items = shelfAdding([], path: "/a")
    #expect(shelfAdding(items, path: "/a").count == 1)
  }

  @Test func `prompter scrolls within the script`() {
    #expect(Prompter.offset(elapsed: 2, speed: 30, from: 10, limit: 500) == 70)
    #expect(Prompter.offset(elapsed: 100, speed: 30, from: 0, limit: 500) == 500)
  }
}

@Suite struct HubTests {
  @Test func `tabs follow settings`() {
    var settings = IslandSettings()
    #expect(HubTab.enabled(settings).first == .agents)
    settings.quickControls = false
    settings.assistant = false
    #expect(!HubTab.enabled(settings).contains(.controls) && !HubTab.enabled(settings).contains(.ask))
  }

  @Test func `stepping walks sessions then tabs, clamped`() {
    let tabs: [HubTab] = [.controls, .shelf]
    #expect(HubTab.step(from: nil, by: 1, in: tabs) == .controls)
    #expect(HubTab.step(from: .controls, by: -1, in: tabs) == nil)
    #expect(HubTab.step(from: .shelf, by: 1, in: tabs) == .shelf)
    #expect(HubTab.step(from: nil, by: -1, in: tabs) == nil)
  }

  @Test func `quick-access settings round-trip and stay out of a default file`() {
    var settings = IslandSettings()
    let plain = String(decoding: settings.json(), as: UTF8.self)
    #expect(!plain.contains("clipboardHistory"))
    settings.clipboardHistory = false
    settings.stockSymbols = "NVDA"
    let back = IslandSettings(json: settings.json())
    #expect(back.clipboardHistory == false && back.stockSymbols == "NVDA" && back.shelf)
  }

  @Test func `reads the menu bar's auto-hide default`() {
    #expect(MenuBarHiding.isHidden(globalDefaults: ["_HIHideMenuBar": true]))
    #expect(MenuBarHiding.isHidden(globalDefaults: ["_HIHideMenuBar": 1]))
    #expect(!MenuBarHiding.isHidden(globalDefaults: [:]))
  }
}

@Suite struct QuickLinkTests {
  @Test func `reads tool, timer and pomodoro links`() {
    #expect(DeepLink(URL(string: "agent-island://tools/clipboard")!) == .tools("clipboard"))
    #expect(DeepLink(URL(string: "agent-island://tools")!) == .tools(nil))
    #expect(DeepLink(URL(string: "agent-island://timer?minutes=2&label=Tea")!) == .timer(minutes: 2, label: "Tea"))
    #expect(DeepLink(URL(string: "agent-island://timer?minutes=-1")!) == nil)
    #expect(DeepLink(URL(string: "agent-island://pomodoro")!) == .pomodoro)
  }
}

@Suite struct AgentStatsTests {
  let now = ISO8601DateFormatter().date(from: "2026-10-03T12:00:00Z")!

  @Test func `counts each claude message once, by day and project`() {
    let line = #"{"type":"assistant","timestamp":"2026-10-03T11:00:00.000Z","sessionId":"s1","cwd":"/x/island","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":90,"cache_creation_input_tokens":100,"cache_read_input_tokens":5000}}}"#
    var stats = AgentStats()
    var seen: Set<String> = []
    stats.addClaude(line + "\n" + line, since: .distantPast, now: now, seen: &seen)
    #expect(stats.today(now: now).claude == 200)
    #expect(stats.projects["island"] == 200)
    #expect(stats.sessionsToday[.claudeCode] == ["s1"])
    #expect(stats.models["claude-opus-5-5"] == 200)
  }

  @Test func `takes codex's last cumulative count, without cached input`() {
    let text = """
      {"timestamp":"2026-10-03T10:00:00.000Z","type":"session_meta","payload":{"id":"c1","cwd":"/y/api"}}
      {"timestamp":"2026-10-03T10:01:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":5}}}}
      {"timestamp":"2026-10-03T10:02:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300,"cached_input_tokens":100,"output_tokens":20}}}}
      """
    var stats = AgentStats()
    stats.addCodex(text, since: .distantPast, now: now)
    #expect(stats.today(now: now).codex == 220)
    #expect(stats.projects["api"] == 220)
    #expect(stats.sessionsToday[.codex] == ["c1"])
  }

  @Test func `ignores what's older than the window`() {
    let line = #"{"timestamp":"2026-09-01T11:00:00.000Z","sessionId":"s","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":1}}}"#
    var stats = AgentStats()
    var seen: Set<String> = []
    stats.addClaude(line, since: now.addingTimeInterval(-7 * 86_400), now: now, seen: &seen)
    #expect(stats.days.isEmpty)
  }

  @Test func `series is zero-filled, oldest first`() {
    let series = AgentStats().series(days: 7, now: now)
    #expect(series.count == 7 && series.last?.key == AgentStats.dayKey(now))
  }

  @Test func `short token text and terminal paths`() {
    #expect(TokenText.short(842) == "842" && TokenText.short(12_400) == "12K" && TokenText.short(3_100_000) == "3.1M")
    #expect(TokenText.short(1_500) == "1.5K")
    #expect(terminalPaths(["/a b/c.txt", "/d"]) == #"/a\ b/c.txt /d"#)
  }
}

@Suite struct MonthGridTests {
  @Test func `lays out October 2026 from a Monday-first calendar`() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    let october = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15))!
    let days = MonthGrid.days(of: october, calendar: calendar)
    // 1 October 2026 is a Thursday: three blanks (Mon, Tue, Wed).
    #expect(days.prefix(3).allSatisfy { $0 == nil })
    #expect(days.compactMap(\.self).count == 31)
    #expect(MonthGrid.weekdaySymbols(calendar: calendar).first == "M")
    let next = MonthGrid.shift(october, by: 1, calendar: calendar)
    #expect(calendar.component(.month, from: next) == 11 && calendar.component(.day, from: next) == 1)
  }
}

@Suite struct ConverterPickerTests {
  @Test func `every family has units and its default pair`() {
    #expect(UnitConverter.kinds.count == 11)
    for kind in UnitConverter.kinds {
      #expect(kind.units.contains(kind.from) && kind.units.contains(kind.to), "\(kind.id)")
    }
  }

  @Test func `converts by symbol, refusing mixed families`() {
    #expect(abs((UnitConverter.convert(100, from: "°C", to: "°F") ?? 0) - 212) < 0.0001)
    #expect(abs((UnitConverter.convert(1, from: "mi", to: "km") ?? 0) - 1.609344) < 0.0001)
    #expect(UnitConverter.convert(1, from: "kg", to: "km") == nil)
  }
}

@Suite struct TrayStatusTests {
  @Test func `rests, counts working agents, and puts attention first`() {
    let now = Date.now
    func s(_ state: SessionState, action: Bool = false) -> SessionSnapshot {
      SessionSnapshot(key: UUID().uuidString, agent: .codex, sessionId: "x", cwd: "/a", state: state, title: "", requiresAction: action, startedAt: now, updatedAt: now)
    }
    #expect(TrayStatus([]).kind == .resting && TrayStatus([]).count == 0)
    #expect(TrayStatus([s(.working), s(.starting), s(.done)]).count == 2)
    let attention = TrayStatus([s(.working), s(.waitingForApproval, action: true)])
    #expect(attention.kind == .attention && attention.count == 1)
  }
}

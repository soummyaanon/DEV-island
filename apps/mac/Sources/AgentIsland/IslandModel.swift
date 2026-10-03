import CoreGraphics
import Foundation
import IslandCore
import Observation

/// Everything the island draws from, on the main actor. Services write into
/// it; views read it.
@Observable
final class IslandModel {
  var notch: NotchMetrics
  var settings: IslandSettings
  let power: PowerMonitor
  let sessions: SessionStore

  /// Locked, asleep, or covered: nothing may animate unseen.
  var isPaused = false

  /// The pointer is over the island's shape.
  var isHovering = false {
    didSet {
      guard !isHovering, oldValue else { return }
      // Leaving resets both gesture latches, so a gesture-opened island can
      // always be closed by moving away — never stuck open.
      gestureOpen = false
      dismissed = false
      closeEmptyPrompt()
      // Moving off with nothing typed lets the island close, like the prompt bar.
      if ask.text.trimmingCharacters(in: .whitespaces).isEmpty && ask.live == nil { ask.focused = false }
    }
  }

  /// Swipe mode: a swipe down (or a click) opened it while hovering.
  private(set) var gestureOpen = false
  /// A swipe up parked it closed until the pointer leaves.
  private(set) var dismissed = false
  /// The session row or bubble under the pointer.
  var hovered: String?
  /// −1…1 while a swipe accumulates: the wings lean down to open, the panel up to close.
  var rubber: Double = 0

  /// The island body as last laid out (ears excluded), for hit-testing.
  var bodySize: CGSize = .zero {
    didSet { if bodySize != oldValue { onLayout?() } }
  }

  /// The pointer may now be inside or outside a different shape.
  @ObservationIgnored var onLayout: (() -> Void)?

  let actions: IslandActions
  let weather = WeatherService()
  let assistant = AssistantEngine()
  let updates = UpdateChecker()

  // Quick access: each a service the controller starts and stops with its setting.
  let media = NowPlayingService()
  let timers = TimerService()
  let shelf = FileShelf()
  let clipboard = ClipboardHistory()
  let meeting = MeetingService()
  let browser = BrowserService()
  let agenda = AgendaService()
  let stocks = StocksService()
  let system = SystemControls()
  let prompter = TeleprompterState()
  let agentStats = AgentStatsService()
  @ObservationIgnored private(set) lazy var ask = AssistantState(engine: assistant)

  init(notch: NotchMetrics, settings: IslandSettings, power: PowerMonitor, sessions: SessionStore, actions: IslandActions) {
    self.notch = notch
    self.settings = settings
    self.power = power
    self.sessions = sessions
    self.actions = actions
  }

  // MARK: Settings

  /// Opens the Settings window (the gear key, the tray, a deep link).
  @ObservationIgnored var openSettings: () -> Void = {}

  /// Changes a setting: saved to the shared file at once, and the controller
  /// applies any side effects.
  func changeSettings(_ change: (inout IslandSettings) -> Void) {
    var next = settings
    change(&next)
    guard next != settings else { return }
    settings = next
    do { try next.save() } catch { Log.app.error("settings save failed: \(error.localizedDescription, privacy: .public)") }
  }

  // MARK: Focus

  /// As a Shortcuts automation last said (agent-island://focus/on|off).
  var focus = MacFocus()
  /// A Focus change shows in the wings for two seconds.
  private(set) var focusMoment: (id: UUID, active: Bool)?
  @ObservationIgnored private var focusMomentEnd: Task<Void, Never>?

  func setFocus(_ next: MacFocus) {
    let changed = next.active != focus.active
    focus = next
    guard changed else { return }
    let moment = (id: UUID(), active: next.active)
    focusMoment = moment
    focusMomentEnd?.cancel()
    focusMomentEnd = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      if self?.focusMoment?.id == moment.id { self?.focusMoment = nil }
    }
  }

  // MARK: Resource meter

  /// CPU and memory per session's process tree, while the panel is open.
  var procStats: [String: ProcTotals] = [:]

  /// What every shown session is using right now.
  var procTotal: ProcTotals? {
    let shown = sessions.sessions.prefix(SessionList.maxRows).compactMap { procStats[$0.key] }
    guard !shown.isEmpty else { return nil }
    return ProcTotals(cpu: shown.map(\.cpu).reduce(0, +), rssMB: shown.map(\.rssMB).reduce(0, +), processes: shown.map(\.processes).reduce(0, +))
  }

  // MARK: Hello

  /// The launch or welcome-back hello, while it's up.
  private(set) var greeting: (value: Greeting, id: UUID, at: Date)?
  @ObservationIgnored private var greetingEnd: Task<Void, Never>?

  func showGreeting(_ value: Greeting) {
    let shown = (value: value, id: UUID(), at: Date.now)
    greeting = shown
    sessions.firePulse(.hello)
    greetingEnd?.cancel()
    greetingEnd = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(Greeting.duration(for: value.line))) } catch { return }
      if self?.greeting?.id == shown.id { self?.greeting = nil }
    }
  }

  func dismissGreeting() {
    greetingEnd?.cancel()
    greeting = nil
  }

  /// While the hello is up (and you're not otherwise using the island), the
  /// panel shows only the hello.
  var greetingOnly: Bool {
    greeting != nil && !hoverExpands && !pinned && pending.isEmpty && asking.isEmpty
  }

  // MARK: Held open

  /// Pinned open from the menu bar icon or a deep link.
  var pinned = false
  /// VoiceOver reached in (⌃⌥⌘I): open, focusable, Tab stays inside.
  var a11yFocused = false

  // MARK: Prompt

  var promptText = ""
  /// Summoned with the compose key.
  var promptOpen = false
  var promptFocused = false
  /// A send was dropped for lack of Accessibility: show the hint.
  var needsAccessibility = false

  /// Free-form prompts go to the first running session, else the first listed.
  var promptTarget: SessionSnapshot? { active.first ?? sessions.sessions.first }

  var asking: [SessionSnapshot] { sessions.sessions.filter { $0.pendingQuestion != nil } }
  var pending: [SessionSnapshot] { sessions.sessions.filter { $0.pendingApproval != nil } }

  /// The prompt bar appears when an agent waits on an answer, or when you ask
  /// for it, and never vanishes from under you mid-sentence.
  var showsPrompt: Bool {
    promptTarget != nil && (promptOpen || promptFocused || !asking.isEmpty || !promptText.isEmpty)
  }

  /// The island takes keystrokes only while you're typing or VoiceOver is in.
  var wantsKey: Bool { promptFocused || promptOpen || a11yFocused || ask.focused || hubTyping }

  /// The Ask bar is on (Settings) and can open here.
  var crewAvailable: Bool { settings.assistant }

  func toggleAsk() {
    if ask.isOpen {
      ask.close()
    } else {
      promptOpen = false
      promptFocused = false
      ask.open()
    }
  }

  func togglePrompt() {
    if ask.isOpen { ask.close() }
    if promptOpen {
      promptText = ""
      promptOpen = false
      promptFocused = false
    } else {
      promptOpen = true
    }
  }

  func submitPrompt() {
    guard let target = promptTarget, !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    switch actions.sendPrompt(promptText, to: target) {
    case .sent: needsAccessibility = false
    case .noAccessibility: needsAccessibility = true
    case .empty: break
    }
    promptText = ""
  }

  /// With nothing typed, leaving the island closes the bar, so one click on
  /// the compose key can't pin the island open until someone finds Escape.
  func closeEmptyPrompt() {
    guard promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    promptFocused = false
    promptOpen = false
  }

  /// Picks on each question card, by question id; a new question starts fresh.
  var questionPicks: [String: QuestionPicks] = [:]

  func picks(for question: PendingQuestion) -> QuestionPicks {
    if let picks = questionPicks[question.id], picks.question == question { return picks }
    return QuestionPicks(question)
  }

  func choose(_ session: SessionSnapshot, question index: Int, option: Int) {
    guard let question = session.pendingQuestion else { return }
    var picks = picks(for: question)
    let answer = picks.choose(question: index, option: option)
    questionPicks[question.id] = picks
    if let answer { actions.answer(session, selections: answer) }
  }

  // MARK: Open or closed

  /// Hover opens it in hover mode; swipe mode also needs a swipe down or a click.
  var hoverExpands: Bool {
    isHovering && !dismissed && (settings.openWith == .hover || gestureOpen)
  }

  /// Anything waiting on the human forces the panel open.
  var isForcedOpen: Bool {
    sessions.sessions.contains { $0.pendingApproval != nil || $0.pendingQuestion != nil || $0.state == .waitingForApproval }
  }

  var isExpanded: Bool {
    hoverExpands || pinned || promptFocused || a11yFocused || ask.focused || greeting != nil || isForcedOpen
      || shelfDropping || prompterLive || hubTyping
  }

  // MARK: Quick access

  /// The open island's page: nil is the sessions page, else a tool.
  var hubTab: HubTab?
  /// The Tools page remembers its tab across a close.
  var lastHubTab: HubTab?
  /// A text field in a tool has the keyboard: the island stays open.
  var hubTyping = false
  /// −1…1 while a sideways swipe builds: the page leans and the next one's icon shows.
  var sideRubber: Double = 0
  /// Opens so far that showed the swipe hint; it stops after a few, or after a swipe.
  var swipeHintsLeft = max(0, 6 - UserDefaults.standard.integer(forKey: "swipeHintsShown"))

  func swiped() {
    guard swipeHintsLeft > 0 else { return }
    swipeHintsLeft = 0
    UserDefaults.standard.set(99, forKey: "swipeHintsShown")
  }

  /// The pages a swipe walks through: sessions first (nil), then each tool.
  var pages: [HubTab?] { [nil] + hubTabs.filter { $0 != .ask } }

  /// Where a swipe in `direction` (+1 next, −1 back) would land.
  func page(after delta: Int) -> HubTab?? {
    let pages = pages
    guard let index = pages.firstIndex(of: hubTab) else { return nil }
    let next = index + delta
    return pages.indices.contains(next) ? .some(pages[next]) : nil
  }

  /// The menu bar hides itself, so the wings carry the time.
  var menuBarHidden = false

  var hubTabs: [HubTab] { HubTab.enabled(settings) }

  /// Files are being dragged at the notch: the island opens as the shelf's drop zone.
  var shelfDropping: Bool { settings.shelf && shelf.dragActive }

  /// The teleprompter rolling: it holds the island open under the camera.
  var prompterLive: Bool { settings.teleprompter && prompter.playing }

  func showTab(_ tab: HubTab?) {
    if tab == .ask {
      // The assistant lives on the main page, in the Ask bar.
      hubTab = nil
      if !ask.isOpen { toggleAsk() }
      return
    }
    hubTab = tab
    if let tab { lastHubTab = tab }
  }

  /// A sideways swipe: sessions ⇄ tools.
  func stepPage(_ delta: Int) {
    let tabs = hubTabs.filter { $0 != .ask }
    if hubTab == nil, delta > 0, let last = lastHubTab, tabs.contains(last) {
      showTab(last)
    } else {
      showTab(HubTab.step(from: hubTab, by: delta, in: tabs))
    }
  }

  /// The call, timer and track the wings may show.
  var liveCall: MeetingService.Call? { settings.meetings ? meeting.call : nil }
  var liveTimer: IslandTimer? { settings.timers ? timers.featured : nil }
  var liveTrack: NowPlayingService.Track? { settings.nowPlaying ? media.track : nil }

  /// The time in the right wing at rest, when the menu bar that shows it is hidden.
  var showsClock: Bool { settings.menuBarClock && menuBarHidden }

  func swipe(_ direction: WheelGesture.Direction) {
    switch direction {
    case .up where isExpanded:
      dismissed = true
      gestureOpen = false
    case .down where !isExpanded && settings.openWith == .swipe:
      gestureOpen = true
      dismissed = false
    default:
      break
    }
  }

  /// A sideways swipe on the closed island opens it (onto the tools).
  func openFromGesture() {
    gestureOpen = true
    dismissed = false
  }

  /// Swipe mode only: a click on the wings toggles, mirroring the gesture.
  func clickWings() {
    guard settings.openWith == .swipe else { return }
    if isExpanded && hoverExpands {
      dismissed = true
    } else if !isExpanded {
      gestureOpen = true
      dismissed = false
    }
  }

  // MARK: Wings

  var active: [SessionSnapshot] { sessions.sessions.filter(\.isActive) }
  var needsYou: [SessionSnapshot] { sessions.sessions.filter { $0.state == .waitingForApproval } }

  /// The battery, when the setting shows it and the Mac has one.
  var reading: PowerReading? { settings.battery ? power.reading : nil }

  /// What the collapsed wings show (nothing while open).
  var wing: WingContent {
    guard !isExpanded else { return .empty }
    return WingContent(.init(
      needsYou: needsYou.count,
      active: active.count,
      moment: sessions.momentSession != nil,
      activity: (power.activity != nil && reading != nil) || focusMoment != nil,
      powerMoment: power.activity?.isCharger == true,
      lowBattery: reading?.isLow == true,
      weather: weather.reading != nil,
      meeting: liveCall != nil,
      timer: liveTimer != nil,
      media: liveTrack?.playing == true
    ))
  }

  /// Sessions present, none running: battery left, the crew plays right.
  var isSleeping: Bool {
    !isExpanded && !sessions.sessions.isEmpty && active.isEmpty && wing == .empty
  }

  /// No sessions at all: the crew still keeps the island company.
  var isIdleBot: Bool {
    !isExpanded && sessions.connected && sessions.sessions.isEmpty && wing == .empty
  }

  /// Offline with nothing to show: the island shrinks to the notch and disappears.
  var isResting: Bool {
    sessions.sessions.isEmpty && wing == .empty && !isIdleBot && !isExpanded
  }

  var orbs: [WingOrb] { WingOrb.shown(active: active) }

  var showsWorkCrew: Bool {
    needsYou.isEmpty && wing == .working && !active.isEmpty
  }

  // MARK: Size

  var bandHeight: CGFloat { IslandMetrics.bandHeight(notch) }

  /// The collapsed width for what the wings hold (1.x's island.css rules).
  var collapsedWidth: CGFloat {
    let w = notch.width
    if isResting { return w }
    if isSleeping || isIdleBot { return w + (showsClock ? 124 : 84) }
    switch wing {
    case .moment, .activity, .lowBattery, .weather, .media: return w + 104
    case .meeting, .timer: return w + 124
    case .working where WorkCrew(active).more > 0: return w + 100
    default:
      return switch orbs.count {
      case 3...: w + 136
      case 2: w + 100
      default: w + 68
      }
    }
  }

  /// The open island sizes to its content, between these.
  var expandedWidthRange: ClosedRange<CGFloat> {
    let floor = IslandMetrics.expandedWidth(notch)
    return floor...max(floor, maxIslandWidth)
  }

  /// Widest the island may grow on this display.
  var maxIslandWidth: CGFloat = 720
}

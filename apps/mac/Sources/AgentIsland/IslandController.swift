import AppKit
import IslandCore
import SwiftUI

/// Owns the panel and wires the world into the model: the pointer (hover,
/// click-through, swipes), display changes, and sleep/lock/occlusion.
final class IslandController {
  private let model: IslandModel
  private let panel: IslandPanel
  private var gesture = WheelGesture()
  private let daemon: DaemonClient
  /// One launch runs everything: the daemon, unless one's already up.
  private let server = Daemon()
  private var rubberReset: Task<Void, Never>?
  private var eventMonitors: [Any] = []
  private var observers: [NSObjectProtocol] = []
  private var asleep = false
  private var sessionInactive = false
  private let hotKeys = HotKeys()
  private let sounds = SoundPlayer()
  private let haptics = HapticPlayer()
  private var tray: NSStatusItem?
  private var trayMenu: TrayMenu?
  private lazy var windows = WindowsController(model: model, sounds: sounds)
  private var sampler: Task<Void, Never>?
  private var settle: Task<Void, Never>?
  /// When the Mac was locked or slept, for the welcome-back hello.
  private var awaySince: Date?
  /// The app that was frontmost before the island took keys, to hand them back to.
  private var previousApp: NSRunningApplication?
  // Quick access (see the extension below).
  fileprivate var browserPoll: Task<Void, Never>?
  fileprivate var pageReset: Task<Void, Never>?
  fileprivate var dragBaseline = 0
  fileprivate var dragCarriesFiles = false
  fileprivate var sidewaysSum = 0.0
  fileprivate var sidewaysLast: TimeInterval = 0
  fileprivate var sidewaysLockedUntil: TimeInterval = 0
  fileprivate var sideReset: Task<Void, Never>?
  fileprivate var hintCounted = false
  fileprivate let tokenMilestones = TokenMilestoneWatcher()
  /// A press on the closed island that may become a drag to another edge.
  private var grab: (start: CGPoint, moving: Bool)?
  /// On a side edge, the pointer has to rest a moment before it counts as hovering.
  private var hoverDwell: Task<Void, Never>?
  /// The layer a drag carries the island across.
  private lazy var overlay = DragOverlayPanel(model: model)
  /// The flight into the slot after a drag lets go.
  private var landing: Task<Void, Never>?
  /// The last hit-test shape, rebuilt only when the island changes.
  private var hitShape: (key: HitKey, inner: CGPath, outer: CGPath)?

  init(settings: IslandSettings) {
    let screen = Self.targetScreen
    let sessions = SessionStore()
    sessions.enabledAgents = settings.agents
    daemon = DaemonClient(store: sessions)
    model = IslandModel(
      notch: screen.map(NotchMetrics.init(screen:)) ?? NotchMetrics(width: NotchMetrics.fallbackWidth, height: 24, hasNotch: false),
      settings: settings,
      power: PowerMonitor(),
      sessions: sessions,
      actions: IslandActions(daemon: daemon, store: sessions)
    )
    if let screen { model.maxIslandWidth = Self.maxIslandWidth(on: screen) }
    let host = IslandHostingView(rootView: IslandView(model: model))
    // The panel is a fixed canvas; the island never resizes the window.
    host.sizingOptions = []
    panel = IslandPanel(contentView: host)
    panel.orderFrontRegardless()
    Log.notch.notice("notch \(self.model.notch.width, format: .fixed(precision: 0))×\(self.model.notch.height, format: .fixed(precision: 0)) real=\(self.model.notch.hasNotch)")

    model.onLayout = { [weak self] in self?.pointerMoved() }
    watchPlacement()
    if settings.battery { model.power.start() }
    Task { [server, daemon] in
      // Moving in from 1.x first, so its leftover daemon doesn't hold the port.
      await MigrationRunner.run(port: 7433)
      await server.start()
      daemon.start()
    }
    watchPointer()
    watchScreens()
    watchVisibility()
    watchEnergy()
    watchRequests()
    watchKeys()
    announceTransitions()
    model.openSettings = { [weak self] in self?.openSettings() }
    ZeroConfigPolicy.setUp(settings)
    // First run: the intro speaks first, and the island says hello once it's done.
    let introducing = windows.maybeShowOnboarding()
    windows.onArrive = { [weak self] in self?.welcome() }
    wireFeedback()
    wireAssistant()
    watchSettings()
    watchMeter()
    watchDev()
    wireQuickAccess()
    if !introducing { Task { await greet(.launch) } }
  }

  // MARK: Assistant

  private func wireAssistant() {
    let ask = model.ask
    #if DEBUG
    // From a terminal: ask the Ask bar something (see README).
    let token = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name(Log.subsystem + ".ask"), object: nil, queue: .main
    ) { [weak self] note in
      let question = note.object as? String ?? ""
      MainActor.assumeIsolated {
        guard let self else { return }
        if !self.model.ask.isOpen { self.model.toggleAsk() }
        self.model.pinned = true
        self.model.ask.text = question
        self.model.ask.ask()
      }
    }
    observers.append(token)
    #endif
    // Warmed now, so "run my … shortcut" never waits on `shortcuts list`.
    if model.settings.assistant { Task { _ = await AssistantTools.listShortcuts() } }
    ask.sessions = { [model] in model.sessions.sessions }
    ask.sendPrompt = { [model] text, session in _ = model.actions.sendPrompt(text, to: session) }
    ask.haptic = { [haptics] in haptics.play($0) }
    ask.speakReplies = { [model] in model.settings.speakReplies }
    ask.startTimerHook = { [model] minutes, label in model.timers.startCountdown(minutes: Double(minutes), label: label) }
    ask.extraAction = { [model] payload in
      switch payload["kind"] {
      case "pomodoro": model.timers.startPomodoro()
      case "todo": if let text = payload["text"] { model.agenda.addTodo(text) }
      case "media":
        switch payload["command"] {
        case "next": model.media.next()
        case "previous": model.media.previous()
        default: model.media.playPause()
        }
      case "tool": if let tab = payload["tab"].flatMap(HubTab.init(rawValue:)) { model.showTab(tab) }
      default: break
      }
    }
    ask.onTimer = { [weak self] label in
      guard let self else { return }
      sounds.play(.success, settings: model.settings)
      model.sessions.firePulse(.done)
      haptics.play(.success)
      NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
        .announcement: label.isEmpty ? "Timer done" : "Timer done: \(label)",
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ])
    }
  }

  // MARK: Hello

  private func greet(_ occasion: Greeting.Occasion) async {
    guard model.settings.greeting else { return }
    let reading = model.reading
    var facts = Greeting.Facts(
      name: Greeting.firstName(fullName: NSFullUserName(), login: NSUserName()),
      date: .now,
      weather: model.weather.reading?.summary,
      occasion: occasion
    )
    if let reading { facts.battery = (reading.percent, !reading.isOnBattery) }
    let title = Greeting.title(facts)
    let greeting = if let line = await model.assistant.greet(facts: Greeting.factsText(facts)) {
      Greeting(title: title, line: Greeting.dropSalutation(Greeting.tidy(line), name: facts.name), ai: true)
    } else {
      Greeting(title: title, line: Greeting.fallbackLine(facts), ai: false)
    }
    model.showGreeting(greeting)
    haptics.play(.success)
  }

  /// Straight after the intro: the island opens where the card landed.
  private func welcome() {
    let name = Greeting.firstName(fullName: NSFullUserName(), login: NSUserName())
    model.showGreeting(Greeting(
      title: name.isEmpty ? "Welcome to the island" : "Welcome aboard, \(name)",
      line: "This is home. Start Claude Code, Codex or Cursor and they'll show up right here. Hover me anytime.",
      ai: false
    ))
    haptics.play(.success)
    sounds.play(.success, settings: model.settings)
  }

  /// Back after a while away: a lock, or a sleep without one.
  private func cameBack() {
    guard let since = awaySince else { return }
    awaySince = nil
    guard Date.now.timeIntervalSince(since) >= Greeting.awayThreshold else { return }
    Task { await greet(.welcomeBack) }
  }

  // MARK: Feedback

  private func wireFeedback() {
    let previous = model.sessions.onTransitions
    model.sessions.onTransitions = { [weak self] transitions in
      previous?(transitions)
      guard let self else { return }
      feedback(for: transitions, settings: model.settings, focus: model.focus, sounds: sounds, haptics: haptics)
    }
    model.actions.feedback = { [weak self] kind in
      guard let self else { return }
      switch kind {
      case .approve:
        if !(model.settings.respectFocus && model.focus.active) { sounds.play(.approve, settings: model.settings) }
      case .commit:
        haptics.play(.commit)
      }
    }
  }

  // MARK: Settings

  /// What changes when a setting does: haptics, integrations, the battery,
  /// the tray, and quiet under a Focus.
  private func watchSettings() {
    track({ [model] in (model.settings, model.focus) }) { [weak self] (settings: IslandSettings, focus: MacFocus) in
      guard let self else { return }
      haptics.enabled = settings.haptics
      haptics.quiet = settings.respectFocus && focus.active
      model.sessions.enabledAgents = settings.agents
      if settings.battery { model.power.start() } else { model.power.stop() }
      syncTray(settings.tray || ProcessInfo.processInfo.environment["AGENT_ISLAND_TRAY"] == "1")
      if !settings.procStats { model.procStats = [:] }
      model.weather.update(enabled: settings.weather, units: settings.weatherUnits, location: settings.weatherLocation)
      if settings.updateCheck { model.updates.start() } else { model.updates.stop() }
      model.assistant.forceBasic = !settings.assistantModel || ProcessInfo.processInfo.environment["AGENT_ISLAND_FORCE_BASIC"] == "1"
      if !settings.assistant, model.ask.isOpen { model.ask.close() }
      if !settings.voice { model.ask.voiceIO.stopSpeaking() }
    }
    // Weather is ambient: the subtlest tap, except thunder arriving.
    model.weather.onChange = { [weak self] reading in
      self?.haptics.play(reading.condition == .thunder ? .rumble : .whisper)
    }
    track({ [model] in TrayStatus(model.sessions.sessions) }) { [weak self] status in
      TrayIcon.apply(status, to: self?.tray?.button)
    }
  }

  // MARK: Deep links

  /// agent-island://focus/on|off, ://toggle, ://settings.
  func open(_ url: URL) {
    guard let link = DeepLink(url) else {
      Log.app.notice("deep link ignored: \(url.absoluteString, privacy: .public)")
      return
    }
    Log.app.notice("deep link \(url.absoluteString, privacy: .public)")
    switch link {
    case let .focus(active, name): model.setFocus(MacFocus(active: active, name: name))
    case .toggle: model.pinned.toggle()
    case .settings: openSettings()
    case let .tools(name):
      model.pinned = true
      model.showTab(name.flatMap(HubTab.init(rawValue:)) ?? model.lastHubTab ?? model.hubTabs.first)
    case let .timer(minutes, label): model.timers.startCountdown(minutes: minutes, label: label)
    case .pomodoro: model.timers.startPomodoro()
    }
  }

  func openSettings() {
    windows.showSettings()
  }

  /// Launched again from Finder: the intro until it's been seen, Settings after.
  func reopen() {
    if !windows.maybeShowOnboarding() { windows.showSettings() }
  }

  /// A clicked notification: the update one opens the download.
  func openNotification(_ identifier: String) {
    if identifier.hasPrefix("update-") { model.updates.openDownload() }
  }

  // MARK: Tray

  private func syncTray(_ wanted: Bool) {
    if wanted, tray == nil {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      TrayIcon.apply(TrayStatus(model.sessions.sessions), to: item.button)
      let menu = TrayMenu(model: model)
      item.menu = menu.menu
      trayMenu = menu
      tray = item
    } else if !wanted, let item = tray {
      NSStatusBar.system.removeStatusItem(item)
      tray = nil
      trayMenu = nil
    }
  }

  // MARK: Resource meter

  /// The developer strip's servers and changes: sampled only while the panel
  /// is open on the sessions page, and never while the Mac is locked or asleep.
  private func watchDev() {
    track({ [model] in model.isExpanded && model.hubTab == nil && model.settings.devTools && !model.isPaused }) { [weak self] sampling in
      guard let self else { return }
      if sampling { model.dev.start { [model] in model.sessions.sessions } } else { model.dev.stop() }
    }
  }

  /// One `ps` every two seconds, only while the panel is open, the setting is
  /// on and some session reported its PID. Nothing polls unseen.
  private func watchMeter() {
    track({ [model] in model.isExpanded && model.settings.procStats && !model.isPaused }) { [weak self] sampling in
      guard let self else { return }
      sampler?.cancel()
      sampler = nil
      guard sampling else { return }
      sampler = Task { [weak self] in
        while !Task.isCancelled {
          guard let model = self?.model else { return }
          let roots = model.sessions.sessions.compactMap { session -> (String, Int)? in
            guard case let .number(pid)? = session.meta["pid"], pid > 0, pid == pid.rounded() else { return nil }
            return (session.key, Int(pid))
          }
          if !roots.isEmpty {
            let rows = ProcTotals.parse(await PS.read())
            var stats: [String: ProcTotals] = [:]
            for (key, pid) in roots { stats[key] = ProcTotals.subtree(rows, root: pid) }
            model.procStats = stats
          }
          do { try await Task.sleep(for: ProcTotals.interval) } catch { return }
        }
      }
    }
  }

  // MARK: Energy

  /// How long the closed island must look the same before its idle loops settle.
  static let settleAfter: Duration = .seconds(20)

  /// What the closed island looks like, as far as settling goes.
  private struct Look: Equatable {
    var open: Bool
    var hovering: Bool
    var wing: WingContent
    var working: Int
    var sleeping: Bool
    var idleBot: Bool
    var paused: Bool
  }

  /// Low Power Mode stills the wings. Any change to the island's look wakes
  /// its idle loops; `settleAfter` of sameness lets them settle again.
  private func watchEnergy() {
    observe(NotificationCenter.default, .NSProcessInfoPowerStateDidChange) { controller in
      let low = ProcessInfo.processInfo.isLowPowerModeEnabled
      if low != controller.model.lowPowerMode { controller.model.lowPowerMode = low }
    }
    var last: Look?
    track({ [model] in
      Look(
        open: model.isExpanded, hovering: model.isHovering, wing: model.wing, working: model.active.count,
        sleeping: model.isSleeping, idleBot: model.isIdleBot, paused: model.isPaused
      )
    }) { [weak self] look in
      guard let self, look != last else { return }
      last = look
      settle?.cancel()
      if model.settled { model.settled = false }
      settle = Task { [weak self] in
        do { try await Task.sleep(for: Self.settleAfter) } catch { return }
        self?.model.settled = true
      }
    }
  }

  // MARK: Requests

  /// ⌘Y/⌘N while an approval waits; ⌘1…9 while one single-select question
  /// does. Registered only then, released the moment it clears.
  private func watchRequests() {
    track({ [model] in model.pending.first?.pendingApproval?.id }) { [weak self] id in
      guard let self else { return }
      Log.app.notice("approval shortcuts for \(id ?? "none", privacy: .public)")
      if let id {
        hotKeys.register(.allow) { [weak self] in self?.model.actions.decide(id, allow: true) }
        hotKeys.register(.deny) { [weak self] in self?.model.actions.decide(id, allow: false) }
      } else {
        hotKeys.unregister(.allow)
        hotKeys.unregister(.deny)
      }
    }
    track({ [model] in model.asking.first?.pendingQuestion?.id }) { [weak self] _ in
      guard let self else { return }
      for index in 0..<9 { hotKeys.unregister(.option(index)) }
      guard let session = model.asking.first, let question = session.pendingQuestion,
        question.questions.count == 1, question.questions[0].multiSelect != true
      else { return }
      let count = min(9, question.questions[0].options.count)
      Log.app.notice("question shortcuts ⌘1…⌘\(count) for \(question.id, privacy: .public)")
      for index in 0..<count {
        hotKeys.register(.option(index)) { [weak self] in self?.model.actions.answer(session, selections: [[index]]) }
      }
    }
    // VoiceOver reach-in. Four modifiers on purpose: ⌥⌘I is every browser's
    // developer tools, and a global one would shadow it.
    if !hotKeys.register(.voiceOver, action: { [weak self] in self?.toggleVoiceOverFocus() }) {
      Log.app.error("could not register ⌃⌥⌘I: another app holds it")
    }
  }

  private func toggleVoiceOverFocus() {
    model.a11yFocused.toggle()
    Log.app.notice("VoiceOver island focus=\(self.model.a11yFocused)")
  }

  // MARK: Keys

  /// The island is normally non-focusable, so it never steals keystrokes from
  /// your terminal. It takes them only while you type a prompt or VoiceOver
  /// reaches in, then hands them straight back.
  private func watchKeys() {
    track({ [model] in (model.wantsKey, model.showsPrompt || model.ask.isOpen || model.hubTab != nil) }) { [weak self] (wants: Bool, fields: Bool) in
      guard let self else { return }
      // A visible field may take keys when clicked; typing and VoiceOver take them at once.
      panel.keyAllowed = wants || fields
      if wants {
        if !panel.isKeyWindow {
          previousApp = NSWorkspace.shared.frontmostApplication.flatMap { $0 == .current ? nil : $0 }
          if model.a11yFocused { NSApp.activate() }
          panel.makeKey()
        }
      } else if panel.isKeyWindow {
        panel.resignKey()
        previousApp?.activate()
        previousApp = nil
      }
    }
  }

  // MARK: VoiceOver

  /// One spoken sentence per update: a blocked agent can't wait for a gap in
  /// speech, a finished one can.
  private func announceTransitions() {
    let previous = model.sessions.onTransitions
    model.sessions.onTransitions = { transitions in
      previous?(transitions)
      guard let summary = SessionMarks.summary(transitions) else { return }
      NSAccessibility.post(
        element: NSApp as Any,
        notification: .announcementRequested,
        userInfo: [
          .announcement: summary.message,
          .priority: (summary.assertive ? NSAccessibilityPriorityLevel.high : .medium).rawValue,
        ]
      )
    }
  }

  /// Calls `onChange` with `value()` now, and again whenever what it reads
  /// changes. Every handler here is idempotent, so a repeat is harmless.
  private func track<T>(_ value: @escaping @MainActor () -> T, onChange: @escaping @MainActor (T) -> Void) {
    let current = withObservationTracking(value) { [weak self] in
      Task { @MainActor in self?.track(value, onChange: onChange) }
    }
    onChange(current)
  }

  /// The expanded island's ceiling on this display.
  private static func maxIslandWidth(on screen: NSScreen) -> CGFloat {
    min(720, screen.frame.width - 80)
  }

  /// The notched built-in display while it's on, else the one with the menu
  /// bar. (1.x took the menu bar's, which put the island on an external
  /// monitor set as main.)
  private static var targetScreen: NSScreen? { NSScreen.island }

  // MARK: Pointer

  private func watchPointer() {
    let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]) { [weak self] event in
      let type = event.type
      MainActor.assumeIsolated {
        guard let self else { return }
        switch type {
        case .leftMouseDown: self.dragStarted()
        case .leftMouseUp:
          self.dragEnded()
          self.releaseGrab()
        case .leftMouseDragged:
          // A drag that started on the island keeps carrying it, wherever the pointer goes.
          if self.grab != nil { self.carry(); return }
          self.dragMoved()
          self.pointerMoved()
        default: self.pointerMoved()
        }
      }
    }
    let local = NSEvent.addLocalMonitorForEvents(
      matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp, .scrollWheel]
    ) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self else { return }
        switch event.type {
        case .scrollWheel: self.scrolled(event)
        case .leftMouseDown: if event.window === self.panel { self.pressed() }
        case .leftMouseUp: self.releaseGrab()
        case .leftMouseDragged where self.grab != nil: self.carry()
        default: self.pointerMoved()
        }
      }
      return event
    }
    eventMonitors = [global, local].compactMap(\.self)
  }

  /// Hover follows the island's real shape, and so does click-through:
  /// outside it, clicks fall through to the menu bar and the desktop.
  private func pointerMoved() {
    // While a drag carries the island, the island keeps the mouse.
    guard grab?.moving != true else { return }
    let inside = islandContains(NSEvent.mouseLocation)
    if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
    guard inside else {
      hoverDwell?.cancel()
      hoverDwell = nil
      if model.isHovering { model.isHovering = false }
      gesture.reset()
      return
    }
    guard !model.isHovering else { return }
    // A side edge is where scroll bars and the Dock live: passing over the
    // island on the way there shouldn't open it.
    guard model.placement.isSide, !model.isExpanded else {
      model.isHovering = true
      return
    }
    guard hoverDwell == nil else { return }
    hoverDwell = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
      guard let self else { return }
      hoverDwell = nil
      if islandContains(NSEvent.mouseLocation), !model.isHovering { model.isHovering = true }
    }
  }

  /// What the hit-test shape depends on.
  private struct HitKey: Equatable {
    var placement: IslandPlacement
    var size: CGSize
    var corner: CGFloat
  }

  private func islandContains(_ point: CGPoint) -> Bool {
    let frame = panel.frame
    let placement = model.placement
    let key: HitKey
    let local: CGPoint
    if placement.isSide {
      let box = model.edgeBox
      key = HitKey(placement: placement, size: box.size, corner: model.isExpanded ? IslandOutline.expandedCorner : EdgeMetrics.depth / 2)
      // Into the island's box: top-left origin, y down. The pointer pushed
      // against the screen edge is clamped in, so it still hits.
      let x = point.x - frame.minX - box.minX
      local = CGPoint(x: placement == .right ? min(x, box.width - 0.5) : max(x, 0.5), y: frame.maxY - point.y - box.minY)
    } else {
      let size = model.bodySize
      key = HitKey(placement: .top, size: CGSize(width: size.width + 2 * IslandOutline.earRadius, height: size.height), corner: IslandOutline.expandedCorner)
      // The very top row of the screen counts, so a pointer pushed against the bezel still hits.
      local = CGPoint(x: point.x - (frame.midX - key.size.width / 2), y: max(frame.maxY - point.y, 0.5))
    }
    guard key.size.width > 0, key.size.height > 0 else { return false }
    if hitShape?.key != key {
      let ear = placement.isSide ? EdgeMetrics.ear : IslandOutline.earRadius
      let inner = IslandOutline.silhouette(key.size, on: placement, corner: key.corner, ear: ear)
      hitShape = (key, inner, inner.copy(strokingWithWidth: 20, lineCap: .round, lineJoin: .round, miterLimit: 1))
    }
    guard let shape = hitShape else { return false }
    if shape.inner.contains(local) { return true }
    // Once in, it takes 10 pt past the edge to leave, so the edge never flickers.
    return model.isHovering && shape.outer.contains(local)
  }

  // MARK: Drag and place

  /// A press on the island: the start of a click, or of a drag to another
  /// edge. Closed, it can be grabbed anywhere; open, only by its bezel side
  /// (the notch band on top, the strip along the edge on a side), so the
  /// panel's own buttons, fields and scrolling never pick it up.
  private func pressed() {
    let point = NSEvent.mouseLocation
    guard islandContains(point), !model.isExpanded || inGrip(point) else { return }
    grab = (point, false)
  }

  /// How far in from the bezel an open island can be grabbed.
  private static let grip: CGFloat = 14

  private func inGrip(_ point: CGPoint) -> Bool {
    let frame = panel.frame
    switch model.placement {
    case .top: return frame.maxY - point.y <= model.bandHeight
    case .left: return point.x - (frame.minX + model.edgeBox.minX) <= Self.grip
    case .right: return frame.minX + model.edgeBox.maxX - point.x <= Self.grip
    }
  }

  /// The island lifts off and follows the pointer; the nearest edge (with a
  /// little hysteresis) is where it would land.
  private func carry() {
    guard var grab, let screen = Self.targetScreen else { return }
    let point = NSEvent.mouseLocation
    if !grab.moving {
      // A few points of wobble is still a click.
      guard hypot(point.x - grab.start.x, point.y - grab.start.y) >= 6 else { return }
      grab.moving = true
      self.grab = grab
      hoverDwell?.cancel()
      hoverDwell = nil
      panel.ignoresMouseEvents = false
      overlay.show(on: screen)
      haptics.play(.tick)
    }
    NSCursor.closedHand.set()
    let frame = screen.frame
    let target = EdgeSnap.placement(at: point, in: frame, current: model.carry?.target ?? model.placement)
    let anchor = EdgeSnap.anchor(at: point, in: frame)
    if let previous = model.carry?.target, previous != target { haptics.play(.tick) }
    model.carry = Carry(
      point: CGPoint(x: point.x - frame.minX, y: frame.maxY - point.y),
      target: target,
      anchor: anchor,
      slot: slot(target, anchor: anchor, on: screen),
      zones: zones(on: screen)
    )
  }

  /// Let go: a drag flies into its slot and is saved; a press that never moved was a click.
  private func releaseGrab() {
    guard let grab else { return }
    self.grab = nil
    guard grab.moving, var landed = model.carry else { return }
    NSCursor.arrow.set()
    let moved = landed.target != model.settings.placement
    model.relocatedAt = .now
    landed.landing = true
    model.carry = landed
    // Saved now, while the island is still hidden: its window moves under the flight.
    model.changeSettings {
      $0.placement = landed.target
      if landed.target.isSide { $0.edgeAnchor = (Double(landed.anchor) * 1000).rounded() / 1000 }
    }
    Log.notch.notice("moved to \(landed.target.rawValue, privacy: .public) at \(landed.anchor, format: .fixed(precision: 2))")
    landing?.cancel()
    landing = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(340))
      guard let self else { return }
      model.carry = nil
      // Settling in: a quiet Apple Intelligence sheen runs round its edge.
      model.sessions.firePulse(.hello)
      haptics.play(moved ? .success : .tick)
      pointerMoved()
      try? await Task.sleep(for: .milliseconds(220))
      if model.carry == nil { overlay.orderOut(nil) }
    }
  }

  /// Where the resting island sits on `placement`'s edge, in the display's
  /// top-left coordinates: what the overlay's outline and flight aim at.
  private func slot(_ placement: IslandPlacement, anchor: CGFloat, on screen: NSScreen) -> CGRect {
    let frame = screen.frame
    let visible = screen.visibleFrame
    switch placement {
    case .top:
      // Never the bare notch: the outline shows the island with its wings.
      let width = max(model.collapsedWidth, model.notch.width + 84) + 2 * IslandOutline.earRadius
      return CGRect(x: (frame.width - width) / 2, y: 0, width: width, height: model.bandHeight)
    case .left, .right:
      let box = EdgeMetrics.restingBox
      let insets = screen.edgeInsets
      let canvas = CGSize(width: EdgeMetrics.canvasWidth, height: frame.height)
      let origin = EdgeMetrics.origin(box: box, canvas: canvas, placement: placement, anchor: anchor, top: insets.top, bottom: insets.bottom)
      let window = placement == .left ? visible.minX - frame.minX : visible.maxX - frame.minX - EdgeMetrics.canvasWidth
      return CGRect(x: window + origin.x, y: origin.y, width: box.width, height: box.height)
    }
  }

  /// Each edge's landing zone, for the glows: the notch, and each side's
  /// whole length between the menu bar and a bottom Dock.
  private func zones(on screen: NSScreen) -> [IslandPlacement: CGRect] {
    let frame = screen.frame
    let visible = screen.visibleFrame
    let insets = screen.edgeInsets
    let height = frame.height - insets.top - insets.bottom
    return [
      .top: slot(.top, anchor: 0, on: screen).insetBy(dx: -6, dy: 0),
      .left: CGRect(x: visible.minX - frame.minX, y: insets.top, width: 18, height: height),
      .right: CGRect(x: visible.maxX - frame.minX - 18, y: insets.top, width: 18, height: height),
    ]
  }

  /// Pins the window to the island's edge, whenever that edge or the display changes.
  private func watchPlacement() {
    track({ [model] in model.placement }) { [weak self] _ in self?.place() }
  }

  private func place() {
    guard let screen = Self.targetScreen else { return }
    panel.pin(to: screen, placement: model.placement)
    let insets = screen.edgeInsets
    if model.edgeTopInset != insets.top { model.edgeTopInset = insets.top }
    if model.edgeBottomInset != insets.bottom { model.edgeBottomInset = insets.bottom }
  }

  private func scrolled(_ event: NSEvent) {
    // Momentum is the tail of a swipe already decided, not a new one.
    guard event.window === panel, event.momentumPhase.isEmpty else { return }
    // Sideways: through the sessions page and every tool. On the closed
    // island it opens straight onto the tools.
    if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || sidewaysActive(at: event.timestamp) {
      sideways(event)
      return
    }
    let finger = WheelGesture.fingerDelta(
      scrollingDeltaY: event.scrollingDeltaY,
      invertedFromDevice: event.isDirectionInvertedFromDevice
    )
    let direction = gesture.feed(finger, at: event.timestamp)
    // The rubber band follows the fingers, then springs home once they stop.
    model.rubber = gesture.progress(at: event.timestamp)
    rubberReset?.cancel()
    rubberReset = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
      self?.model.rubber = 0
    }
    if let direction { model.swipe(direction) }
  }

  // MARK: Displays

  private func watchScreens() {
    observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { controller in
      controller.screensChanged()
    }
  }

  /// A resolution change, a display swap or docking moves the notch.
  private func screensChanged() {
    guard let screen = Self.targetScreen else { return }
    let notch = NotchMetrics(screen: screen)
    if notch != model.notch { model.notch = notch }
    model.maxIslandWidth = Self.maxIslandWidth(on: screen)
    place()
    Log.notch.notice("display changed: notch \(notch.width, format: .fixed(precision: 0)) real=\(notch.hasNotch)")
  }

  // MARK: Visibility

  private func watchVisibility() {
    let workspace = NSWorkspace.shared.notificationCenter
    observe(workspace, NSWorkspace.screensDidSleepNotification) {
      $0.asleep = true
      $0.awaySince = $0.awaySince ?? .now
    }
    observe(workspace, NSWorkspace.screensDidWakeNotification) { controller in
      controller.asleep = false
      // A wake without a lock screen still counts as coming back.
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(1500))
        if !controller.sessionInactive { controller.cameBack() }
      }
    }
    observe(workspace, NSWorkspace.sessionDidResignActiveNotification) {
      $0.sessionInactive = true
      $0.awaySince = $0.awaySince ?? .now
    }
    observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) {
      $0.sessionInactive = false
      $0.cameBack()
    }
    observe(NotificationCenter.default, NSWindow.didChangeOcclusionStateNotification, object: panel) { _ in }
  }

  private func updatePaused() {
    let hidden = !panel.occlusionState.contains(.visible)
    let paused = asleep || sessionInactive || hidden
    if paused != model.isPaused { model.isPaused = paused }
  }

  /// Runs `handler` on the main actor for each `name`, then re-derives the pause state.
  private func observe(
    _ center: NotificationCenter,
    _ name: Notification.Name,
    object: AnyObject? = nil,
    _ handler: @escaping @MainActor @Sendable (IslandController) -> Void
  ) {
    let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        handler(self)
        self.updatePaused()
      }
    }
    observers.append(token)
  }
}

/// Takes the first click even though the panel never becomes key. Not
/// generic: Swift 6.3's optimiser crashes inlining a generic one's deinit.
final class IslandHostingView: NSHostingView<IslandView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Quick access

extension IslandController {
  /// Starts each quick-access service while its setting is on, and feeds the
  /// open island what it shows (the browser's tab, a catch-up on music).
  fileprivate func wireQuickAccess() {
    track({ [model] in model.settings }) { [weak self] (settings: IslandSettings) in
      guard let self else { return }
      if settings.nowPlaying { model.media.start() } else { model.media.stop() }
      if settings.clipboardHistory { model.clipboard.start() } else { model.clipboard.stop() }
      if settings.meetings { model.meeting.start() } else { model.meeting.stop() }
      if settings.browserControls || settings.meetings { model.browser.start() } else { model.browser.stop() }
      if settings.agenda { model.agenda.start() } else { model.agenda.stop() }
      if !settings.teleprompter { model.prompter.stop() }
      if settings.tokenConfetti { tokenMilestones.start() } else { tokenMilestones.stop() }
      if !settings.shelf { model.shelf.dragActive = false }
      if let tab = model.hubTab, !model.hubTabs.contains(tab) { model.hubTab = nil }
    }
    model.meeting.frontMeetTab = { [model] in model.browser.meetTab }

    // Another million tokens today: confetti out of the notch (a bloom with
    // Reduce Motion), a tap, and a spoken line.
    tokenMilestones.onMilestone = { [weak self] mark in
      guard let self, !model.isPaused else { return }
      // Confetti comes out of the notch; a side island blooms instead.
      if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || model.placement.isSide {
        model.sessions.firePulse(.done)
      } else {
        model.celebrate()
      }
      haptics.play(.success)
      NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
        .announcement: "\(mark / TokenMilestones.step) million tokens today", .priority: NSAccessibilityPriorityLevel.medium.rawValue,
      ])
    }
    #if DEBUG
    // From a terminal: play a million-token burst (see README).
    let celebrate = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name(Log.subsystem + ".simulateMilestone"), object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.tokenMilestones.onMilestone(TokenMilestones.step) }
    }
    observers.append(celebrate)
    #endif

    // A rung timer: chime, bloom, tap, and a spoken line.
    model.timers.onFinish = { [weak self] timer in
      guard let self else { return }
      sounds.play(.timer, settings: model.settings)
      model.sessions.firePulse(.done)
      haptics.play(.success)
      let line = switch (timer.kind, timer.phase) {
      case (.countdown, _): timer.label.isEmpty ? "Timer done" : "Timer done: \(timer.label)"
      case (.pomodoro, .focus): "Focus round done. Take a break."
      case (.pomodoro, _): "Break's over."
      }
      NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
        .announcement: line, .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ])
    }

    // Opening: read the browser tab (and keep reading while open), and ask the
    // music apps once what they're already playing. Closing: back to sessions.
    track({ [model] in model.isExpanded && !model.isPaused }) { [weak self] open in
      guard let self else { return }
      browserPoll?.cancel()
      browserPoll = nil
      model.browser.live = open
      if open {
        pageReset?.cancel()
        // Each open spends one of the swipe hints.
        if model.swipeHintsLeft > 0, !hintCounted {
          hintCounted = true
          UserDefaults.standard.set(UserDefaults.standard.integer(forKey: "swipeHintsShown") + 1, forKey: "swipeHintsShown")
        }
        if model.settings.nowPlaying { model.media.catchUp() }
        if model.settings.agenda { model.agenda.refresh() }
        browserPoll = Task { [weak self] in
          while !Task.isCancelled {
            guard let model = self?.model else { return }
            // The tab shows only on the sessions page: read it only then.
            if model.settings.browserControls, model.browser.front != nil, model.hubTab == nil { await model.browser.refresh() }
            try? await Task.sleep(for: .seconds(3))
          }
        }
      } else {
        if hintCounted {
          hintCounted = false
          model.swipeHintsLeft = max(0, 6 - UserDefaults.standard.integer(forKey: "swipeHintsShown"))
        }
        // After the close has played out, so nothing swaps mid-animation.
        pageReset = Task { [weak self] in
          try? await Task.sleep(for: .milliseconds(500))
          guard !Task.isCancelled, let model = self?.model, !model.isExpanded else { return }
          model.hubTab = nil
        }
      }
    }

    readMenuBarHiding()
    let token = DistributedNotificationCenter.default().addObserver(
      forName: .init("AppleInterfaceMenuBarHidingChangedNotification"), object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.readMenuBarHiding() }
    }
    observers.append(token)
  }

  fileprivate func readMenuBarHiding() {
    let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain) ?? [:]
    let hidden = MenuBarHiding.isHidden(globalDefaults: global)
    if hidden != model.menuBarHidden { model.menuBarHidden = hidden }
  }

  // MARK: File drags

  /// A press starts what may become a drag: remember the drag pasteboard.
  fileprivate func dragStarted() {
    dragBaseline = NSPasteboard(name: .drag).changeCount
    dragCarriesFiles = false
  }

  /// A drag carrying files (or images, or text) that reaches the notch opens
  /// the shelf's drop zone; moving well away closes it again.
  fileprivate func dragMoved() {
    guard model.settings.shelf else { return }
    let pasteboard = NSPasteboard(name: .drag)
    if !dragCarriesFiles, pasteboard.changeCount != dragBaseline {
      let types = pasteboard.types ?? []
      dragCarriesFiles = types.contains(.fileURL) || types.contains(.tiff) || types.contains(.png)
        || types.contains(.string) || types.contains(NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData"))
        || types.contains(NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"))
    }
    guard dragCarriesFiles else { return }
    let point = NSEvent.mouseLocation
    let frame = panel.frame
    let reach: CGFloat = model.shelf.dragActive ? 260 : 46
    let halfWidth = (model.shelf.dragActive ? 260 : max(model.collapsedWidth / 2 + 40, 140))
    let near = abs(point.x - frame.midX) <= halfWidth && frame.maxY - point.y <= model.bandHeight + reach
    if near != model.shelf.dragActive { model.shelf.dragActive = near }
  }

  fileprivate func dragEnded() {
    dragCarriesFiles = false
    guard model.shelf.dragActive else { return }
    // Let a drop land before the zone goes.
    Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(350))
      self?.model.shelf.dragActive = false
      self?.model.shelf.targeted = nil
    }
  }

  // MARK: Sideways

  /// A sideways swipe holds the gesture until the fingers rest, so its
  /// vertical wobble never reads as a swipe up or down.
  fileprivate func sidewaysActive(at now: TimeInterval) -> Bool {
    now - sidewaysLast < 0.12 && sidewaysSum != 0
  }

  fileprivate func sideways(_ event: NSEvent) {
    let now = event.timestamp
    if now - sidewaysLast > 0.3 { sidewaysSum = 0 }
    sidewaysLast = now
    guard now >= sidewaysLockedUntil else { return }
    // Finger motion, whatever the scroll direction setting; a mouse wheel's
    // lines are scaled up to points.
    let raw = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 12
    let finger = event.isDirectionInvertedFromDevice ? raw : -raw
    sidewaysSum += finger
    // The page follows the fingers, then springs home once they stop.
    model.sideRubber = max(-1, min(1, -sidewaysSum / 26))
    sideReset?.cancel()
    sideReset = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
      self?.model.sideRubber = 0
    }
    guard abs(sidewaysSum) >= 26 else { return }
    // Fingers moving left bring in the page on the right, as on iPhone.
    let step = sidewaysSum < 0 ? 1 : -1
    if !model.isExpanded {
      guard step > 0 else { return reset() }
      model.openFromGesture()
    }
    model.stepPage(step)
    model.sideRubber = 0
    model.swiped()
    Log.app.notice("sideways swipe \(step) → \(self.model.hubTab?.rawValue ?? "sessions", privacy: .public)")
    haptics.play(.tick)
    reset()

    func reset() {
      sidewaysSum = 0.0001
      sidewaysLockedUntil = now + 0.4
    }
  }
}

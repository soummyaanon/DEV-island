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
  /// When the Mac was locked or slept, for the welcome-back hello.
  private var awaySince: Date?
  /// The app that was frontmost before the island took keys, to hand them back to.
  private var previousApp: NSRunningApplication?

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
    if let screen { panel.pin(to: screen) }
    panel.orderFrontRegardless()
    Log.notch.notice("notch \(self.model.notch.width, format: .fixed(precision: 0))×\(self.model.notch.height, format: .fixed(precision: 0)) real=\(self.model.notch.hasNotch)")

    model.onLayout = { [weak self] in self?.pointerMoved() }
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
    watchRequests()
    watchKeys()
    announceTransitions()
    model.openSettings = { [weak self] in self?.openSettings() }
    ZeroConfigPolicy.setUp(settings)
    windows.maybeShowOnboarding()
    wireFeedback()
    wireAssistant()
    watchSettings()
    watchMeter()
    Task { await greet(.launch) }
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
    ask.sessions = { [model] in model.sessions.sessions }
    ask.sendPrompt = { [model] text, session in _ = model.actions.sendPrompt(text, to: session) }
    ask.haptic = { [haptics] in haptics.play($0) }
    ask.speakReplies = { [model] in model.settings.speakReplies }
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
    track({ [model] in TrayTitle.title(model.sessions.sessions) }) { [weak self] title in
      self?.tray?.button?.title = title
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
    }
  }

  func openSettings() {
    windows.showSettings()
  }

  /// A clicked notification: the update one opens the download.
  func openNotification(_ identifier: String) {
    if identifier.hasPrefix("update-") { model.updates.openDownload() }
  }

  // MARK: Tray

  private func syncTray(_ wanted: Bool) {
    if wanted, tray == nil {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      item.button?.title = TrayTitle.title(model.sessions.sessions)
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
    track({ [model] in (model.wantsKey, model.showsPrompt || model.ask.isOpen) }) { [weak self] (wants: Bool, fields: Bool) in
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

  /// The primary display, like 1.x: the one with the menu bar on it.
  private static var targetScreen: NSScreen? { NSScreen.screens.first }

  // MARK: Pointer

  private func watchPointer() {
    let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
      MainActor.assumeIsolated { self?.pointerMoved() }
    }
    let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .scrollWheel]) { [weak self] event in
      MainActor.assumeIsolated {
        if event.type == .scrollWheel { self?.scrolled(event) } else { self?.pointerMoved() }
      }
      return event
    }
    eventMonitors = [global, local].compactMap(\.self)
  }

  /// Hover follows the island's real shape, and so does click-through:
  /// outside it, clicks fall through to the menu bar and the desktop.
  private func pointerMoved() {
    let inside = islandContains(NSEvent.mouseLocation)
    if inside != model.isHovering { model.isHovering = inside }
    if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
    if !inside { gesture.reset() }
  }

  private func islandContains(_ point: CGPoint) -> Bool {
    let size = model.bodySize
    guard size.width > 0, size.height > 0 else { return false }
    let outline = IslandOutline(width: size.width, height: size.height, corner: IslandOutline.expandedCorner)
    let frame = panel.frame
    // Into the island's box: top-left origin, y down. The very top row of the
    // screen counts, so a pointer pushed against the bezel still hits.
    let local = CGPoint(x: point.x - (frame.midX - outline.boxWidth / 2), y: max(frame.maxY - point.y, 0.5))
    let shape = outline.silhouette()
    if shape.contains(local) { return true }
    // Once in, it takes 10 pt past the edge to leave, so the edge never flickers.
    return model.isHovering && shape.copy(strokingWithWidth: 20, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(local)
  }

  private func scrolled(_ event: NSEvent) {
    // Momentum is the tail of a swipe already decided, not a new one.
    guard event.window === panel, event.momentumPhase.isEmpty else { return }
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
    panel.pin(to: screen)
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

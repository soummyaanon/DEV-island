import AppKit
import IslandCore
import SwiftUI

/// Settings and the first-run window. An accessory app has no Dock icon, so
/// it steps forward (regular) while one is open and back when it closes.
final class WindowsController: NSObject, NSWindowDelegate {
  private let model: IslandModel
  private let sounds: SoundPlayer
  private var settings: NSWindow?
  private var onboarding: NSWindow?
  private let settingsState = SettingsWindowState()
  let onboardingState = OnboardingState()
  private var trustPoll: Task<Void, Never>?

  init(model: IslandModel, sounds: SoundPlayer) {
    self.model = model
    self.sounds = sounds
  }

  // MARK: Settings

  func showSettings(section: SettingsWindowState.Section? = nil) {
    if let section { settingsState.section = section }
    if settings == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false
      )
      window.title = "Agent Island Settings"
      window.titlebarAppearsTransparent = true
      window.titleVisibility = .hidden
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: SettingsView(model: model, state: settingsState, sounds: sounds) { [weak self] agent, on in
        self?.applyIntegration(agent, on)
      })
      window.setFrameAutosaveName("AgentIslandSettings")
      window.center()
      window.delegate = self
      settings = window
    }
    present(settings)
  }

  /// Hooks follow the toggle: installed when on, removed cleanly when off.
  /// Codex needs nothing (its logs are read directly).
  private func applyIntegration(_ agent: AgentKind, _ on: Bool) {
    guard ZeroConfigPolicy.owns else { return }
    let config = ZeroConfig.standard
    switch (agent, on) {
    case (.claudeCode, true): ZeroConfigPolicy.report(config.setupClaude(), claude: true)
    case (.claudeCode, false): _ = config.removeClaude()
    case (.cursor, true): _ = config.setupCursor()
    case (.cursor, false): _ = config.removeCursor()
    case (.codex, _): break
    }
  }

  // MARK: Onboarding

  /// First run only (the same marker 1.x writes, so an upgrade doesn't repeat it).
  func maybeShowOnboarding() {
    guard !FileManager.default.fileExists(atPath: OnboardingState.flag.path) else { return }
    let window = OnboardingWindow()
    window.contentView = NSHostingView(rootView: OnboardingView(state: onboardingState) { [weak self] in self?.finishOnboarding() })
    window.center()
    window.delegate = self
    onboarding = window
    present(window)
    // The transparent window's shadow follows the card once card-in settles.
    Task { [weak window] in
      try? await Task.sleep(for: .milliseconds(600))
      window?.invalidateShadow()
    }
    // Reflect the Accessibility toggle live while the window is open.
    trustPoll = Task { [weak self] in
      while !Task.isCancelled {
        self?.onboardingState.refresh()
        try? await Task.sleep(for: .milliseconds(1200))
      }
    }
  }

  /// Closing the intro still counts as onboarded: never trap anyone.
  func finishOnboarding() {
    try? FileManager.default.createDirectory(at: OnboardingState.flag.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Date.now.ISO8601Format().write(to: OnboardingState.flag, atomically: true, encoding: .utf8)
    onboarding?.close()
  }

  // MARK: Windows

  private func present(_ window: NSWindow?) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
    window?.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_ notification: Notification) {
    let closing = notification.object as? NSWindow
    if closing === onboarding {
      trustPoll?.cancel()
      finishOnboarding()
      onboarding = nil
    }
    let othersOpen = [settings, onboarding].contains { $0 != nil && $0 !== closing && $0!.isVisible }
    if !othersOpen { NSApp.setActivationPolicy(.accessory) }
  }
}

/// Who installs the hooks. 2.0 does (as 1.x did); the side-by-side "Next"
/// build leaves them to 1.x unless AGENT_ISLAND_ZERO_CONFIG=1, so running and
/// quitting it during development never rewires anyone's Claude or Cursor.
enum ZeroConfigPolicy {
  static var owns: Bool {
    Bundle.main.bundleIdentifier == "com.agentisland.app" || ProcessInfo.processInfo.environment["AGENT_ISLAND_ZERO_CONFIG"] == "1"
  }

  static func report(_ result: HookInstaller.Result, claude: Bool) {
    Log.app.notice("zero-config \(claude ? "claude" : "cursor", privacy: .public): \(String(describing: result), privacy: .public)")
    guard claude, result == .installed || result == .updated, Bundle.main.bundleIdentifier != nil else { return }
    let content = UNMutableNotificationContent()
    content.title = "Agent Island"
    content.body = "Claude Code connected. Restart running claude sessions to see them here."
    Task {
      _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
      try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "zero-config", content: content, trigger: nil))
    }
  }

  /// At launch: wire the enabled agents.
  static func setUp(_ settings: IslandSettings) {
    guard owns else { return }
    let config = ZeroConfig.standard
    if settings.agents.contains(.claudeCode) { report(config.setupClaude(), claude: true) }
    if settings.agents.contains(.cursor) { report(config.setupCursor(), claude: false) }
  }

  /// At quit: the HTTP hooks point at the daemon we're about to stop, and
  /// left behind they'd error every tool call. They come back next launch.
  static func tearDown() {
    guard owns else { return }
    let config = ZeroConfig.standard
    _ = config.removeClaude()
    _ = config.removeCursor()
  }
}

import UserNotifications

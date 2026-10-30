import AppKit
import Foundation
import IslandCore
import Observation

/// The browser you last used: its current tab, and back, forward and reload.
///
/// It stays the island's browser after you switch to another app, until you
/// use a different browser or quit it, so a glance from your terminal still
/// shows the page you left. The tab is read only while the island is open
/// (AppleScript for Safari and Chromium browsers, the window title for Firefox).
@Observable
final class BrowserService {
  struct Tab: Equatable {
    var title: String
    var url: String
  }

  private(set) var front: Browser?
  private(set) var tab: Tab?

  /// Reading its tab needs macOS's Automation permission: nil until asked.
  private(set) var allowed: Bool?

  /// The island is open and showing the tab: only then is a switch worth a read.
  @ObservationIgnored var live = false
  @ObservationIgnored private var frontPID: pid_t?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var reading = false

  func start() {
    guard observers.isEmpty else { return }
    let center = NSWorkspace.shared.notificationCenter
    observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      let id = app?.bundleIdentifier
      let pid = app?.processIdentifier
      MainActor.assumeIsolated { self?.activated(id, pid: pid) }
    })
    // Quitting the browser is the one thing that forgets it.
    observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
      let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
      MainActor.assumeIsolated {
        guard let self, pid != nil, pid == self.frontPID else { return }
        self.front = nil
        self.frontPID = nil
        self.tab = nil
      }
    })
    // At launch: the browser in front, else the most recently used one still running.
    let app = NSWorkspace.shared.frontmostApplication
    if Browser.named(bundleId: app?.bundleIdentifier) != nil {
      activated(app?.bundleIdentifier, pid: app?.processIdentifier)
    } else if let running = NSWorkspace.shared.runningApplications.first(where: { Browser.named(bundleId: $0.bundleIdentifier) != nil }) {
      activated(running.bundleIdentifier, pid: running.processIdentifier)
    }
  }

  func stop() {
    for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    observers = []
    front = nil
    frontPID = nil
    tab = nil
  }

  private func activated(_ bundleId: String?, pid: pid_t?) {
    // Another app coming forward (the island's Settings, your terminal) isn't
    // leaving the browser: only a different browser replaces it.
    guard let browser = Browser.named(bundleId: bundleId) else { return }
    if browser != front || pid != frontPID { tab = nil }
    front = browser
    frontPID = pid
    allowed = Automation.isAllowed(browser.bundleId)
    // Open, the new browser's tab shows now rather than on the next poll.
    if live { Task { await refresh() } }
  }

  /// Brings the browser (and the window whose tab the island shows) to the
  /// front. The first time, macOS asks whether the island may read its tabs.
  func bringForward() {
    guard let front else { return }
    if let pid = frontPID, let app = NSRunningApplication(processIdentifier: pid),
      let url = app.bundleURL
    {
      // Through Launch Services: a background app's own `activate()` is
      // ignored since macOS 14 unless it's already in front.
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = true
      NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
    guard allowed != true else { return }
    let bundleId = front.bundleId
    Task {
      let granted = await OffMain.value(timeout: 120) { Automation.ask(bundleId) }
      guard self.front?.bundleId == bundleId else { return }
      allowed = granted ?? false
      await refresh()
    }
  }

  /// Reads the front tab now (the island just opened, or it's open and polling).
  func refresh() async {
    guard let front, !reading else { return }
    reading = true
    defer { reading = false }
    if let script = front.activeTabScript {
      // Reading the tab is a background read: only once you've allowed it
      // (your first back/forward/reload click asks).
      guard Automation.isAllowed(front.bundleId) == true else { return }
      guard let out = await Osascript.run(script, timeout: 2), let parsed = Browser.parseActiveTab(out) else { return }
      guard self.front == front else { return }
      let next = Tab(title: parsed.title, url: parsed.url)
      if next != tab { tab = next }
    } else if let pid = frontPID, let title = MenuReader.focusedWindowTitle(of: pid) {
      let cleaned = title.replacingOccurrences(of: " — Mozilla Firefox", with: "").replacingOccurrences(of: " - Mozilla Firefox", with: "")
      tab = Tab(title: cleaned, url: "")
    }
  }

  /// The front tab is a Meet call (for the meeting detector).
  var meetTab: (bundle: String, url: String)? {
    guard let front, let tab, MeetingLink.isMeetCall(tab.url) else { return nil }
    return (front.bundleId, tab.url)
  }

  func perform(_ command: Browser.Command) {
    guard let front else { return }
    // Keys first where AppleScript can't (Safari's history, Firefox).
    if let script = front.script(command), front.family == .chromium || !Accessibility.isTrusted {
      Osascript.send(script)
    } else {
      switch command {
      case .back: KeyPoster.press(KeyPoster.leftBracket, .maskCommand, to: frontPID)
      case .forward: KeyPoster.press(KeyPoster.rightBracket, .maskCommand, to: frontPID)
      case .reload: KeyPoster.press(15 /* R */, .maskCommand, to: frontPID)
      }
    }
    Task {
      try? await Task.sleep(for: .milliseconds(700))
      await refresh()
    }
  }

  func copyLink() {
    guard let url = tab?.url, !url.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url, forType: .string)
  }
}

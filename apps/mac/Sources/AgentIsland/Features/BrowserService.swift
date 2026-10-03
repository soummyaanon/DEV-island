import AppKit
import Foundation
import IslandCore
import Observation

/// The browser in front: its current tab, and back, forward and reload.
///
/// The island never takes focus, so the browser stays frontmost while you use
/// it. The tab is read only while the island is open (AppleScript for Safari
/// and Chromium browsers, the window title for Firefox).
@Observable
final class BrowserService {
  struct Tab: Equatable {
    var title: String
    var url: String
  }

  private(set) var front: Browser?
  private(set) var tab: Tab?

  @ObservationIgnored private var frontPID: pid_t?
  @ObservationIgnored private var observer: NSObjectProtocol?
  @ObservationIgnored private var reading = false

  func start() {
    guard observer == nil else { return }
    observer = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      let id = app?.bundleIdentifier
      let pid = app?.processIdentifier
      MainActor.assumeIsolated { self?.activated(id, pid: pid) }
    }
    let app = NSWorkspace.shared.frontmostApplication
    activated(app?.bundleIdentifier, pid: app?.processIdentifier)
  }

  func stop() {
    if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    observer = nil
    front = nil
    tab = nil
  }

  private func activated(_ bundleId: String?, pid: pid_t?) {
    // The island itself (Settings) coming forward isn't leaving the browser.
    guard bundleId != Bundle.main.bundleIdentifier else { return }
    let browser = Browser.named(bundleId: bundleId)
    if browser != front { tab = nil }
    front = browser
    frontPID = browser == nil ? nil : pid
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

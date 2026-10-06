import AppKit
import Carbon.HIToolbox
import Foundation
import IslandCore
import Observation

/// Zoom and Google Meet calls: how long you've been on, and mute, camera and
/// leave without hunting for the window.
///
/// Zoom is recognised by the helper it runs only during a meeting, and driven
/// through its own Meeting menu (Accessibility), so the mute state is real.
/// Meet is a browser tab: looked for only while some app holds the microphone,
/// and driven with Meet's own shortcuts (⌘D, ⌘E) in that tab.
@Observable
final class MeetingService {
  struct Call: Equatable {
    var source: MeetingSignals.Source
    var since: Date
  }

  private(set) var call: Call?
  /// Zoom says; for Meet it's what the island last toggled (nil: unknown).
  private(set) var muted: Bool?
  private(set) var videoOn: Bool?
  /// The browser in front is on a Meet call (from `BrowserService`), checked first.
  @ObservationIgnored var frontMeetTab: () -> (bundle: String, url: String)? = { nil }

  @ObservationIgnored private var poll: Task<Void, Never>?
  @ObservationIgnored private var checkingTabs = false
  @ObservationIgnored private var lastTabCheck = Date.distantPast
  @ObservationIgnored private var cachedMeetTab: (bundle: String, url: String)?

  func start() {
    guard poll == nil else { return }
    poll = Task { [weak self] in
      while !Task.isCancelled {
        await self?.check()
        try? await Task.sleep(for: .seconds(3))
      }
    }
  }

  func stop() {
    poll?.cancel()
    poll = nil
    call = nil
  }

  private var zoomApp: NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: MeetingSignals.zoomBundle).first
  }

  private func check() async {
    let zoom = zoomApp
    let names = zoom != nil ? ProcessNames.all() : []
    let meet = await meetTab()
    let source = MeetingSignals.source(zoomRunning: zoom != nil, processNames: names, meetTab: meet)
    if source != call?.source {
      call = source.map { Call(source: $0, since: call?.source == $0 ? call!.since : .now) }
      if source == nil || source != .zoom {
        muted = nil
        videoOn = nil
      }
    }
    if case .zoom? = source, let zoom { readZoomState(zoom.processIdentifier) }
  }

  /// A Meet call in the front browser, else (while the mic is open) in any
  /// running browser, checked at most every ten seconds.
  private func meetTab() async -> (bundle: String, url: String)? {
    if let front = frontMeetTab() { return front }
    // Core Audio only once there's a browser a Meet tab could be in.
    let browsers = NSWorkspace.shared.runningApplications.filter { Browser.named(bundleId: $0.bundleIdentifier)?.allTabsScript != nil }
    guard !browsers.isEmpty, await AudioDevices.micInUse() else {
      cachedMeetTab = nil
      return nil
    }
    guard !checkingTabs, Date.now.timeIntervalSince(lastTabCheck) > 10 else { return cachedMeetTab }
    checkingTabs = true
    defer { checkingTabs = false }
    lastTabCheck = .now
    cachedMeetTab = nil
    for app in browsers {
      // Only browsers already allowed: detection must never prompt.
      guard let browser = Browser.named(bundleId: app.bundleIdentifier), let script = browser.allTabsScript,
        Automation.isAllowed(browser.bundleId) == true, let out = await Osascript.run(script)
      else { continue }
      if let url = out.split(separator: "\n").map(String.init).first(where: MeetingLink.isMeetCall) {
        cachedMeetTab = (browser.bundleId, url)
        break
      }
    }
    return cachedMeetTab
  }

  private func readZoomState(_ pid: pid_t) {
    let titles = Set(MenuReader.items(of: pid).map { $0.title.lowercased() })
    guard !titles.isEmpty else { return }
    if titles.contains("unmute audio") { muted = true } else if titles.contains("mute audio") { muted = false }
    if titles.contains("stop video") { videoOn = true } else if titles.contains("start video") { videoOn = false }
  }

  // MARK: Controls

  func toggleMute() {
    guard let call else { return }
    switch call.source {
    case .zoom:
      guard let zoom = zoomApp else { return }
      if !MenuReader.press(["Mute Audio", "Unmute Audio"], in: zoom.processIdentifier) {
        KeyPoster.press(kVK_ANSI_A, [.maskCommand, .maskShift], to: zoom.processIdentifier)
      }
      muted = muted.map(!)
      Task {
        try? await Task.sleep(for: .milliseconds(300))
        readZoomState(zoom.processIdentifier)
      }
    case let .meet(bundle, url):
      meetShortcut(kVK_ANSI_D, bundle: bundle, url: url)
      muted = !(muted ?? false)
    }
  }

  func toggleVideo() {
    guard let call else { return }
    switch call.source {
    case .zoom:
      guard let zoom = zoomApp else { return }
      if !MenuReader.press(["Start Video", "Stop Video"], in: zoom.processIdentifier) {
        KeyPoster.press(kVK_ANSI_V, [.maskCommand, .maskShift], to: zoom.processIdentifier)
      }
      videoOn = videoOn.map(!)
      Task {
        try? await Task.sleep(for: .milliseconds(300))
        readZoomState(zoom.processIdentifier)
      }
    case let .meet(bundle, url):
      meetShortcut(kVK_ANSI_E, bundle: bundle, url: url)
      videoOn = !(videoOn ?? true)
    }
  }

  /// Zoom: its own Leave (it may ask "Leave meeting?"). Meet: closes the tab.
  func leave() {
    guard let call else { return }
    switch call.source {
    case .zoom:
      guard let zoom = zoomApp else { return }
      if !MenuReader.press(["Leave Meeting", "End Meeting", "Leave"], in: zoom.processIdentifier) {
        zoom.activate()
        KeyPoster.press(kVK_ANSI_W, .maskCommand, to: zoom.processIdentifier)
      }
    case let .meet(bundle, url):
      guard let browser = Browser.named(bundleId: bundle) else { return }
      if let script = browser.closeTabScript(url: url) {
        Osascript.send(script)
      }
      self.call = nil
      cachedMeetTab = nil
    }
  }

  /// Brings the call's tab forward, then sends Meet's shortcut to it.
  private func meetShortcut(_ key: Int, bundle: String, url: String) {
    guard let browser = Browser.named(bundleId: bundle), let script = browser.focusTabScript(url: url) else { return }
    Task {
      _ = await Osascript.run(script)
      try? await Task.sleep(for: .milliseconds(250))
      let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier
      KeyPoster.press(key, .maskCommand, to: pid)
    }
  }

  /// Brings the call's window forward.
  func show() {
    guard let call else { return }
    switch call.source {
    case .zoom:
      zoomApp?.activate()
    case let .meet(bundle, url):
      if let script = Browser.named(bundleId: bundle)?.focusTabScript(url: url) { Osascript.send(script) }
    }
  }
}

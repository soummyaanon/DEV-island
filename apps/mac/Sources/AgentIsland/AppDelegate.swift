import AppKit
import IslandCore
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  private var island: IslandController?

  func applicationWillFinishLaunching(_ notification: Notification) {
    // An accessory: no Dock icon, no menu bar of its own.
    NSApp.setActivationPolicy(.accessory)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard !SingleInstance.anotherIsRunning else {
      NSApp.terminate(nil)
      return
    }
    installEditMenu()
    if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
    island = IslandController(settings: .load())
    for url in pendingURLs { island?.open(url) }
    pendingURLs.removeAll()
  }

  func applicationWillTerminate(_ notification: Notification) {
    ZeroConfigPolicy.tearDown()
  }

  /// Launched again from Finder: the intro if it hasn't been seen, else Settings.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    island?.reopen()
    return false
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
    let identifier = response.notification.request.identifier
    await MainActor.run { island?.openNotification(identifier) }
  }

  nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }

  /// agent-island:// links, including one that launched the app.
  private var pendingURLs: [URL] = []

  func application(_ application: NSApplication, open urls: [URL]) {
    guard let island else {
      pendingURLs += urls
      return
    }
    for url in urls { island.open(url) }
  }
}

/// Never shown (an accessory has no menu bar), but ⌘V, ⌘C, ⌘X, ⌘A and ⌘Z
/// reach text fields through the main menu's key equivalents.
@MainActor private func installEditMenu() {
  let edit = NSMenu(title: "Edit")
  edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
  edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
  edit.addItem(.separator())
  edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
  edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
  edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
  edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
  let main = NSMenu()
  main.addItem(NSMenuItem(title: "Agent Island", action: nil, keyEquivalent: ""))
  let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
  editItem.submenu = edit
  main.addItem(editItem)
  NSApp.mainMenu = main
}

enum SingleInstance {
  /// Another copy of this bundle is already running. An unbundled `swift run`
  /// has no bundle id and can't tell, so it always starts.
  static var anotherIsRunning: Bool {
    guard let id = Bundle.main.bundleIdentifier else { return false }
    let me = ProcessInfo.processInfo.processIdentifier
    return NSRunningApplication.runningApplications(withBundleIdentifier: id)
      .contains { $0.processIdentifier != me }
  }
}

enum LoginItem {
  /// Only a bundled app can be a login item.
  static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

  static var isEnabled: Bool {
    get { SMAppService.mainApp.status == .enabled }
    set {
      do {
        if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
      } catch {
        Log.app.error("Login item \(newValue ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }
}

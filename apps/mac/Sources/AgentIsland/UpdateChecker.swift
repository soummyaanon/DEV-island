import AppKit
import Foundation
import IslandCore
import Observation
import UserNotifications

/// Update notifier (1.x's update-check.ts): one anonymous request to the
/// public releases feed at launch and hourly. A newer version shows a chip in
/// the footer and, once per version, a notification. Install downloads the
/// DMG and hands a detached script the bundle swap. Opt out in Settings or
/// with AGENT_ISLAND_NO_UPDATE_CHECK=1.
@Observable
final class UpdateChecker {
  /// The newest version seen, when it's newer than this one.
  private(set) var available: String?

  @ObservationIgnored private var loop: Task<Void, Never>?

  static var currentVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
  }

  private static var notifiedURL: URL {
    IslandSettings.userData.appending(path: "last-notified-version")
  }

  func start() {
    guard ProcessInfo.processInfo.environment["AGENT_ISLAND_NO_UPDATE_CHECK"] != "1", loop == nil else { return }
    loop = Task { [weak self] in
      // Give launch a moment first.
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      while !Task.isCancelled {
        await self?.check()
        do { try await Task.sleep(for: Updates.every) } catch { return }
      }
    }
  }

  func stop() {
    loop?.cancel()
    loop = nil
  }

  /// A check right now (Settings → Check for Updates). Never disturbs the app.
  func check() async {
    var request = URLRequest(url: Updates.latestRelease)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "accept")
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      (response as? HTTPURLResponse)?.statusCode == 200,
      let release = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let tag = release["tag_name"] as? String,
      Updates.isNewer(tag, than: Self.currentVersion)
    else { return }
    let version = tag.replacing(/^[vV]/, with: "")
    available = version
    guard (try? String(contentsOf: Self.notifiedURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) != tag else { return }
    try? tag.write(to: Self.notifiedURL, atomically: true, encoding: .utf8)
    await notify(version)
  }

  private func notify(_ version: String) async {
    guard Bundle.main.bundleIdentifier != nil else { return }
    let center = UNUserNotificationCenter.current()
    guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
    let content = UNMutableNotificationContent()
    content.title = "Agent Island update"
    content.body = "Version \(version) is available — click to download."
    try? await center.add(UNNotificationRequest(identifier: "update-\(version)", content: content, trigger: nil))
  }

  func openDownload() {
    NSWorkspace.shared.open(Updates.directDownload)
  }

  /// Downloads the DMG and swaps the bundle once we've quit. Only a packaged
  /// 2.0 replaces itself; anything else just opens the download.
  func install() async -> Bool {
    guard Bundle.main.bundleIdentifier == "com.agentisland.app" else {
      openDownload()
      return false
    }
    do {
      let (file, response) = try await URLSession.shared.download(from: Updates.directDownload)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
      let dmg = FileManager.default.temporaryDirectory.appending(path: "Agent-Island-update.dmg")
      try? FileManager.default.removeItem(at: dmg)
      try FileManager.default.moveItem(at: file, to: dmg)
      let script = FileManager.default.temporaryDirectory.appending(path: "agent-island-update.sh")
      try Updates.installerScript(dmg: dmg.path, app: Bundle.main.bundlePath).write(to: script, atomically: true, encoding: .utf8)
      let process = Process()
      process.executableURL = URL(filePath: "/bin/zsh")
      process.arguments = [script.path]
      try process.run()
      try await Task.sleep(for: .milliseconds(400))
      NSApp.terminate(nil)
      return true
    } catch {
      Log.app.error("update install failed: \(error.localizedDescription, privacy: .public)")
      return false
    }
  }
}

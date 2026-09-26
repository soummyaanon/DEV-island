import Foundation

/// Moving in from 1.x: the Electron app shares 2.0's folder, bundle id and
/// hooks, so almost everything carries over as is. What doesn't: Chromium's
/// own files in that folder, and 1.x's Node daemon if it outlived the app.
public enum Migration {
  /// Chromium's files in Electron's userData; 1.x's own (settings.json,
  /// onboarded, weather-cache.json, last-notified-version, sounds/) stay.
  public static let electronLeftovers = [
    "Cache", "Code Cache", "Cookies", "Cookies-journal", "DIPS", "DawnGraphiteCache", "DawnWebGPUCache",
    "GPUCache", "Local Storage", "Network Persistent State", "Preferences", "Session Storage",
    "Shared Dictionary", "SharedStorage", "TransportSecurity", "Trust Tokens", "Trust Tokens-journal",
    "blob_storage", "Crashpad", "IndexedDB", "Service Worker", "WebStorage",
  ]

  /// Written once the folder's been tidied, so it happens once.
  public static let marker = "migrated-2.0"

  /// Whether a process listening on the daemon's port is 1.x's bundled Node
  /// daemon: Electron forks it as a utility process of its own helper
  /// (`Agent Island Helper --type=utility …`). A daemon a developer runs by
  /// hand (`node …`) is left alone.
  public static func isElectronDaemon(command: String) -> Bool {
    command.contains("Agent Island Helper") && command.contains("--type=utility")
  }
}

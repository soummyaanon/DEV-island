import Foundation
import os

nonisolated enum Log {
  /// The running bundle's id: `com.agentisland.app` shipped, `.next` side by side.
  static let subsystem = Bundle.main.bundleIdentifier ?? "com.agentisland.app.next"

  static let app = Logger(subsystem: subsystem, category: "app")
  static let notch = Logger(subsystem: subsystem, category: "notch")
  static let daemon = Logger(subsystem: subsystem, category: "daemon")
  static let power = Logger(subsystem: subsystem, category: "power")
}

// swift-tools-version: 6.2
import PackageDescription

/// Approachable Concurrency: `async` stays on the caller's actor unless a
/// function says `@concurrent`, and conformances pick up their type's isolation.
let approachable: [SwiftSetting] = [
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
  .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
  name: "AgentIsland",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "AgentIsland", targets: ["AgentIsland"]),
  ],
  targets: [
    // Pure logic, no AppKit: pmset parsing, the island's outline, the swipe
    // detector, settings. A library, so it stays nonisolated and callers decide
    // where it runs. Everything worth a test lives here.
    .target(
      name: "IslandCore",
      swiftSettings: approachable
    ),
    // The app: one process, main actor by default.
    .executableTarget(
      name: "AgentIsland",
      dependencies: ["IslandCore"],
      swiftSettings: approachable + [.defaultIsolation(MainActor.self)],
      linkerSettings: [.linkedFramework("IOKit")]
    ),
    .testTarget(
      name: "IslandCoreTests",
      dependencies: ["IslandCore"],
      swiftSettings: approachable
    ),
  ]
)

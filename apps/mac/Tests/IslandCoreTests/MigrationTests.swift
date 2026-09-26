import IslandCore
import Testing

@Suite struct MigrationTests {
  @Test func `tidies Chromium's files and keeps 1.x's own`() {
    for kept in ["settings.json", "onboarded", "weather-cache.json", "last-notified-version", "sounds"] {
      #expect(!Migration.electronLeftovers.contains(kept))
    }
    #expect(Migration.electronLeftovers.contains("GPUCache"))
    #expect(Migration.electronLeftovers.contains("Local Storage"))
  }

  @Test func `knows 1.x's bundled daemon from anything else on the port`() {
    #expect(Migration.isElectronDaemon(command: "/Applications/Agent Island.app/Contents/Frameworks/Agent Island Helper.app/Contents/MacOS/Agent Island Helper --type=utility --utility-sub-type=node.mojom.NodeService --lang=en-US"))
    #expect(!Migration.isElectronDaemon(command: "/Applications/Agent Island.app/Contents/MacOS/AgentIsland"))
    #expect(!Migration.isElectronDaemon(command: "node packages/daemon/dist/main.cjs"))
    #expect(!Migration.isElectronDaemon(command: "/Applications/Agent Island.app/Contents/Frameworks/Agent Island Helper (GPU).app/Contents/MacOS/Agent Island Helper (GPU) --type=gpu-process"))
  }
}

import AppKit

// Plain AppKit, not a SwiftUI `App`: an app with no scenes of its own would
// get an empty window from SwiftUI. The island hosts SwiftUI in its panel;
// Settings (phase 6) will host it in a window the same way.
// `--render-icon <file.png>`: write the app icon's master and quit (scripts/icon.sh).
if let flag = CommandLine.arguments.firstIndex(of: "--render-icon"), flag + 1 < CommandLine.arguments.count {
  do {
    try IconRenderer.render(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
    exit(0)
  } catch {
    FileHandle.standardError.write(Data("render-icon: \(error)\n".utf8))
    exit(1)
  }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

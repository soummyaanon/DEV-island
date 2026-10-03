#if DEBUG
import AppKit
import IslandCore
import SwiftUI

/// `--render-preview <folder>` (debug builds): draws the open island's pages
/// to PNGs, for checking layout without a notch in front of you.
enum PreviewRenderer {
  static func render(to folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let sessions = SessionStore()
    let model = IslandModel(
      notch: NotchMetrics(width: 185, height: 32, hasNotch: true), settings: IslandSettings(), power: PowerMonitor(),
      sessions: sessions, actions: IslandActions(daemon: DaemonClient(store: sessions), store: sessions)
    )
    model.timers.startPomodoro()
    model.timers.startCountdown(minutes: 3, label: "Tea")
    model.agenda.addTodo("Ship the quick-access layer")
    model.shelf.add(urls: [URL(filePath: "/Applications/Safari.app"), URL(filePath: "/System/Applications/Notes.app")])
    var pages: [(String, AnyView)] = [("now", AnyView(Panel(model: model)))]
    for tab in HubTab.allCases where tab != .ask {
      pages.append((tab.rawValue, AnyView(HubPage(model: model, tab: tab, now: .now))))
    }
    model.agentStats.refreshIfStale()
    let until = Date.now.addingTimeInterval(8)
    while model.agentStats.updated == nil, Date.now < until { RunLoop.main.run(until: .now.addingTimeInterval(0.1)) }
    model.system.detail = .displays
    model.system.refresh(full: false)
    pages.append(("controls-displays", AnyView(HubPage(model: model, tab: .controls, now: .now))))
    pages.append(("displays", AnyView(DisplaysDetail(system: model.system).frame(width: 420))))
    pages.append(("drop", AnyView(ShelfDropZone(model: model))))
    pages.append(("prompter-stage", AnyView(PrompterStage(model: model))))
    for (name, page) in pages {
      FileHandle.standardError.write(Data("render \(name)\n".utf8))
      let view = page
        .environment(\.uiScale, 1)
        .frame(width: name == "now" ? 460 : nil)
        .fixedSize(horizontal: false, vertical: true)
        .background(.black)
        .environment(\.colorScheme, .dark)
      let renderer = ImageRenderer(content: view)
      renderer.scale = 2
      renderer.proposedSize = ProposedViewSize(width: 460, height: 600)
      guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
        let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
      else { continue }
      try png.write(to: folder.appending(path: "\(name).png"))
    }
  }
}
#endif

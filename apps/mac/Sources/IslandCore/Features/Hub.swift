import Foundation

/// The open island's second page: quick-access tools, one tab at a time.
/// The first page stays what it always was (sessions), plus whatever is
/// happening right now (a call, a timer, music, the browser in front).
public enum HubTab: String, Sendable, CaseIterable, Identifiable {
  case agents, controls, shelf, clipboard, agenda, timers, widgets, prompter, ask

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .agents: "Agents"
    case .controls: "Controls"
    case .shelf: "Files"
    case .clipboard: "Clipboard"
    case .agenda: "Today"
    case .timers: "Timers"
    case .widgets: "Widgets"
    case .prompter: "Prompter"
    case .ask: "Ask"
    }
  }

  public var symbol: String {
    switch self {
    case .agents: "chart.bar.xaxis"
    case .controls: "slider.horizontal.3"
    case .shelf: "tray.full"
    case .clipboard: "doc.on.clipboard"
    case .agenda: "calendar"
    case .timers: "timer"
    case .widgets: "square.grid.2x2"
    case .prompter: "text.alignleft"
    case .ask: "sparkles"
    }
  }

  /// The tabs these settings switch on, in order.
  public static func enabled(_ settings: IslandSettings) -> [HubTab] {
    allCases.filter { tab in
      switch tab {
      case .agents: settings.agentStats
      case .controls: settings.quickControls
      case .shelf: settings.shelf
      case .clipboard: settings.clipboardHistory
      case .agenda: settings.agenda
      case .timers: settings.timers
      case .widgets: settings.widgets
      case .prompter: settings.teleprompter
      case .ask: settings.assistant
      }
    }
  }

  /// One step left or right through `tabs`; stepping left off the first goes
  /// back to the sessions page (nil), and right from there to the first tab.
  public static func step(from current: HubTab?, by delta: Int, in tabs: [HubTab]) -> HubTab? {
    guard !tabs.isEmpty else { return nil }
    // Index 0 is the sessions page; tabs follow.
    let pages: [HubTab?] = [nil] + tabs
    let index = pages.firstIndex(of: current) ?? 0
    let next = min(max(0, index + delta), pages.count - 1)
    return pages[next]
  }
}

/// Whether the menu bar hides itself (System Settings → Control Centre →
/// "Automatically hide and show the menu bar"), from its global default.
public enum MenuBarHiding {
  public static func isHidden(globalDefaults: [String: Any]) -> Bool {
    (globalDefaults["_HIHideMenuBar"] as? Bool) ?? ((globalDefaults["_HIHideMenuBar"] as? Int) ?? 0 != 0)
  }
}

import Foundation

/// Video-call links in calendar events and browser tabs.
public enum MeetingLink {
  public enum Service: String, Sendable, CaseIterable {
    case zoom, meet, teams, webex, facetime

    public var name: String {
      switch self {
      case .zoom: "Zoom"
      case .meet: "Google Meet"
      case .teams: "Teams"
      case .webex: "Webex"
      case .facetime: "FaceTime"
      }
    }
  }

  private static let patterns: [(Service, String)] = [
    (.zoom, #"https://(?:[a-z0-9-]+\.)?zoom\.us/(?:j|my|w|s)/[A-Za-z0-9?=&._\-/]+"#),
    (.meet, #"https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}(?:\?[A-Za-z0-9=&._\-]*)?"#),
    (.teams, #"https://teams\.(?:microsoft|live)\.com/(?:l/meetup-join|meet)/[A-Za-z0-9%?=&._\-/:@]+"#),
    (.webex, #"https://[a-z0-9-]+\.webex\.com/[A-Za-z0-9?=&._\-/]+"#),
    (.facetime, #"https://facetime\.apple\.com/join[A-Za-z0-9#?=&._\-/]+"#),
  ]

  /// The first call link in any of `texts` (an event's URL, location, notes).
  public static func find(in texts: [String?]) -> (service: Service, url: URL)? {
    for text in texts.compactMap(\.self) where !text.isEmpty {
      for (service, pattern) in patterns {
        if let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
          let url = URL(string: String(text[range]))
        {
          return (service, url)
        }
      }
    }
    return nil
  }

  /// A Google Meet call itself (meet.google.com/abc-defg-hij), not its landing page.
  public static func isMeetCall(_ url: String) -> Bool {
    url.range(of: #"^https://meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}(?:[?#/].*)?$"#, options: .regularExpression) != nil
  }
}

/// How a call is recognised without reading anyone's windows: Zoom runs a
/// helper process only while you're in a meeting; Meet is a tab.
public enum MeetingSignals {
  public static let zoomBundle = "us.zoom.xos"
  /// Zoom's screen-share/meeting host, alive only during a call.
  public static let zoomMeetingProcesses: Set<String> = ["CptHost", "caphost", "aomhost"]

  public enum Source: Equatable, Sendable {
    case zoom
    case meet(browserBundle: String, url: String)

    public var name: String {
      switch self {
      case .zoom: "Zoom"
      case .meet: "Google Meet"
      }
    }
  }

  /// Zoom wins when both are seen: its own process is the stronger signal.
  public static func source(zoomRunning: Bool, processNames: Set<String>, meetTab: (bundle: String, url: String)?) -> Source? {
    if zoomRunning, !processNames.isDisjoint(with: zoomMeetingProcesses) { return .zoom }
    if let meetTab { return .meet(browserBundle: meetTab.bundle, url: meetTab.url) }
    return nil
  }
}

// MARK: - Browsers

/// A browser the island can read and steer, by bundle id.
public struct Browser: Equatable, Sendable {
  public enum Family: Sendable { case chromium, safari, firefox }

  public let bundleId: String
  public let name: String
  public let family: Family

  public static let all: [Browser] = [
    Browser(bundleId: "com.apple.Safari", name: "Safari", family: .safari),
    Browser(bundleId: "com.apple.SafariTechnologyPreview", name: "Safari Technology Preview", family: .safari),
    Browser(bundleId: "com.google.Chrome", name: "Chrome", family: .chromium),
    Browser(bundleId: "com.google.Chrome.canary", name: "Chrome Canary", family: .chromium),
    Browser(bundleId: "company.thebrowser.Browser", name: "Arc", family: .chromium),
    Browser(bundleId: "com.brave.Browser", name: "Brave", family: .chromium),
    Browser(bundleId: "com.microsoft.edgemac", name: "Edge", family: .chromium),
    Browser(bundleId: "com.vivaldi.Vivaldi", name: "Vivaldi", family: .chromium),
    Browser(bundleId: "org.chromium.Chromium", name: "Chromium", family: .chromium),
    Browser(bundleId: "com.operasoftware.Opera", name: "Opera", family: .chromium),
    Browser(bundleId: "org.mozilla.firefox", name: "Firefox", family: .firefox),
    Browser(bundleId: "app.zen-browser.zen", name: "Zen", family: .firefox),
  ]

  public static func named(bundleId: String?) -> Browser? {
    guard let bundleId else { return nil }
    return all.first { $0.bundleId == bundleId }
  }

  /// Firefox has no tab scripting: it's driven by keys alone.
  public var scriptable: Bool { family != .firefox }

  private var tell: String { "tell application id \"\(bundleId)\"" }

  /// Returns "title⏎url" for the front window's tab, or "" with no window.
  public var activeTabScript: String? {
    switch family {
    case .chromium:
      "\(tell)\nif (count of windows) is 0 then return \"\"\nreturn (title of active tab of front window) & linefeed & (URL of active tab of front window)\nend tell"
    case .safari:
      "\(tell)\nif (count of windows) is 0 then return \"\"\nreturn (name of current tab of front window) & linefeed & (URL of current tab of front window)\nend tell"
    case .firefox: nil
    }
  }

  /// Every tab's URL, one per line, for spotting a Meet call in the background.
  public var allTabsScript: String? {
    guard scriptable else { return nil }
    return """
      \(tell)
      set out to ""
      repeat with w in windows
      repeat with t in tabs of w
      set out to out & (URL of t) & linefeed
      end repeat
      end repeat
      return out
      end tell
      """
  }

  public enum Command: String, Sendable { case back, forward, reload }

  /// Chromium browsers take these as AppleScript; Safari and Firefox need keys.
  public func script(_ command: Command) -> String? {
    guard family == .chromium else {
      // Safari can reload by re-setting its URL; history needs keys.
      if family == .safari, command == .reload {
        return "\(tell)\nif (count of windows) > 0 then set URL of current tab of front window to (URL of current tab of front window)\nend tell"
      }
      return nil
    }
    let verb = switch command {
    case .back: "go back"
    case .forward: "go forward"
    case .reload: "reload"
    }
    return "\(tell)\nif (count of windows) > 0 then \(verb) active tab of front window\nend tell"
  }

  /// Brings the tab with `url` to the front (window raised, tab selected).
  public func focusTabScript(url: String) -> String? {
    let quoted = url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    switch family {
    case .chromium:
      return """
        \(tell)
        repeat with w in windows
        set i to 0
        repeat with t in tabs of w
        set i to i + 1
        if (URL of t) starts with "\(quoted)" then
        set active tab index of w to i
        set index of w to 1
        activate
        return "ok"
        end if
        end repeat
        end repeat
        end tell
        """
    case .safari:
      return """
        \(tell)
        repeat with w in windows
        repeat with t in tabs of w
        if (URL of t) starts with "\(quoted)" then
        set current tab of w to t
        set index of w to 1
        activate
        return "ok"
        end if
        end repeat
        end repeat
        end tell
        """
    case .firefox: return nil
    }
  }

  /// Closes the tab with `url` (leaving a Meet call).
  public func closeTabScript(url: String) -> String? {
    guard scriptable else { return nil }
    let quoted = url.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return """
      \(tell)
      repeat with w in windows
      repeat with t in tabs of w
      if (URL of t) starts with "\(quoted)" then
      close t
      return "ok"
      end if
      end repeat
      end repeat
      end tell
      """
  }

  /// Parses `activeTabScript`'s output.
  public static func parseActiveTab(_ output: String) -> (title: String, url: String)? {
    let lines = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard lines.count == 2, !(lines[0].isEmpty && lines[1].isEmpty) else { return nil }
    return (lines[0], lines[1])
  }
}

/// "github.com" from a URL, for a tab's subtitle.
public func displayHost(_ url: String) -> String {
  guard let host = URL(string: url)?.host() else { return url }
  return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
}

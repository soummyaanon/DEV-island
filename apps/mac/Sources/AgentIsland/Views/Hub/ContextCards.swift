import AppKit
import IslandCore
import SwiftUI

/// The main page's "right now": whatever is happening gets one small tile,
/// two to a row, and nothing at all when nothing is.
struct ContextCards: View {
  let model: IslandModel
  let now: Date

  enum Item: Identifiable {
    case call(MeetingService.Call)
    case event(AgendaService.Event)
    case timer(IslandTimer)
    case media(NowPlayingService.Track)
    case browser(Browser)
    case files

    var id: String {
      switch self {
      case .call: "call"
      case let .event(event): "event-\(event.id)"
      case let .timer(timer): "timer-\(timer.id)"
      case .media: "media"
      case .browser: "browser"
      case .files: "files"
      }
    }
  }

  private var items: [Item] {
    var items: [Item] = []
    if let call = model.liveCall {
      items.append(.call(call))
    } else if model.settings.agenda, let event = model.agenda.upcoming(at: now) {
      items.append(.event(event))
    }
    if model.settings.timers { items += model.timers.timers.map(Item.timer) }
    if let track = model.liveTrack { items.append(.media(track)) }
    if model.settings.browserControls, let browser = model.browser.front { items.append(.browser(browser)) }
    if model.settings.shelf, !model.shelf.items.isEmpty { items.append(.files) }
    return items
  }

  var body: some View {
    let items = items
    if !items.isEmpty {
      Grid(horizontalSpacing: 6, verticalSpacing: 6) {
        ForEach(Array(stride(from: 0, to: items.count, by: 2)), id: \.self) { start in
          GridRow {
            tile(items[start])
              .gridCellColumns(start + 1 == items.count ? 2 : 1)
            if start + 1 < items.count { tile(items[start + 1]) }
          }
        }
      }
      .frame(width: 412)
      .padding(.init(top: 4, leading: 8, bottom: 2, trailing: 8))
    }
  }

  @ViewBuilder private func tile(_ item: Item) -> some View {
    switch item {
    case let .call(call): CallTile(model: model, call: call, now: now)
    case let .event(event): EventTile(model: model, event: event, now: now)
    case let .timer(timer): TimerTile(model: model, timer: timer, now: now)
    case let .media(track): MediaTile(model: model, track: track)
    case .browser: BrowserTile(model: model)
    case .files: FilesTile(model: model)
    }
  }
}

/// A quiet tile for one card.
struct QuickCard<Content: View>: View {
  var tint: Color? = nil
  @ViewBuilder let content: Content

  var body: some View {
    content
      .padding(.init(top: 6, leading: 8, bottom: 6, trailing: 6))
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .fill(LinearGradient(colors: [(tint ?? .white).opacity(tint == nil ? 0.07 : 0.14), (tint ?? .white).opacity(tint == nil ? 0.035 : 0.05)], startPoint: .top, endPoint: .bottom))
      )
      .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.06)))
      .modifier(Entrance(kind: .rowIn, delay: 0.04))
  }
}

/// A round glyph button in a card: dim, lit under the pointer.
struct QuickButton: View {
  let symbol: String
  let label: String
  var size: CGFloat = 12
  var tint: Color? = nil
  var prominent = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Glyph(symbol, size: size)
        .frame(width: prominent ? 30 : 24, height: prominent ? 30 : 24)
    }
    .buttonStyle(QuickButtonStyle(tint: tint, prominent: prominent))
    .help(label)
    .accessibilityLabel(label)
  }
}

private struct QuickButtonStyle: ButtonStyle {
  let tint: Color?
  let prominent: Bool

  func makeBody(configuration: Configuration) -> some View {
    Hovering { hovered in
      configuration.label
        .foregroundStyle(tint ?? (hovered ? Palette.text : .white.opacity(0.72)))
        .background(Circle().fill(.white.opacity(configuration.isPressed ? 0.16 : hovered ? 0.1 : prominent ? 0.08 : 0)))
        .scaleEffect(configuration.isPressed ? 0.92 : 1)
        .animation(.easeOut(duration: 0.1), value: hovered)
        .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        .contentShape(Circle())
    }
  }
}

/// A small text button, for the less common actions.
struct TextKey: View {
  let title: String
  var tint: Color = Palette.accent
  let action: () -> Void

  var body: some View {
    Hovering { hovered in
      Button(action: action) {
        Text(title)
          .islandFont(10, weight: .semibold)
          .foregroundStyle(tint)
          .padding(.init(top: 3, leading: 8, bottom: 3, trailing: 8))
          .background(Capsule().fill(tint.opacity(hovered ? 0.2 : 0.11)))
      }
      .buttonStyle(.plain)
    }
  }
}

enum AgendaText {
  static func when(_ event: AgendaService.Event, now: Date) -> String {
    if event.allDay { return "All day" }
    if event.isOngoing(at: now) { return "Now · until \(event.end.formatted(date: .omitted, time: .shortened))" }
    let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded(.up))
    if minutes <= 60 { return "in \(minutes) min · \(event.start.formatted(date: .omitted, time: .shortened))" }
    let day = Calendar.current.isDateInToday(event.start) ? "" : "Tomorrow "
    return day + event.start.formatted(date: .omitted, time: .shortened) + "–" + event.end.formatted(date: .omitted, time: .shortened)
  }
}

// MARK: - Timer

struct TimerCard: View {
  let model: IslandModel
  let timer: IslandTimer
  let now: Date

  var body: some View {
    let timers = model.timers
    let tint = QuickPalette.timer(timer)
    QuickCard {
      HStack(spacing: 9) {
        TimerRing(timer: timer, now: now, size: 22, lineWidth: 2.5)
        VStack(alignment: .leading, spacing: 0) {
          Text(timer.title).islandFont(10, weight: .medium).foregroundStyle(Palette.textDim).lineLimit(1)
          Text(Clock.countdown(timer.remaining(at: now)))
            .islandFont(17, weight: .semibold)
            .monospacedDigit()
            .foregroundStyle(timer.isPaused ? Palette.textDim : tint)
            .contentTransition(.numericText(countsDown: true))
        }
        Spacer(minLength: 8)
        QuickButton(symbol: "plus", label: "Add a minute") { timers.extend(timer.id, minutes: 1) }
        QuickButton(symbol: timer.isPaused ? "play.fill" : "pause.fill", label: timer.isPaused ? "Resume" : "Pause", prominent: true) {
          timers.togglePause(timer.id)
        }
        if timer.kind == .pomodoro {
          QuickButton(symbol: "forward.end.fill", label: "Skip to the next phase") { timers.skip(timer.id) }
        }
        QuickButton(symbol: "xmark", label: "Stop the timer") { timers.cancel(timer.id) }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(timer.title), \(Clock.countdown(timer.remaining(at: now))) left")
  }
}

/// An installed app's icon by bundle id.
struct AppIcon: View {
  let bundleId: String
  var size: CGFloat = 16

  /// Looked up once per app: Launch Services and icon decoding aren't free.
  private static var cache: [String: NSImage] = [:]

  private var icon: NSImage? {
    if let cached = Self.cache[bundleId] { return cached }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
    let icon = NSWorkspace.shared.icon(forFile: url.path)
    Self.cache[bundleId] = icon
    return icon
  }

  var body: some View {
    if let icon {
      Image(nsImage: icon).resizable().frame(width: size, height: size)
    } else {
      Image(systemName: "globe").font(.system(size: size * 0.8)).foregroundStyle(Palette.textDim).frame(width: size, height: size)
    }
  }
}

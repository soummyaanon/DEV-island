import AppKit
import EventKit
import Foundation
import IslandCore
import Observation

/// Today: calendar events and reminders (EventKit, read on this Mac, asked
/// for only when you press Allow), and the island's own to-do list.
@Observable
final class AgendaService {
  enum Access: Equatable { case notAsked, granted, denied }

  struct Event: Identifiable, Equatable {
    let id: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var calendar: String
    var color: NSColor?
    var link: URL?
    var service: MeetingLink.Service?

    func isOngoing(at now: Date) -> Bool { start <= now && end > now }
  }

  struct Reminder: Identifiable, Equatable {
    let id: String
    var title: String
    var due: Date?
    var list: String
    var color: NSColor?
  }

  private(set) var eventAccess: Access = .notAsked
  private(set) var reminderAccess: Access = .notAsked
  private(set) var events: [Event] = []
  private(set) var reminders: [Reminder] = []
  private(set) var todos = TodoList.load()

  /// The month the calendar shows, and the day picked in it.
  private(set) var month = Date.now
  private(set) var selected = Calendar.current.startOfDay(for: .now)
  /// Days of the shown month with events, by `AgentStats.dayKey`, with their calendars' colours.
  private(set) var busyDays: [String: [NSColor]] = [:]
  /// The picked day's events.
  private(set) var dayEvents: [Event] = []

  @ObservationIgnored private let store = EKEventStore()
  @ObservationIgnored private var observer: NSObjectProtocol?
  @ObservationIgnored private var lastRefresh = Date.distantPast

  init() {
    eventAccess = Self.access(.event)
    reminderAccess = Self.access(.reminder)
  }

  private static func access(_ type: EKEntityType) -> Access {
    switch EKEventStore.authorizationStatus(for: type) {
    case .fullAccess: .granted
    case .notDetermined: .notAsked
    default: .denied
    }
  }

  func start() {
    guard observer == nil else { return }
    observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh(force: true) }
    }
    refresh(force: true)
  }

  func stop() {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    events = []
    reminders = []
  }

  /// Both prompts, one after the other; from the Allow button only.
  func requestAccess() {
    Task {
      NSApp.activate()
      let events = (try? await store.requestFullAccessToEvents()) ?? false
      let reminders = (try? await store.requestFullAccessToReminders()) ?? false
      eventAccess = events ? .granted : .denied
      reminderAccess = reminders ? .granted : .denied
      store.reset()
      refresh(force: true)
    }
  }

  func openPrivacySettings() {
    SettingsPane.open("com.apple.preference.security?Privacy_Calendars")
  }

  /// At most once a minute unless something changed.
  func refresh(force: Bool = false) {
    guard force || Date.now.timeIntervalSince(lastRefresh) > 60 else { return }
    lastRefresh = .now
    eventAccess = Self.access(.event)
    reminderAccess = Self.access(.reminder)
    if eventAccess == .granted {
      loadEvents()
      loadMonth()
    }
    if reminderAccess == .granted { loadReminders() }
  }

  private func loadEvents() {
    let now = Date.now
    let calendar = Calendar.current
    let end = calendar.date(byAdding: .hour, value: 36, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
    let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3 * 3600), end: end, calendars: nil)
    events = store.events(matching: predicate)
      .filter { $0.endDate > now && $0.status != .canceled }
      .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
      .prefix(8)
      .map { event in
        let link = MeetingLink.find(in: [event.url?.absoluteString, event.location, event.notes])
        return Event(
          id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "Untitled", start: event.startDate,
          end: event.endDate, allDay: event.isAllDay, calendar: event.calendar?.title ?? "",
          color: event.calendar?.color, link: link?.url, service: link?.service
        )
      }
  }

  func showMonth(_ delta: Int) {
    month = MonthGrid.shift(month, by: delta)
    loadMonth()
  }

  func select(_ day: Date) {
    selected = Calendar.current.startOfDay(for: day)
    if !Calendar.current.isDate(day, equalTo: month, toGranularity: .month) { month = day }
    loadMonth()
  }

  /// One fetch for the whole month: which days are busy, and the picked day's events.
  private func loadMonth() {
    guard eventAccess == .granted, let interval = Calendar.current.dateInterval(of: .month, for: month) else { return }
    let all = store.events(matching: store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil))
      .filter { $0.status != .canceled }
    var busy: [String: [NSColor]] = [:]
    for event in all {
      var day = Calendar.current.startOfDay(for: event.startDate)
      // A multi-day event marks every day it covers.
      while day < event.endDate, day < interval.end {
        let key = AgentStats.dayKey(day)
        if let color = event.calendar?.color, busy[key, default: []].count < 3, !busy[key, default: []].contains(color) {
          busy[key, default: []].append(color)
        } else if busy[key] == nil {
          busy[key] = []
        }
        guard let next = Calendar.current.date(byAdding: .day, value: 1, to: day) else { break }
        day = next
      }
    }
    busyDays = busy
    let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: selected) ?? selected
    dayEvents = store.events(matching: store.predicateForEvents(withStart: selected, end: dayEnd, calendars: nil))
      .filter { $0.status != .canceled }
      .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
      .map { event in
        let link = MeetingLink.find(in: [event.url?.absoluteString, event.location, event.notes])
        return Event(
          id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? "Untitled", start: event.startDate,
          end: event.endDate, allDay: event.isAllDay, calendar: event.calendar?.title ?? "",
          color: event.calendar?.color, link: link?.url, service: link?.service
        )
      }
  }

  private func loadReminders() {
    let endOfToday = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))
    let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: endOfToday, calendars: nil)
    store.fetchReminders(matching: predicate) { [weak self] found in
      let values = (found ?? []).prefix(12).map { reminder in
        Reminder(
          id: reminder.calendarItemIdentifier, title: reminder.title ?? "", due: reminder.dueDateComponents?.date,
          list: reminder.calendar?.title ?? "", color: reminder.calendar?.color
        )
      }
      let sorted = values.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
      Task { @MainActor in self?.reminders = sorted }
    }
  }

  /// Ticks a reminder off in Reminders itself.
  func complete(_ reminder: Reminder) {
    guard let item = store.calendarItem(withIdentifier: reminder.id) as? EKReminder else { return }
    item.isCompleted = true
    do {
      try store.save(item, commit: true)
      reminders.removeAll { $0.id == reminder.id }
    } catch {
      Log.app.error("reminder save failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// The event to surface on the main page: on now with a call link, or
  /// starting within ten minutes.
  func upcoming(at now: Date) -> Event? {
    events.first { event in
      guard !event.allDay else { return false }
      let startsSoon = event.start > now && event.start.timeIntervalSince(now) <= 10 * 60
      let justStarted = event.isOngoing(at: now) && now.timeIntervalSince(event.start) <= 10 * 60
      return startsSoon || (justStarted && event.link != nil)
    }
  }

  func join(_ event: Event) {
    if let link = event.link { NSWorkspace.shared.open(link) }
  }

  func openCalendar() {
    NSWorkspace.shared.open(URL(string: "ical://")!)
  }

  // MARK: To-dos

  func addTodo(_ text: String) {
    guard todos.add(text) != nil else { return }
    saveTodos()
  }

  func toggleTodo(_ id: UUID) {
    todos.toggle(id)
    saveTodos()
  }

  func removeTodo(_ id: UUID) {
    todos.remove(id)
    saveTodos()
  }

  func clearDoneTodos() {
    todos.clearDone()
    saveTodos()
  }

  private func saveTodos() {
    do { try todos.save() } catch { Log.app.error("todos save failed: \(error.localizedDescription, privacy: .public)") }
  }
}

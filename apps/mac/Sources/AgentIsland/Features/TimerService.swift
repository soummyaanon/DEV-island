import Foundation
import IslandCore
import Observation
import UserNotifications

/// Countdowns and Pomodoro. Nothing polls: one task sleeps until the next
/// timer rings. The wings and cards read `now` from their own timelines.
@Observable
final class TimerService {
  private(set) var timers: [IslandTimer] = []
  var plan = PomodoroPlan.classic

  /// A timer rang (a Pomodoro phase ended, or a countdown finished).
  @ObservationIgnored var onFinish: (IslandTimer) -> Void = { _ in }
  @ObservationIgnored private var wake: Task<Void, Never>?

  /// The one the wings show: the next to ring, a paused one only when nothing runs.
  var featured: IslandTimer? {
    let now = Date.now
    return timers.filter(\.isRunning).min { $0.remaining(at: now) < $1.remaining(at: now) } ?? timers.first
  }

  var pomodoro: IslandTimer? { timers.first { $0.kind == .pomodoro } }

  func startCountdown(minutes: Double, label: String = "") {
    guard minutes > 0 else { return }
    timers.append(.countdown(minutes: min(minutes, 24 * 60), label: label, at: .now))
    reschedule()
  }

  /// One Pomodoro at a time: starting another restarts it.
  func startPomodoro() {
    timers.removeAll { $0.kind == .pomodoro }
    timers.insert(.pomodoro(plan, at: .now), at: 0)
    reschedule()
  }

  func togglePause(_ id: UUID) {
    change(id) { timer in
      if timer.isPaused { timer.resume(at: .now) } else { timer.pause(at: .now) }
    }
  }

  func extend(_ id: UUID, minutes: Double) {
    change(id) { $0.extend(by: minutes * 60, at: .now) }
  }

  /// Jumps a Pomodoro to its next phase; ends a countdown.
  func skip(_ id: UUID) {
    guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
    if let next = timers[index].next(plan, at: .now) { timers[index] = next } else { timers.remove(at: index) }
    reschedule()
  }

  func cancel(_ id: UUID) {
    timers.removeAll { $0.id == id }
    reschedule()
  }

  private func change(_ id: UUID, _ body: (inout IslandTimer) -> Void) {
    guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
    body(&timers[index])
    reschedule()
  }

  private func reschedule() {
    wake?.cancel()
    let now = Date.now
    guard let soonest = timers.filter(\.isRunning).map({ $0.remaining(at: now) }).min() else { return }
    wake = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(max(0.05, soonest))) } catch { return }
      self?.ring()
    }
  }

  private func ring() {
    let now = Date.now
    var rang: [IslandTimer] = []
    timers = timers.compactMap { timer in
      guard timer.isFinished(at: now) else { return timer }
      rang.append(timer)
      return timer.next(plan, at: now)
    }
    for timer in rang {
      notify(timer)
      onFinish(timer)
    }
    reschedule()
  }

  private func notify(_ timer: IslandTimer) {
    guard Bundle.main.bundleIdentifier != nil else { return }
    let content = UNMutableNotificationContent()
    switch (timer.kind, timer.phase) {
    case (.countdown, _):
      content.title = timer.label.isEmpty ? "Timer done" : "Timer: \(timer.label)"
      content.body = "\(Clock.countdown(timer.duration)) is up."
    case (.pomodoro, .focus):
      content.title = "Focus \(timer.round) done"
      content.body = "Time for a break."
    case (.pomodoro, _):
      content.title = "Break's over"
      content.body = "Back to focus."
    }
    Task {
      _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
      try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
  }
}

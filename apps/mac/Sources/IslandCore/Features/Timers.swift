import Foundation

/// A countdown or one Pomodoro phase. Time is passed in, never read, so every
/// rule here is testable; the app owns the clock.
public struct IslandTimer: Equatable, Sendable, Identifiable {
  public enum Kind: Equatable, Sendable { case countdown, pomodoro }

  public enum Phase: String, Equatable, Sendable {
    case focus, shortBreak, longBreak

    public var label: String {
      switch self {
      case .focus: "Focus"
      case .shortBreak: "Break"
      case .longBreak: "Long break"
      }
    }
  }

  public let id: UUID
  public var kind: Kind
  public var label: String
  public var phase: Phase
  /// Which focus round this is (Pomodoro), from 1.
  public var round: Int
  public var duration: TimeInterval
  /// Set while running.
  public var endsAt: Date?
  /// Set while paused.
  public var pausedRemaining: TimeInterval?

  public init(
    id: UUID = UUID(), kind: Kind = .countdown, label: String = "", phase: Phase = .focus, round: Int = 1,
    duration: TimeInterval, startedAt: Date
  ) {
    self.id = id
    self.kind = kind
    self.label = label
    self.phase = phase
    self.round = round
    self.duration = max(1, duration)
    endsAt = startedAt.addingTimeInterval(self.duration)
  }

  public static func countdown(minutes: Double, label: String = "", at now: Date) -> IslandTimer {
    IslandTimer(label: label, duration: minutes * 60, startedAt: now)
  }

  public static func pomodoro(_ plan: PomodoroPlan = .classic, at now: Date) -> IslandTimer {
    IslandTimer(kind: .pomodoro, phase: .focus, round: 1, duration: plan.focus, startedAt: now)
  }

  public var isRunning: Bool { endsAt != nil }
  public var isPaused: Bool { pausedRemaining != nil }

  public func remaining(at now: Date) -> TimeInterval {
    if let pausedRemaining { return pausedRemaining }
    guard let endsAt else { return 0 }
    return max(0, endsAt.timeIntervalSince(now))
  }

  /// 0 at the start, 1 when it rings.
  public func progress(at now: Date) -> Double {
    min(1, max(0, 1 - remaining(at: now) / duration))
  }

  public func isFinished(at now: Date) -> Bool {
    isRunning && remaining(at: now) <= 0
  }

  public mutating func pause(at now: Date) {
    guard isRunning else { return }
    pausedRemaining = remaining(at: now)
    endsAt = nil
  }

  public mutating func resume(at now: Date) {
    guard let left = pausedRemaining else { return }
    endsAt = now.addingTimeInterval(left)
    pausedRemaining = nil
  }

  /// Adds (or with a negative, takes) time; never below a second.
  public mutating func extend(by seconds: TimeInterval, at now: Date) {
    let left = max(1, remaining(at: now) + seconds)
    duration = max(duration, left)
    if isPaused { pausedRemaining = left } else { endsAt = now.addingTimeInterval(left) }
  }

  /// The Pomodoro phase after this one, already running; nil for a countdown.
  public func next(_ plan: PomodoroPlan = .classic, at now: Date) -> IslandTimer? {
    guard kind == .pomodoro else { return nil }
    switch phase {
    case .focus:
      let long = round % plan.roundsBeforeLongBreak == 0
      return IslandTimer(
        id: id, kind: .pomodoro, label: label, phase: long ? .longBreak : .shortBreak, round: round,
        duration: long ? plan.longBreak : plan.shortBreak, startedAt: now
      )
    case .shortBreak, .longBreak:
      return IslandTimer(id: id, kind: .pomodoro, label: label, phase: .focus, round: round + 1, duration: plan.focus, startedAt: now)
    }
  }

  /// "Focus 2", "Break", or the countdown's label.
  public var title: String {
    switch kind {
    case .countdown: label.isEmpty ? "Timer" : label
    case .pomodoro: phase == .focus ? "Focus \(round)" : phase.label
    }
  }
}

/// The classic 25 / 5, with 15 after every fourth round.
public struct PomodoroPlan: Equatable, Sendable {
  public var focus: TimeInterval
  public var shortBreak: TimeInterval
  public var longBreak: TimeInterval
  public var roundsBeforeLongBreak: Int

  public init(focus: TimeInterval, shortBreak: TimeInterval, longBreak: TimeInterval, roundsBeforeLongBreak: Int) {
    self.focus = focus
    self.shortBreak = shortBreak
    self.longBreak = longBreak
    self.roundsBeforeLongBreak = max(1, roundsBeforeLongBreak)
  }

  public static let classic = PomodoroPlan(focus: 25 * 60, shortBreak: 5 * 60, longBreak: 15 * 60, roundsBeforeLongBreak: 4)
}

public enum Clock {
  /// "4:59", "12:00", "1:04:59". Rounds up, so a timer never reads 0:00 while running.
  public static func countdown(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds).rounded(.up))
    let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
  }

  /// Elapsed time, rounded down: "0:42", "12:05", "1:02:00".
  public static func elapsed(_ seconds: TimeInterval) -> String {
    let total = Int(max(0, seconds))
    let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
  }
}

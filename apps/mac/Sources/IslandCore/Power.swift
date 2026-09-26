import Foundation

// Battery as a live activity — the pure half of 1.x's `main/power.ts`.
//
// IOKit says the instant the charger comes or goes; `pmset` says how full the
// battery is and which Energy Mode is set. These functions reconcile the two,
// and keep the same behaviour (and tests) as 1.x.

/// Below this, on battery, the island keeps a small red battery in its wing.
public let lowBatteryPercent = 20

public enum PowerState: String, Sendable {
  case charging, discharging, charged
  /// On the charger but not charging (optimised charging, or a full hold).
  case ac
}

/// System Settings → Battery → Energy Mode. The charge animation follows it.
public enum EnergyMode: String, Sendable, CaseIterable {
  case automatic, low, high
}

public enum PowerSource: Sendable {
  case ac, battery
}

/// The moment between two readings: the charger going in or coming out.
public enum PowerEvent: Sendable {
  case plugged, unplugged
}

public struct PowerReading: Equatable, Sendable {
  public var percent: Int
  public var state: PowerState
  /// Minutes to empty (discharging) or to full (charging); nil when unknown.
  public var minutesRemaining: Int?

  public init(percent: Int, state: PowerState, minutesRemaining: Int? = nil) {
    self.percent = percent
    self.state = state
    self.minutesRemaining = minutesRemaining
  }

  public var isOnBattery: Bool { state == .discharging }

  /// On battery and at or under `lowBatteryPercent`.
  public var isLow: Bool { isOnBattery && percent <= lowBatteryPercent }
}

extension PowerReading {
  /// Parses `pmset -g batt`. Nil when there is no internal battery (a desktop Mac).
  public init?(pmsetBatt output: String) {
    guard let line = output.firstMatch(of: /InternalBattery[^\n]*?\t(\d{1,3})%;\s*([^\n]*)/),
      let raw = Int(line.1)
    else { return nil }

    let rest = line.2.lowercased()
    // Order matters: "not charging" and "discharging" both contain "charging".
    let state: PowerState =
      if rest.contains("not charging") { .ac }
      else if rest.contains("discharging") { .discharging }
      else if rest.contains("charged") { .charged }
      else if rest.contains("charging") || rest.contains("finishing charge") { .charging }
      else { .ac }

    var minutes: Int?
    if let remaining = rest.firstMatch(of: /(\d+):(\d{2}) remaining/),
      let hours = Int(remaining.1), let mins = Int(remaining.2)
    {
      minutes = hours * 60 + mins
    }
    self.init(percent: min(100, max(0, raw)), state: state, minutesRemaining: minutes)
  }

  /// IOKit knows about the charger before pmset does: read right after the
  /// charger goes in, pmset can still say "discharging". Trust the event for
  /// the power source, so the next reading doesn't see the same transition and
  /// fire it again.
  public func reconciled(with event: PowerEvent?) -> PowerReading {
    switch event {
    case .plugged where state == .discharging:
      PowerReading(percent: percent, state: .charging)
    case .unplugged where state != .discharging:
      PowerReading(percent: percent, state: .discharging)
    default:
      self
    }
  }
}

extension PowerEvent {
  /// The moment between two readings, if any. The first reading is only a baseline.
  public init?(from previous: PowerReading?, to next: PowerReading) {
    guard let previous, previous.isOnBattery != next.isOnBattery else { return nil }
    self = next.isOnBattery ? .unplugged : .plugged
  }

  /// The charger moment, if the power source really changed. The first report
  /// only sets the baseline; a second watcher repeating the same source is nothing.
  public init?(from previous: PowerSource?, to next: PowerSource) {
    guard let previous, previous != next else { return nil }
    self = next == .ac ? .plugged : .unplugged
  }
}

extension EnergyMode {
  /// Parses `pmset -g`: `powermode` 0/1/2 on current macOS, `lowpowermode` 0/1
  /// on older releases. Automatic when neither says.
  public init(pmset output: String) {
    if let mode = output.firstMatch(of: /^\s*powermode\s+(\d)/.anchorsMatchLineEndings()) {
      self = switch mode.1 {
      case "1": .low
      case "2": .high
      default: .automatic
      }
    } else if let legacy = output.firstMatch(of: /^\s*lowpowermode\s+(\d)/.anchorsMatchLineEndings()) {
      self = legacy.1 == "1" ? .low : .automatic
    } else {
      self = .automatic
    }
  }

  /// `ProcessInfo` hears Low Power Mode flip before pmset settles; trust it for
  /// that one bit, and keep pmset's High Power (which it can't see).
  public static func resolve(pmset: EnergyMode, lowPowerMode: Bool?) -> EnergyMode {
    switch (pmset, lowPowerMode) {
    case (_, true?): .low
    case (.low, false?): .automatic
    default: pmset
    }
  }
}

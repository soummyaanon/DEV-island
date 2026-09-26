import AppKit
import Foundation
import IOKit.ps
import IslandCore
import Observation

/// A few seconds of battery news in the wings: the charger going in or out
/// (played along the edge too), or the battery crossing into low.
struct PowerActivity: Equatable, Identifiable {
  enum Kind: Equatable { case plugged, unplugged, low }

  let id = UUID()
  let kind: Kind
  let energyMode: EnergyMode

  var isCharger: Bool { kind != .low }

  /// How long it holds the wings before they return to what they were.
  var duration: Duration { kind == .low ? .milliseconds(4000) : .milliseconds(3500) }
}

/// Battery as a live activity, moved in from the sidecar and 1.x's `power.ts`.
///
/// IOKit's power-source notification says the instant the charger comes or
/// goes, and `ProcessInfo` when Low Power Mode flips; `pmset` says how full the
/// battery is and which Energy Mode is set. One small read a minute on a
/// laptop, nothing at all on a desktop (no battery → nil once, then stop).
@Observable
final class PowerMonitor {
  private(set) var reading: PowerReading?
  private(set) var energyMode: EnergyMode = .automatic
  private(set) var activity: PowerActivity?

  @ObservationIgnored private var running = false
  @ObservationIgnored private var hasBattery = true
  @ObservationIgnored private var source: PowerSource?
  @ObservationIgnored private var lowPowerMode: Bool?
  /// The last refresh; each new one waits for it, so readings land in order.
  @ObservationIgnored private var refreshing: Task<Void, Never>?
  @ObservationIgnored private var poll: Task<Void, Never>?
  @ObservationIgnored private var activityEnd: Task<Void, Never>?
  @ObservationIgnored private var runLoopSource: CFRunLoopSource?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []

  func start() {
    guard !running else { return }
    running = true
    watchSource()
    watchLowPowerMode()
    let wake = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.refresh() }
    }
    observers.append(wake)
    #if DEBUG
    // From a terminal: see apps/mac/README.md.
    let simulate = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name(Log.subsystem + ".simulateCharge"), object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.simulateMoment() }
    }
    observers.append(simulate)
    #endif
    refresh()
  }

  /// Battery off in Settings: nothing to show, nothing polled.
  func stop() {
    guard running else { return }
    running = false
    poll?.cancel()
    if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
    runLoopSource = nil
    for token in observers {
      NotificationCenter.default.removeObserver(token)
      NSWorkspace.shared.notificationCenter.removeObserver(token)
    }
    observers.removeAll()
    source = nil
    reading = nil
    activity = nil
  }

  // MARK: Watchers

  private func watchSource() {
    let context = Unmanaged.passUnretained(self).toOpaque()
    let created = IOPSNotificationCreateRunLoopSource({ context in
      guard let context else { return }
      // Added to the main run loop below, so this is the main thread.
      MainActor.assumeIsolated {
        Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue().readSource()
      }
    }, context)
    guard let source = created?.takeRetainedValue() else {
      Log.power.error("IOKit power-source notification unavailable; polling only")
      return
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    runLoopSource = source
    readSource()
  }

  private func readSource() {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
    else { return }
    sourceChanged((type as String) == kIOPMBatteryPowerKey ? .battery : .ac)
  }

  private func watchLowPowerMode() {
    lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    let token = NotificationCenter.default.addObserver(
      forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        let low = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard low != self.lowPowerMode else { return }
        self.lowPowerMode = low
        self.refresh()
      }
    }
    observers.append(token)
  }

  /// The charger went in or out, from whichever watcher noticed first.
  private func sourceChanged(_ next: PowerSource) {
    let event = PowerEvent(from: source, to: next)
    source = next
    if let event { refresh(forcing: event) }
  }

  // MARK: Reading

  /// Queues a read behind any in flight, so a slow minute poll can never land
  /// after — and undo — the reading for a charger moment.
  func refresh(forcing event: PowerEvent? = nil) {
    let previous = refreshing
    refreshing = Task {
      await previous?.value
      await read(forcing: event)
    }
  }

  private func read(forcing forced: PowerEvent?) async {
    guard running, hasBattery else { return }
    async let batt = Pmset.read("batt")
    async let settings = Pmset.read()
    let (battOutput, settingsOutput) = await (batt, settings)

    guard let raw = PowerReading(pmsetBatt: battOutput) else {
      // A desktop Mac: nothing to show, ever.
      hasBattery = false
      reading = nil
      Log.power.notice("no internal battery; power off")
      return
    }
    let next = raw.reconciled(with: forced)
    let event = forced ?? PowerEvent(from: reading, to: next)
    let wasLow = reading?.isLow ?? false
    reading = next
    // Only a moment moves the baseline: a plain poll must not overwrite what
    // IOKit just said with a pmset reading that hasn't caught up yet.
    if let event {
      source = event == .plugged ? .ac : .battery
    } else if source == nil {
      source = next.isOnBattery ? .battery : .ac
    }
    energyMode = .resolve(pmset: EnergyMode(pmset: settingsOutput), lowPowerMode: lowPowerMode)
    if let event {
      play(event == .plugged ? .plugged : .unplugged)
    } else if next.isLow && !wasLow {
      play(.low)
    }
    // pmset was behind: look again shortly for the real state and estimate.
    schedulePoll(after: next == raw ? .seconds(60) : .seconds(5))
  }

  private func schedulePoll(after delay: Duration) {
    poll?.cancel()
    poll = Task { [weak self] in
      do { try await Task.sleep(for: delay) } catch { return }
      self?.refresh()
    }
  }

  // MARK: Moments

  private func play(_ kind: PowerActivity.Kind) {
    Log.power.notice("battery \(String(describing: kind), privacy: .public), mode \(self.energyMode.rawValue, privacy: .public)")
    let next = PowerActivity(kind: kind, energyMode: energyMode)
    activity = next
    activityEnd?.cancel()
    activityEnd = Task { [weak self] in
      do { try await Task.sleep(for: next.duration) } catch { return }
      if self?.activity?.id == next.id { self?.activity = nil }
    }
  }

  #if DEBUG
  /// Replays the charger going in, then out, alternately — for side-by-side checks against 1.x.
  func simulateMoment() {
    guard reading != nil else { return }
    simulated = simulated == .plugged ? .unplugged : .plugged
    play(simulated)
  }

  @ObservationIgnored private var simulated = PowerActivity.Kind.unplugged
  #endif
}

/// `pmset -g …`, off the main actor: it's a process launch and a blocking read.
nonisolated enum Pmset {
  @concurrent
  static func read(_ arguments: String...) async -> String {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/pmset")
    process.arguments = ["-g"] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      Log.power.error("pmset failed to launch: \(error.localizedDescription, privacy: .public)")
      return ""
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
  }
}

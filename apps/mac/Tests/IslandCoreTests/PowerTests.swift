import IslandCore
import Testing

// Ported from 1.x's `main/power.test.ts`: same inputs, same answers.

private func batt(_ tail: String) -> String {
  "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=34668643)\t\(tail) present: true\n"
}

private func settings(_ line: String) -> String {
  "System-wide power settings:\nCurrently in use:\n standby              1\n\(line)\n sleep                1\n"
}

@Suite struct ParsePmset {
  @Test func `reads a discharging battery with an estimate`() {
    #expect(PowerReading(pmsetBatt: batt("80%; discharging; 11:02 remaining"))
      == PowerReading(percent: 80, state: .discharging, minutesRemaining: 662))
  }

  @Test func `reads charging with time to full`() {
    #expect(PowerReading(pmsetBatt: batt("43%; charging; 1:20 remaining"))
      == PowerReading(percent: 43, state: .charging, minutesRemaining: 80))
  }

  @Test(arguments: [
    ("100%; charged; 0:00 remaining", PowerState.charged),
    ("85%; AC attached; not charging", .ac),
    ("97%; finishing charge; 0:12 remaining", .charging),
  ])
  func `reads the state`(tail: String, state: PowerState) {
    #expect(PowerReading(pmsetBatt: batt(tail))?.state == state)
  }

  @Test func `copes with no estimate`() {
    #expect(PowerReading(pmsetBatt: batt("80%; discharging; (no estimate)"))
      == PowerReading(percent: 80, state: .discharging, minutesRemaining: nil))
  }

  @Test(arguments: ["Now drawing from 'AC Power'\n", ""])
  func `is nil on a desktop Mac`(output: String) {
    #expect(PowerReading(pmsetBatt: output) == nil)
  }
}

@Suite struct DetectPowerEvent {
  let bat = PowerReading(percent: 50, state: .discharging)
  let ac = PowerReading(percent: 50, state: .charging)

  @Test func `battery to charger is plugged`() {
    #expect(PowerEvent(from: bat, to: ac) == .plugged)
  }

  @Test func `charger to battery is unplugged`() {
    #expect(PowerEvent(from: ac, to: bat) == .unplugged)
  }

  @Test func `no change, or the first reading, is nothing`() {
    #expect(PowerEvent(from: bat, to: bat) == nil)
    #expect(PowerEvent(from: nil as PowerReading?, to: bat) == nil)
  }
}

@Suite struct ParseEnergyMode {
  @Test(arguments: [
    (" powermode            0", EnergyMode.automatic),
    (" powermode            1", .low),
    (" powermode            2", .high),
    (" lowpowermode         1", .low),
    (" lowpowermode         0", .automatic),
  ])
  func `reads powermode and the older lowpowermode flag`(line: String, mode: EnergyMode) {
    #expect(EnergyMode(pmset: settings(line)) == mode)
  }

  @Test func `is automatic when pmset says nothing`() {
    #expect(EnergyMode(pmset: "") == .automatic)
  }
}

@Suite struct Reconcile {
  let bat = PowerReading(percent: 50, state: .discharging, minutesRemaining: 300)
  let ac = PowerReading(percent: 50, state: .charging, minutesRemaining: 90)

  @Test func `trusts plugged over a stale discharging reading`() {
    #expect(bat.reconciled(with: .plugged) == PowerReading(percent: 50, state: .charging))
  }

  @Test func `trusts unplugged over a stale charging reading`() {
    #expect(ac.reconciled(with: .unplugged) == PowerReading(percent: 50, state: .discharging))
  }

  @Test func `leaves readings that already agree, or no event, alone`() {
    #expect(ac.reconciled(with: .plugged) == ac)
    #expect(bat.reconciled(with: nil) == bat)
  }

  @Test func `so the next real reading is not a second plugged`() {
    #expect(PowerEvent(from: bat.reconciled(with: .plugged), to: ac) == nil)
  }
}

@Suite struct SourceEvent {
  @Test func `the first report is only a baseline`() {
    #expect(PowerEvent(from: nil as PowerSource?, to: .ac) == nil)
    #expect(PowerEvent(from: nil as PowerSource?, to: .battery) == nil)
  }

  @Test func `battery to ac is plugged, ac to battery is unplugged`() {
    #expect(PowerEvent(from: PowerSource.battery, to: .ac) == .plugged)
    #expect(PowerEvent(from: PowerSource.ac, to: .battery) == .unplugged)
  }

  @Test func `a second watcher repeating the same source is nothing`() {
    #expect(PowerEvent(from: PowerSource.ac, to: .ac) == nil)
  }
}

@Suite struct ResolveEnergyMode {
  @Test func `trusts the native Low Power flag over pmset`() {
    #expect(EnergyMode.resolve(pmset: .automatic, lowPowerMode: true) == .low)
    #expect(EnergyMode.resolve(pmset: .low, lowPowerMode: false) == .automatic)
  }

  @Test func `keeps pmset's High Power, and falls back to pmset without the flag`() {
    #expect(EnergyMode.resolve(pmset: .high, lowPowerMode: false) == .high)
    #expect(EnergyMode.resolve(pmset: .low, lowPowerMode: nil) == .low)
  }
}

@Suite struct IsLow {
  @Test func `is low only on battery at or under 20 percent`() {
    #expect(PowerReading(percent: 20, state: .discharging).isLow)
    #expect(!PowerReading(percent: 21, state: .discharging).isLow)
    #expect(!PowerReading(percent: 5, state: .charging).isLow)
  }
}

import AppKit
import CoreLocation
import Foundation
import IslandCore
import Observation

/// Local weather for the idle island (1.x's weather.ts). The only ongoing
/// network request besides the update check, and only while weather is on
/// (it ships off). Open-Meteo needs no key or account; all that leaves the Mac
/// is a latitude and longitude rounded to two decimals.
@Observable
final class WeatherService {
  private(set) var reading: WeatherReading?

  /// A new, fresh reading arrived (for the haptic).
  @ObservationIgnored var onChange: ((WeatherReading) -> Void)?

  @ObservationIgnored private var enabled = false
  @ObservationIgnored private var units: IslandSettings.TemperatureUnit = .auto
  @ObservationIgnored private var manual = ""
  @ObservationIgnored private var device: Coordinates?
  @ObservationIgnored private var askedDevice = false
  @ObservationIgnored private var poll: Task<Void, Never>?
  @ObservationIgnored private var retry: Duration = .seconds(60)
  @ObservationIgnored private var wake: NSObjectProtocol?
  @ObservationIgnored private var locator: DeviceLocator?

  private static let every: Duration = .seconds(15 * 60)
  private static let retryCeiling: Duration = .seconds(30 * 60)

  private static var cacheURL: URL {
    IslandSettings.userData.appending(path: "weather-cache.json")
  }

  /// Applies the weather settings without a restart.
  func update(enabled: Bool, units: IslandSettings.TemperatureUnit, location: String) {
    let locationChanged = location.trimmingCharacters(in: .whitespaces) != manual.trimmingCharacters(in: .whitespaces)
    let unitsChanged = units != self.units
    let wasEnabled = self.enabled
    self.enabled = enabled
    self.units = units
    manual = location
    guard enabled else {
      stop()
      return
    }
    if let forced = Self.forced {
      publish(WeatherReading(
        condition: forced, temperature: Temperature.format(celsius: 21, units: units, region: Self.region),
        summary: "\(forced.words), forced", locationLabel: "AGENT_ISLAND_WEATHER", locationSource: .manual, stale: false
      ))
      return
    }
    if !wasEnabled {
      if reading == nil { publish(Self.readCache()) }
      upgradeLocation()
      wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
        // Asleep for hours: the cached reading is worthless.
        MainActor.assumeIsolated { self?.refreshNow() }
      }
    }
    if !wasEnabled || locationChanged || unitsChanged {
      if locationChanged { retry = .seconds(60) }
      refreshNow()
    }
  }

  private func stop() {
    poll?.cancel()
    poll = nil
    if let wake { NSWorkspace.shared.notificationCenter.removeObserver(wake) }
    wake = nil
    publish(nil)
  }

  private func refreshNow() {
    schedule(after: .zero)
  }

  private func schedule(after delay: Duration) {
    poll?.cancel()
    guard enabled else { return }
    poll = Task { [weak self] in
      if delay > .zero {
        do { try await Task.sleep(for: delay) } catch { return }
      }
      await self?.refresh()
    }
  }

  /// Typed, else a device fix, else the timezone's city.
  private var location: Coordinates? {
    if let typed = Coordinates.parseManual(manual) {
      return Coordinates(lat: typed.lat, lon: typed.lon, source: .manual, label: manual.trimmingCharacters(in: .whitespaces))
    }
    return device ?? Self.timezoneLocation()
  }

  private func refresh() async {
    guard enabled else { return }
    guard let location else {
      Log.app.notice("weather: no location; set one in Settings")
      publish(nil)
      return
    }
    do {
      let (data, response) = try await URLSession.shared.data(from: OpenMeteo.url(for: location))
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        throw URLError(.badServerResponse)
      }
      let reply = try JSONDecoder().decode(OpenMeteo.self, from: data)
      guard let (condition, celsius) = reply.reading(now: .now) else { throw URLError(.cannotParseResponse) }
      let temperature = Temperature.format(celsius: celsius, units: units, region: Self.region)
      let next = WeatherReading(
        condition: condition, temperature: temperature, summary: "\(condition.words), \(temperature)",
        locationLabel: location.label, locationSource: location.source, stale: false
      )
      publish(next)
      Self.writeCache(next)
      retry = .seconds(60)
      schedule(after: Self.every)
    } catch is CancellationError {
      return
    } catch {
      Log.app.notice("weather refresh failed: \(error.localizedDescription, privacy: .public)")
      // Keep the last good reading, flagged stale.
      if var last = reading, !last.stale {
        last.stale = true
        publish(last)
      }
      schedule(after: retry)
      retry = min(retry * 2, Self.retryCeiling)
    }
  }

  private func publish(_ next: WeatherReading?) {
    let changed = next?.condition != reading?.condition || next?.temperature != reading?.temperature
    reading = next
    if changed, let next, !next.stale { onChange?(next) }
  }

  // MARK: Location

  /// A precise fix once per run, in the background; it replaces the guess if it ever comes.
  private func upgradeLocation() {
    guard !askedDevice else { return }
    askedDevice = true
    let locator = DeviceLocator { [weak self] fix in
      guard let self, let fix else { return }
      device = fix
      Log.app.notice("weather: upgraded to a device location fix")
      refreshNow()
    }
    self.locator = locator
    locator.start()
  }

  static var region: String? { Locale.current.region?.identifier }

  /// The timezone's city from the tz database: no permission, no network.
  static func timezoneLocation() -> Coordinates? {
    var candidates: [String] = []
    if let tz = ProcessInfo.processInfo.environment["TZ"], !tz.isEmpty { candidates.append(tz) }
    candidates.append(TimeZone.current.identifier)
    if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: "/etc/localtime"),
      let zone = Coordinates.zone(fromLocaltimeLink: link), !candidates.contains(zone)
    {
      candidates.append(zone)
    }
    for path in ["/var/db/timezone/zoneinfo/zone.tab", "/usr/share/zoneinfo/zone.tab"] {
      guard let table = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
      if let found = Coordinates.fromZoneTable(table, candidates: candidates) { return found }
    }
    return nil
  }

  // MARK: Cache

  /// A launch with no network still shows something (flagged stale).
  private static func readCache() -> WeatherReading? {
    guard let data = try? Data(contentsOf: cacheURL), var cached = try? JSONDecoder().decode(WeatherReading.self, from: data) else { return nil }
    cached.stale = true
    return cached
  }

  private static func writeCache(_ reading: WeatherReading) {
    guard let data = try? JSONEncoder().encode(reading) else { return }
    try? data.write(to: cacheURL, options: .atomic)
  }

  /// A forced scene for development: AGENT_ISLAND_WEATHER=thunder.
  private static var forced: WeatherCondition? {
    ProcessInfo.processInfo.environment["AGENT_ISLAND_WEATHER"].flatMap(WeatherCondition.init(rawValue:))
  }
}

/// One CoreLocation fix, rounded to ~1 km before it goes anywhere. Any refusal,
/// delay or failure is simply no fix: the timezone guess stands.
final class DeviceLocator: NSObject, CLLocationManagerDelegate {
  private let manager = CLLocationManager()
  private let done: (Coordinates?) -> Void
  private var answered = false
  private var timeout: Task<Void, Never>?

  init(done: @escaping (Coordinates?) -> Void) {
    self.done = done
    super.init()
  }

  func start() {
    guard CLLocationManager.locationServicesEnabled() else { return finish(nil) }
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyKilometer
    // Long enough for a cold fix, short enough not to look hung.
    timeout = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(8)) } catch { return }
      self?.finish(nil)
    }
    switch manager.authorizationStatus {
    case .notDetermined: manager.requestWhenInUseAuthorization()
    case .denied, .restricted: finish(nil)
    default: manager.requestLocation()
    }
  }

  private func finish(_ fix: Coordinates?) {
    guard !answered else { return }
    answered = true
    timeout?.cancel()
    manager.delegate = nil
    done(fix)
  }

  nonisolated func locationManagerDidChangeAuthorization(_ changed: CLLocationManager) {
    let status = changed.authorizationStatus
    MainActor.assumeIsolated {
      switch status {
      case .notDetermined: break
      case .denied, .restricted: finish(nil)
      default: manager.requestLocation()
      }
    }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    let fix = locations.last.map {
      Coordinates(lat: Coordinates.coarsen($0.coordinate.latitude), lon: Coordinates.coarsen($0.coordinate.longitude), source: .device, label: "Current location")
    }
    MainActor.assumeIsolated { finish(fix) }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    MainActor.assumeIsolated { finish(nil) }
  }
}

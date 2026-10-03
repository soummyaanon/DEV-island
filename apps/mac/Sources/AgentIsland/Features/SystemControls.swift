import AppKit
import CoreWLAN
import Foundation
import IOBluetooth
import IOKit.ps
import IslandCore
import Observation

/// The quick controls: volume, brightness, Wi-Fi, Bluetooth, AirDrop,
/// displays. Read when the Controls tab shows, written as you drag.
@Observable
final class SystemControls {
  struct Display: Identifiable, Equatable {
    let id: CGDirectDisplayID
    var name: String
    var size: CGSize
    var builtIn: Bool
    var main: Bool
    var brightness: Float?
    /// Where it sits in the arrangement (global display coordinates).
    var frame: CGRect
  }

  /// The artwork macOS itself uses for a display: this Mac's own model for
  /// the built-in panel, Apple's displays by name, a generic monitor otherwise.
  static func artwork(for display: Display) -> NSImage? {
    if display.builtIn { return NSImage(named: NSImage.computerName) }
    let name = display.name.lowercased()
    let file = name.contains("studio display") ? "com.apple.studio-display"
      : name.contains("pro display") ? "com.apple.pro-display-xdr"
      : name.contains("cinema") ? "com.apple.led-cinema-display-27"
      : "public.generic-lcd"
    if let cached = artworkCache[file] { return cached }
    let image = NSImage(contentsOf: URL(filePath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/\(file).icns"))
    artworkCache[file] = image
    return image
  }

  private static var artworkCache: [String: NSImage] = [:]

  /// The display picked in the Displays preview; nil is the main one.
  var pickedDisplay: CGDirectDisplayID?

  var picked: Display? {
    displays.first { $0.id == pickedDisplay } ?? displays.first(where: \.main) ?? displays.first
  }

  private(set) var volume: Float?
  private(set) var muted = false
  private(set) var output: String?
  private(set) var wifiOn: Bool?
  private(set) var wifiName: String?
  private(set) var bluetoothOn: Bool?
  private(set) var displays: [Display] = []
  private(set) var mirrored = false
  private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
  /// A short line under the tiles when something couldn't be done.
  private(set) var note: String?
  @ObservationIgnored private var noteEnd: Task<Void, Never>?

  func say(_ text: String) {
    note = text
    noteEnd?.cancel()
    noteEnd = Task { [weak self] in
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled else { return }
      self?.note = nil
    }
  }

  /// The user's Shortcuts, for picking the Focus one; read off the main actor.
  var shortcuts: [String]?

  func loadShortcuts() {
    guard shortcuts == nil else { return }
    Task {
      shortcuts = await OffMain.value(timeout: 6) { Radios.shortcutNames() } ?? []
    }
  }

  /// Paired Bluetooth devices, read when their list opens.
  var devices: [BluetoothDevice] = []
  /// The tile opened for more (sound outputs, displays, devices, battery, Focus).
  var detail: Detail?

  enum Detail: Equatable { case sound, displays, bluetooth, battery, focus, wifi }

  @ObservationIgnored private var poll: Task<Void, Never>?

  /// Keeps reading while the tab shows: the keyboard's keys change these too.
  func watch(_ on: Bool) {
    poll?.cancel()
    poll = nil
    guard on else { return }
    refresh(full: true)
    poll = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1.5))
        self?.refresh(full: false)
      }
    }
  }

  func refresh(full: Bool) {
    // Set only what changed: each write redraws whoever reads it.
    let volume = AudioDevices.volume
    if volume != self.volume { self.volume = volume }
    let muted = AudioDevices.muted ?? false
    if muted != self.muted { self.muted = muted }
    let output = AudioDevices.outputName
    if output != self.output { self.output = output }
    let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    if lowPower != self.lowPower { self.lowPower = lowPower }
    readDisplays()
    if full { refreshRadios() }
  }

  /// Wi-Fi and Bluetooth are read off the main actor, with a deadline: the
  /// first Bluetooth read can wait on a permission prompt, and the island
  /// must never freeze behind it.
  func refreshRadios() {
    Task {
      if let wifi = await OffMain.value(timeout: 2, Radios.wifi) {
        wifiOn = wifi.on
        wifiName = wifi.name
      }
      let bluetooth = await OffMain.value(timeout: 2) { Radios.bluetoothOn() }
      bluetoothOn = bluetooth ?? nil
      if detail == .bluetooth, bluetoothOn == true {
        devices = await OffMain.value(timeout: 3) { Bluetooth.devices } ?? devices
      }
    }
  }

  // MARK: Sound

  func setVolume(_ level: Float) {
    AudioDevices.setVolume(level)
    volume = level
    if level > 0 { muted = false }
  }

  func toggleMute() {
    AudioDevices.setMuted(!muted)
    muted = AudioDevices.muted ?? !muted
  }

  // MARK: Displays

  private func readDisplays() {
    let displays: [Display] = NSScreen.screens.compactMap { screen in
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
      let id = CGDirectDisplayID(number.uint32Value)
      return Display(
        id: id, name: screen.localizedName, size: screen.frame.size, builtIn: CGDisplayIsBuiltin(id) != 0,
        main: CGDisplayIsMain(id) != 0, brightness: Brightness.get(id), frame: CGDisplayBounds(id)
      )
    }
    if displays != self.displays {
      self.displays = displays
      modeCache.removeAll()
    }
    let mirrored = displays.contains { CGDisplayIsInMirrorSet($0.id) != 0 }
    if mirrored != self.mirrored { self.mirrored = mirrored }
  }

  /// Each display's modes, read once per change of displays (the list is slow to build).
  @ObservationIgnored var modeCache: [CGDirectDisplayID: [Mode]] = [:]

  /// The built-in panel, else the first display that takes software brightness.
  var brightnessDisplay: Display? {
    displays.first { $0.builtIn && $0.brightness != nil } ?? displays.first { $0.brightness != nil }
  }

  var externalDisplays: [Display] { displays.filter { !$0.builtIn } }

  func setBrightness(_ level: Float, display: CGDirectDisplayID) {
    Brightness.set(display, level)
    if let index = displays.firstIndex(where: { $0.id == display }) { displays[index].brightness = level }
  }

  /// Mirrors every other display to the main one, or stops mirroring.
  func toggleMirroring() {
    let mainId = CGMainDisplayID()
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { return }
    for display in displays where display.id != mainId {
      CGConfigureDisplayMirrorOfDisplay(config, display.id, mirrored ? kCGNullDirectDisplay : mainId)
    }
    CGCompleteDisplayConfiguration(config, .forSession)
    Task {
      try? await Task.sleep(for: .milliseconds(800))
      readDisplays()
    }
  }

  // MARK: Radios

  func toggleWiFi() {
    let target = !(wifiOn ?? false)
    wifiOn = target
    Task {
      let ok = await OffMain.value(timeout: 4) { Radios.setWiFi(target) } ?? false
      if !ok { say("macOS didn't allow switching Wi-Fi just now.") }
      try? await Task.sleep(for: .seconds(1))
      refreshRadios()
    }
  }

  func toggleBluetooth() {
    guard let on = bluetoothOn else { return say("Bluetooth isn't available to the island yet — allow it when macOS asks.") }
    bluetoothOn = !on
    Task {
      let ok = await OffMain.value(timeout: 3) { Bluetooth.set(!on) } ?? false
      if !ok { say("Bluetooth can't be switched from here on this Mac.") }
      try? await Task.sleep(for: .seconds(1.2))
      refreshRadios()
    }
  }

  /// Finder's AirDrop window: who's around, and your own visibility.
  func openAirDrop() {
    let app = URL(filePath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app")
    if FileManager.default.fileExists(atPath: app.path) {
      NSWorkspace.shared.open(app)
    } else {
      Osascript.send("tell application \"Finder\" to activate\ntell application \"System Events\" to keystroke \"r\" using {command down, shift down}")
    }
  }

  /// Focus can't be switched by any public API: a Shortcut you name does it,
  /// else Focus settings open.
  func focusAction(shortcut: String) {
    let name = shortcut.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else {
      detail = .focus
      return
    }
    Task {
      if !(await AssistantState.runShortcut(name)) { say("The “\(name)” shortcut didn't run.") }
    }
  }
}

/// Built-in and Apple display brightness through DisplayServices, the private
/// framework System Settings uses. External DDC monitors aren't covered.
enum Brightness {
  private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
  private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32
  private typealias Can = @convention(c) (CGDirectDisplayID) -> Bool

  private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

  private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
    guard let handle, let pointer = dlsym(handle, name) else { return nil }
    return unsafeBitCast(pointer, to: type)
  }

  static func get(_ display: CGDirectDisplayID) -> Float? {
    if let can = symbol("DisplayServicesCanChangeBrightness", as: Can.self), !can(display) { return nil }
    guard let get = symbol("DisplayServicesGetBrightness", as: Get.self) else { return nil }
    var value: Float = 0
    return get(display, &value) == 0 ? value : nil
  }

  static func set(_ display: CGDirectDisplayID, _ level: Float) {
    guard let set = symbol("DisplayServicesSetBrightness", as: Set.self) else { return }
    _ = set(display, min(1, max(0.02, level)))
  }
}

/// The Bluetooth radio, through IOBluetooth's preference calls (as blueutil does).
nonisolated enum Bluetooth {
  private typealias Get = @convention(c) () -> Int32
  private typealias Set = @convention(c) (Int32) -> Void

  nonisolated(unsafe) private static let handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)

  private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
    guard let handle, let pointer = dlsym(handle, name) else { return nil }
    return unsafeBitCast(pointer, to: type)
  }

  static var isOn: Bool? {
    symbol("IOBluetoothPreferenceGetControllerPowerState", as: Get.self).map { $0() != 0 }
  }

  static func set(_ on: Bool) -> Bool {
    guard let set = symbol("IOBluetoothPreferenceSetControllerPowerState", as: Set.self) else { return false }
    set(on ? 1 : 0)
    return true
  }

  /// Paired devices, connected first.
  static var devices: [BluetoothDevice] {
    let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
    return paired.compactMap { device in
      guard let address = device.addressString else { return nil }
      let kind = switch device.deviceClassMajor {
      case 0x04: "headphones"  // audio/video
      case 0x05: "keyboard"  // peripheral
      case 0x02: "iphone"
      case 0x01: "laptopcomputer"
      default: Glyph.bluetooth
      }
      return BluetoothDevice(id: address, name: device.name ?? address, connected: device.isConnected(), kind: kind)
    }
    .sorted { ($0.connected ? 0 : 1, $0.name) < ($1.connected ? 0 : 1, $1.name) }
  }

  /// Connects or disconnects; the connect is asynchronous so the island never stalls.
  @MainActor static func toggle(address: String) {
    guard let device = IOBluetoothDevice(addressString: address) else { return }
    if device.isConnected() {
      device.closeConnection()
    } else {
      device.openConnection(ConnectionTarget.shared)
    }
  }

  /// IOBluetooth calls a target back when a connection completes; there's nothing to do then.
  @MainActor private final class ConnectionTarget: NSObject {
    static let shared = ConnectionTarget()
    @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {}
  }
}

// MARK: - In-notch detail

/// Display modes, the main display, sound outputs and Bluetooth devices:
/// everything the Controls tab changes without sending you to System Settings.
extension SystemControls {
  struct Mode: Identifiable, Hashable {
    let id: Int32
    let width: Int
    let height: Int
    let refresh: Double
    let hiDPI: Bool

    var label: String {
      let hz = refresh > 0 ? " · \(Int(refresh.rounded())) Hz" : ""
      return "\(width) × \(height)\(hiDPI ? "" : " (low res)")\(hz)"
    }
  }

  /// Each usable resolution once: HiDPI preferred, then the highest refresh.
  func modes(for display: CGDirectDisplayID) -> [Mode] {
    if let cached = modeCache[display] { return cached }
    let modes = readModes(for: display)
    modeCache[display] = modes
    return modes
  }

  private func readModes(for display: CGDirectDisplayID) -> [Mode] {
    let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    guard let all = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] else { return [] }
    var best: [String: Mode] = [:]
    for mode in all where mode.isUsableForDesktopGUI() {
      let candidate = Mode(id: mode.ioDisplayModeID, width: mode.width, height: mode.height, refresh: mode.refreshRate, hiDPI: mode.pixelWidth > mode.width)
      let key = "\(mode.width)x\(mode.height)"
      if let current = best[key] {
        let better = (candidate.hiDPI && !current.hiDPI) || (candidate.hiDPI == current.hiDPI && candidate.refresh > current.refresh)
        if !better { continue }
      }
      best[key] = candidate
    }
    return best.values.sorted { ($0.width, $0.height) > ($1.width, $1.height) }
  }

  func currentMode(for display: CGDirectDisplayID) -> Int32? {
    CGDisplayCopyDisplayMode(display)?.ioDisplayModeID
  }

  func setMode(_ mode: Mode, for display: CGDirectDisplayID) {
    let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    guard let all = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode],
      let target = all.first(where: { $0.ioDisplayModeID == mode.id })
    else { return }
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { return }
    CGConfigureDisplayWithDisplayMode(config, display, target, nil)
    CGCompleteDisplayConfiguration(config, .permanently)
    refresh(full: false)
  }

  /// Makes `display` the main one (the menu bar moves there) by putting its
  /// origin at zero and shifting the others the same amount.
  func makeMain(_ display: CGDirectDisplayID) {
    let shift = CGDisplayBounds(display).origin
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { return }
    for other in displays {
      let origin = CGDisplayBounds(other.id).origin
      CGConfigureDisplayOrigin(config, other.id, Int32(origin.x - shift.x), Int32(origin.y - shift.y))
    }
    CGCompleteDisplayConfiguration(config, .permanently)
    Task {
      try? await Task.sleep(for: .milliseconds(800))
      refresh(full: false)
    }
  }

  // MARK: Sound outputs

  struct Output: Identifiable, Equatable {
    let id: AudioObjectID
    let name: String
  }

  var outputs: [Output] { AudioDevices.outputs }

  var currentOutput: AudioObjectID? { AudioDevices.defaultDevice(input: false) }

  func setOutput(_ id: AudioObjectID) {
    AudioDevices.setDefaultOutput(id)
    refresh(full: false)
  }

  // MARK: Bluetooth devices

  func toggleDevice(_ device: BluetoothDevice) {
    Bluetooth.toggle(address: device.id)
    Task {
      try? await Task.sleep(for: .seconds(2))
      refreshRadios()
    }
  }
}

nonisolated struct BluetoothDevice: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let connected: Bool
  let kind: String
}

/// Wi-Fi and the Bluetooth radio's power, callable off the main actor.
nonisolated enum Radios {
  struct WiFi: Sendable {
    var on: Bool?
    var name: String?
  }

  static func wifi() -> WiFi {
    let interface = CWWiFiClient.shared().interface()
    return WiFi(on: interface?.powerOn(), name: interface?.ssid())
  }

  static func setWiFi(_ on: Bool) -> Bool {
    guard let interface = CWWiFiClient.shared().interface() else { return false }
    return (try? interface.setPower(on)) != nil
  }

  static func bluetoothOn() -> Bool? { Bluetooth.isOn }

  static func shortcutNames() -> [String] {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/shortcuts")
    process.arguments = ["list"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
  }
}

/// Runs blocking system calls on a background queue and gives up waiting after
/// `timeout` (the call may finish later; its answer is then dropped).
nonisolated enum OffMain {
  private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if done { return false }
      done = true
      return true
    }
  }

  static func value<T: Sendable>(timeout: TimeInterval, _ work: @escaping @Sendable () -> T) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
      let once = Once()
      DispatchQueue.global(qos: .userInitiated).async {
        let value = work()
        if once.claim() { continuation.resume(returning: value) }
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        if once.claim() { continuation.resume(returning: nil) }
      }
    }
  }
}


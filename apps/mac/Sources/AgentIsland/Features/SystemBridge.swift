import AppKit
import AudioToolbox
import Carbon.HIToolbox
import CoreAudio
import Foundation

/// AppleScript through `osascript`, off the main actor, with its output. The
/// first script for an app asks the user once (Automation, in Privacy &
/// Security); a refusal is just a nil here.
enum Osascript {
  @concurrent
  nonisolated static func run(_ source: String, timeout: TimeInterval = 4) async -> String? {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    // A hung target app (a modal dialog) must never hang the island.
    let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    watchdog.cancel()
    guard process.terminationStatus == 0 else { return nil }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Fire and forget.
  static func send(_ source: String) {
    Task { _ = await run(source) }
  }
}

/// Keystrokes and media keys, posted as the hardware would. Both need the
/// Accessibility grant the island already asks for to type prompts.
enum KeyPoster {
  /// One key with modifiers, to `pid` when given (it needn't be frontmost),
  /// else to whatever is.
  @discardableResult
  static func press(_ key: Int, _ flags: CGEventFlags = [], to pid: pid_t? = nil) -> Bool {
    guard Accessibility.isTrusted else {
      Accessibility.requestOnce()
      return false
    }
    let source = CGEventSource(stateID: .hidSystemState)
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: true),
      let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: false)
    else { return false }
    down.flags = flags
    up.flags = flags
    if let pid {
      down.postToPid(pid)
      up.postToPid(pid)
    } else {
      down.post(tap: .cghidEventTap)
      up.post(tap: .cghidEventTap)
    }
    return true
  }

  enum MediaKey: Int32 {
    case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7, play = 16, next = 17, previous = 18
  }

  /// The keyboard's media keys (NX_KEYTYPE_*): they go to whatever owns Now Playing.
  @discardableResult
  static func media(_ key: MediaKey) -> Bool {
    guard Accessibility.isTrusted else {
      Accessibility.requestOnce()
      return false
    }
    for down in [true, false] {
      let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
      let data1 = Int((key.rawValue << 16) | ((down ? 0xA : 0xB) << 8))
      let event = NSEvent.otherEvent(
        with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
        subtype: 8, data1: data1, data2: -1
      )
      event?.cgEvent?.post(tap: .cghidEventTap)
    }
    return true
  }

  static let leftBracket = kVK_ANSI_LeftBracket
  static let rightBracket = kVK_ANSI_RightBracket
}

/// Reading another app's menus through Accessibility: Zoom's Meeting menu
/// says whether you're muted, and pressing its items needs no focus change.
enum MenuReader {
  /// Every menu item title in `pid`'s menu bar, with the element to press.
  static func items(of pid: pid_t) -> [(title: String, element: AXUIElement)] {
    guard Accessibility.isTrusted else { return [] }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    guard let bar: AXUIElement = attribute(app, kAXMenuBarAttribute) else { return [] }
    var out: [(String, AXUIElement)] = []
    for top in children(bar) {
      for menu in children(top) {
        for item in children(menu) {
          if let title: String = attribute(item, kAXTitleAttribute), !title.isEmpty { out.append((title, item)) }
        }
      }
    }
    return out
  }

  /// Presses the first item whose title is one of `titles` (case-insensitive).
  @discardableResult
  static func press(_ titles: [String], in pid: pid_t) -> Bool {
    let wanted = Set(titles.map { $0.lowercased() })
    guard let item = items(of: pid).first(where: { wanted.contains($0.title.lowercased()) }) else { return false }
    return AXUIElementPerformAction(item.element, kAXPressAction as CFString) == .success
  }

  /// The focused window's title (Firefox's tab title).
  static func focusedWindowTitle(of pid: pid_t) -> String? {
    guard Accessibility.isTrusted else { return nil }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.5)
    guard let window: AXUIElement = attribute(app, kAXFocusedWindowAttribute) else { return nil }
    return attribute(window, kAXTitleAttribute)
  }

  private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? T
  }

  private static func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as [AXUIElement]?) ?? []
  }
}

/// Core Audio, for the volume control and for noticing a call holds the mic.
enum AudioDevices {
  static func defaultDevice(input: Bool) -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
      mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )
    var device = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return status == noErr && device != 0 ? device : nil
  }

  /// Some app has the default microphone open right now.
  static var micInUse: Bool {
    guard let device = defaultDevice(input: true) else { return false }
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var running: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
  }

  private static func outputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
  }

  /// 0…1, or nil when the output has no software volume (some HDMI and USB devices).
  static var volume: Float? {
    guard let device = defaultDevice(input: false) else { return nil }
    var address = outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
    var value = Float32(0)
    var size = UInt32(MemoryLayout<Float32>.size)
    guard AudioObjectHasProperty(device, &address), AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
      return nil
    }
    return value
  }

  static func setVolume(_ level: Float) {
    guard let device = defaultDevice(input: false) else { return }
    var address = outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
    var value = Float32(min(1, max(0, level)))
    let size = UInt32(MemoryLayout<Float32>.size)
    if AudioObjectHasProperty(device, &address) {
      AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
    }
    // Dragging up from silence unmutes, as the keyboard keys do.
    if level > 0, muted == true { setMuted(false) }
  }

  static var muted: Bool? {
    guard let device = defaultDevice(input: false) else { return nil }
    var address = outputAddress(kAudioDevicePropertyMute)
    var value = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectHasProperty(device, &address), AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
      return nil
    }
    return value != 0
  }

  static func setMuted(_ on: Bool) {
    guard let device = defaultDevice(input: false) else { return }
    var address = outputAddress(kAudioDevicePropertyMute)
    var value = UInt32(on ? 1 : 0)
    guard AudioObjectHasProperty(device, &address) else { return }
    AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
  }

  /// Every device that can play sound.
  static var outputs: [SystemControls.Output] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(0)
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
      var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
      var streamSize = UInt32(0)
      guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0, let name = name(of: id) else { return nil }
      return SystemControls.Output(id: id, name: name)
    }
  }

  static func setDefaultOutput(_ id: AudioObjectID) {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )
    var device = id
    AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &device)
  }

  static func name(of device: AudioObjectID) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
    return name.takeRetainedValue() as String
  }

  /// The output's name ("MacBook Pro Speakers", "AirPods Pro").
  static var outputName: String? {
    guard let device = defaultDevice(input: false) else { return nil }
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
    return name.takeRetainedValue() as String
  }
}

/// Every process's short name, for spotting Zoom's in-call helper. libproc,
/// so no `ps` to spawn.
enum ProcessNames {
  static func all() -> Set<String> {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) * 2)
    let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    var names: Set<String> = []
    var buffer = [CChar](repeating: 0, count: 256)
    for pid in pids.prefix(Int(max(0, filled))) where pid > 0 {
      if proc_name(pid, &buffer, UInt32(buffer.count)) > 0 { names.insert(String(cString: buffer)) }
    }
    return names
  }
}

/// System Settings panes the controls send you to.
enum SettingsPane {
  static func open(_ id: String) {
    if let url = URL(string: "x-apple.systempreferences:\(id)") { NSWorkspace.shared.open(url) }
  }

  static let focus = "com.apple.Focus-Settings.extension"
  static let displays = "com.apple.Displays-Settings.extension"
  static let battery = "com.apple.Battery-Settings.extension"
  static let wifi = "com.apple.wifi-settings-extension"
  static let bluetooth = "com.apple.BluetoothSettings"
  static let sound = "com.apple.Sound-Settings.extension"
  static let automation = "com.apple.preference.security?Privacy_Automation"
}

/// Whether this app may already send Apple Events to another, asked without
/// prompting. Background reads (meeting tabs, music catch-up, the browser's
/// tab) only go to apps already allowed; the first prompt only ever comes from
/// something you clicked.
enum Automation {
  /// True: allowed. False: refused or not asked yet. Nil: the app isn't running.
  static func isAllowed(_ bundleId: String) -> Bool? {
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty else { return nil }
    let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
    guard let desc = target.aeDesc else { return false }
    let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false)
    return status == noErr
  }
}

/// macOS 15.4+ asks before an app reads the clipboard in the background,
/// unless you've set it to always allow.
enum PasteAccess {
  static var backgroundAllowed: Bool {
    if #available(macOS 15.4, *) { return NSPasteboard.general.accessBehavior == .alwaysAllow }
    return true
  }
}

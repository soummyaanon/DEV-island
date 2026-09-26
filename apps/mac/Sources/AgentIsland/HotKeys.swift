import Carbon.HIToolbox

/// System-wide shortcuts that work while your terminal has focus: ⌘Y/⌘N for a
/// pending approval, ⌘1…9 for a waiting question, ⌃⌥⌘I for VoiceOver. Each
/// is registered only while it means something (1.x's globalShortcut), and
/// Carbon's hot keys need no Accessibility grant.
final class HotKeys {
  struct Combo: Hashable {
    var keyCode: Int
    var modifiers: Int

    static func command(_ keyCode: Int) -> Combo { Combo(keyCode: keyCode, modifiers: cmdKey) }

    static let allow = command(kVK_ANSI_Y)
    static let deny = command(kVK_ANSI_N)
    static let voiceOver = Combo(keyCode: kVK_ANSI_I, modifiers: controlKey | optionKey | cmdKey)

    /// ⌘1…⌘9.
    static func option(_ index: Int) -> Combo {
      let keys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
      return command(keys[index])
    }
  }

  private var registered: [Combo: (id: UInt32, ref: EventHotKeyRef)] = [:]
  private var actions: [UInt32: () -> Void] = [:]
  private var nextId: UInt32 = 1
  private var handler: EventHandlerRef?

  init() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let context = Unmanaged.passUnretained(self).toOpaque()
    InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
      guard let event, let context else { return OSStatus(eventNotHandledErr) }
      var id = EventHotKeyID()
      GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &id
      )
      // Carbon delivers hot keys on the main thread.
      MainActor.assumeIsolated {
        Log.app.notice("hot key \(id.id) pressed")
        Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue().actions[id.id]?()
      }
      return noErr
    }, 1, &spec, context, &handler)
  }

  /// Registers `combo`; false if another app already holds it.
  @discardableResult
  func register(_ combo: Combo, action: @escaping () -> Void) -> Bool {
    unregister(combo)
    var ref: EventHotKeyRef?
    let id = nextId
    nextId += 1
    let status = RegisterEventHotKey(
      UInt32(combo.keyCode), UInt32(combo.modifiers), EventHotKeyID(signature: OSType(0x4149_534C), id: id),
      GetApplicationEventTarget(), 0, &ref
    )
    guard status == noErr, let ref else {
      Log.app.error("hot key \(combo.keyCode) refused: \(status)")
      return false
    }
    registered[combo] = (id, ref)
    actions[id] = action
    return true
  }

  func unregister(_ combo: Combo) {
    guard let entry = registered.removeValue(forKey: combo) else { return }
    UnregisterEventHotKey(entry.ref)
    actions[entry.id] = nil
  }
}

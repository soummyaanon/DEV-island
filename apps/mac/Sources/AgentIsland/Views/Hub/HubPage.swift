import AppKit
import IslandCore
import SwiftUI

/// The open island's second page: one tool at a time under a row of names.
struct HubPage: View {
  let model: IslandModel
  let tab: HubTab
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Group {
        switch tab {
        case .agents: AgentsTab(model: model, now: now)
        case .controls: ControlsTab(model: model, now: now)
        case .shelf: ShelfTab(model: model)
        case .clipboard: ClipboardTab(model: model, now: now)
        case .agenda: AgendaTab(model: model, now: now)
        case .timers: TimersTab(model: model, now: now)
        case .widgets: WidgetsTab(model: model)
        case .prompter: PrompterTab(model: model)
        case .ask: EmptyView()
        }
      }
      .id(tab)
      .modifier(Entrance(kind: .rowIn, delay: 0.02))
    }
    .frame(width: 440, alignment: .leading)
    .padding(.init(top: 6, leading: 10, bottom: 4, trailing: 10))
  }
}

/// A text field in a tool: it takes the keyboard while focused and gives it back.
struct HubField: View {
  let model: IslandModel
  let placeholder: String
  @Binding var text: String
  /// Compact by default, centred in whatever holds it.
  var width: CGFloat = 170
  /// Centred in the space it's given; off when it sits in a row.
  var centered = true
  var onSubmit: () -> Void = {}
  @FocusState private var focused: Bool

  var body: some View {
    if centered {
      field.frame(width: width).frame(maxWidth: .infinity, alignment: .center)
    } else {
      field.frame(width: width)
    }
  }

  private var field: some View {
    TextField("", text: $text, prompt: fieldPrompt(placeholder))
      .textFieldStyle(.plain)
      .islandFont(11)
      .foregroundStyle(Palette.text)
      .tint(Palette.caret)
      .focused($focused)
      .onSubmit(onSubmit)
      .onExitCommand { focused = false }
      .multilineTextAlignment(.center)
      .padding(.horizontal, 10)
      .frame(height: 26)
      .modifier(FieldPill(focused: focused))
      .onChange(of: focused) { _, now in model.hubTyping = now }
      .onDisappear { if focused { model.hubTyping = false } }
  }
}

// MARK: - Controls

/// Control Centre in the notch: every control acts here, and the tiles open
/// their detail in place instead of sending you to System Settings.
private struct ControlsTab: View {
  let model: IslandModel
  let now: Date

  var body: some View {
    let system = model.system
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 10) {
        // Left: the time and the two sliders.
        VStack(alignment: .leading, spacing: 8) {
          VStack(alignment: .leading, spacing: 0) {
            Text(now, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
              .islandFont(30, weight: .semibold)
              .monospacedDigit()
              .foregroundStyle(Palette.text)
            Text(now, format: .dateTime.weekday(.abbreviated).month().day())
              .islandFont(10)
              .foregroundStyle(Palette.textDim)
          }
          SliderRow(
            symbol: system.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: system.output ?? "Volume",
            value: system.muted ? 0 : system.volume, onSymbol: { system.toggleMute() },
            more: { toggle(.sound) }, open: system.detail == .sound
          ) { system.setVolume($0) }
          if let display = system.brightnessDisplay, let level = display.brightness {
            SliderRow(symbol: "sun.max.fill", label: "Brightness", value: level, onSymbol: nil, more: nil, open: false) {
              system.setBrightness($0, display: display.id)
            }
          }
        }
        .frame(width: 196)
        Rectangle().fill(.white.opacity(0.07)).frame(width: 1).padding(.vertical, 4)
        // Right: the toggles, round.
        Grid(horizontalSpacing: 14, verticalSpacing: 8) {
          GridRow {
            CircleKey(symbol: "wifi", caption: "Wi-Fi", on: system.wifiOn == true, label: system.wifiName ?? "Wi-Fi") { system.toggleWiFi() }
              .contextMenu { Button("Details") { toggle(.wifi) } }
            CircleKey(symbol: Glyph.bluetooth, caption: "Bluetooth", on: system.bluetoothOn == true) {
              system.toggleBluetooth()
            }
            .contextMenu { Button("Devices") { toggle(.bluetooth); system.refreshRadios() } }
            CircleKey(symbol: Glyph.airdrop, caption: "AirDrop") {
              if model.shelf.items.isEmpty { system.openAirDrop() } else { model.shelf.airDrop() }
            }
          }
          GridRow {
            CircleKey(symbol: "moon.fill", caption: "Focus", on: model.focus.active, tint: Color(hex: 0xA77BFF)) {
              if model.settings.focusShortcut.isEmpty { toggle(.focus) } else { system.focusAction(shortcut: model.settings.focusShortcut) }
            }
            .contextMenu { Button("Choose Shortcut") { toggle(.focus) } }
            CircleKey(symbol: "display.2", caption: "Displays", on: system.detail == .displays, tint: .white.opacity(0.3)) { toggle(.displays) }
            CircleKey(
              symbol: model.power.reading.map { $0.isOnBattery ? "battery.75percent" : "battery.100percent.bolt" } ?? "powerplug.fill",
              caption: model.power.reading.map { "\($0.percent)%" } ?? "Power", on: system.detail == .battery, tint: .white.opacity(0.3)
            ) { toggle(.battery) }
          }
          GridRow {
            Color.clear.frame(width: 1, height: 1)
            CircleKey(symbol: "chevron.down", caption: "More", on: system.detail == .bluetooth || system.detail == .wifi, tint: .white.opacity(0.3), size: 24) {
              toggle(system.bluetoothOn == true ? .bluetooth : .wifi)
              system.refreshRadios()
            }
            Color.clear.frame(width: 1, height: 1)
          }
        }
        .frame(maxWidth: .infinity)
      }
      if system.detail == .sound { SoundDetail(system: system) }
      if let note = system.note {
        Text(note).islandFont(9.5).foregroundStyle(Palette.waiting)
      }
      if let detail = system.detail, detail != .sound {
        ScrollView(.vertical) {
          switch detail {
          case .displays: DisplaysDetail(system: system)
          case .bluetooth: BluetoothDetail(system: system)
          case .battery: BatteryDetail(model: model)
          case .focus: FocusDetail(model: model)
          case .wifi: WiFiDetail(system: system)
          case .sound: EmptyView()
          }
        }
        .frame(maxHeight: 170)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .onAppear { system.watch(true) }
    .onDisappear {
      system.watch(false)
      system.detail = nil
    }
  }

  private func toggle(_ detail: SystemControls.Detail) {
    model.system.detail = model.system.detail == detail ? nil : detail
  }
}

/// A labelled slider with a glyph you can click (mute) and an optional chevron for more.
private struct SliderRow: View {
  let symbol: String
  let label: String
  let value: Float?
  let onSymbol: (() -> Void)?
  let more: (() -> Void)?
  let open: Bool
  let set: (Float) -> Void

  var body: some View {
    HStack(spacing: 8) {
      Button { onSymbol?() } label: {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 18)
      }
      .buttonStyle(.plain)
      .foregroundStyle(Palette.text)
      .disabled(onSymbol == nil)
      .help(onSymbol == nil ? label : "Mute or unmute")
      if let value {
        Slider(value: Binding(get: { Double(value) }, set: { set(Float($0)) }), in: 0...1)
          .controlSize(.mini)
          .tint(.white)
          .accessibilityLabel(label)
          .help("\(label) · \(Int((value * 100).rounded()))%")
      } else {
        Text("—").islandFont(9.5).foregroundStyle(Palette.textDim).frame(maxWidth: .infinity, alignment: .leading)
      }
      if let more {
        QuickButton(symbol: open ? "chevron.up" : "chevron.down", label: "Choose the output", size: 9, action: more)
      }
    }
    .padding(.init(top: 5, leading: 8, bottom: 5, trailing: 4))
    .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.05)))
  }
}

/// The inline panel under the tiles.
private struct DetailBox<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title.uppercased()).islandFont(9, weight: .semibold).foregroundStyle(Palette.textDim).kerning(0.6)
      content
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
    .modifier(Entrance(kind: .rowIn))
  }
}

/// One choice in a detail list, ticked when current.
private struct ChoiceLine: View {
  let symbol: String
  let title: String
  var detail: String? = nil
  let on: Bool
  let action: () -> Void

  var body: some View {
    Hovering { hovered in
      Button(action: action) {
        HStack(spacing: 7) {
          Glyph(symbol, size: 10).frame(width: 16).foregroundStyle(on ? Palette.accent : Palette.textDim)
          Text(title).islandFont(10.5, weight: on ? .semibold : .regular).foregroundStyle(Palette.text).lineLimit(1)
          Spacer(minLength: 4)
          if let detail { Text(detail).islandFont(9).foregroundStyle(Palette.textDim) }
          if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.accent) }
        }
        .padding(.init(top: 3, leading: 4, bottom: 3, trailing: 4))
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(hovered ? 0.07 : 0)))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
  }
}

private struct SoundDetail: View {
  let system: SystemControls

  var body: some View {
    let current = system.currentOutput
    DetailBox(title: "Output") {
      ForEach(system.outputs) { output in
        ChoiceLine(symbol: output.name.localizedCaseInsensitiveContains("airpods") || output.name.localizedCaseInsensitiveContains("head") ? "headphones" : "hifispeaker.fill", title: output.name, on: output.id == current) {
          system.setOutput(output.id)
        }
      }
    }
  }
}

struct DisplaysDetail: View {
  let system: SystemControls

  var body: some View {
    let picked = system.picked
    HStack(alignment: .center, spacing: 12) {
      // Left: the displays as they're arranged; click one to pick it.
      DisplayArrangement(system: system)
        .frame(width: 180, height: 92)
      // Right: the picked display's few controls.
      if let picked {
        VStack(alignment: .leading, spacing: 6) {
          Text(picked.name).islandFont(10, weight: .semibold).foregroundStyle(Palette.text).lineLimit(1)
          ResolutionMenu(system: system, display: picked)
          if let level = picked.brightness {
            HStack(spacing: 5) {
              Image(systemName: "sun.max.fill").font(.system(size: 9)).foregroundStyle(Palette.textDim)
              Slider(value: Binding(get: { Double(level) }, set: { system.setBrightness(Float($0), display: picked.id) }), in: 0...1)
                .controlSize(.mini).tint(.white)
            }
          }
          HStack(spacing: 8) {
            if system.displays.count > 1 {
              CircleKey(symbol: "menubar.rectangle", on: picked.main, size: 24, label: picked.main ? "Main display" : "Make main") {
                if !picked.main { system.makeMain(picked.id) }
              }
              CircleKey(symbol: "rectangle.on.rectangle", on: system.mirrored, size: 24, label: system.mirrored ? "Stop mirroring" : "Mirror") {
                system.toggleMirroring()
              }
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(8)
    .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.05)))
  }
}

/// Each display drawn to scale where it sits: a laptop for the built-in
/// panel, a monitor on a stand for the rest, the menu bar on the main one.
private struct DisplayArrangement: View {
  let system: SystemControls

  var body: some View {
    GeometryReader { proxy in
      let displays = system.displays
      let union = displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
      let scale = union.isNull ? 1 : min((proxy.size.width - 8) / union.width, (proxy.size.height - 16) / union.height)
      let offset = CGPoint(
        x: (proxy.size.width - union.width * scale) / 2 - union.minX * scale,
        y: (proxy.size.height - 12 - union.height * scale) / 2 - union.minY * scale
      )
      ZStack(alignment: .topLeading) {
        ForEach(displays) { display in
          let rect = CGRect(
            x: display.frame.minX * scale + offset.x, y: display.frame.minY * scale + offset.y,
            width: display.frame.width * scale, height: display.frame.height * scale
          )
          DeviceGlyph(display: display, picked: display.id == system.picked?.id, size: rect.size)
            .frame(width: rect.width, height: rect.height + 8, alignment: .top)
            .offset(x: rect.minX, y: rect.minY)
            .onTapGesture { system.pickedDisplay = display.id }
            .help("\(display.name) · \(Int(display.frame.width)) × \(Int(display.frame.height))")
        }
      }
    }
  }
}

/// One display as System Settings shows it: Apple's own artwork for it (this
/// Mac's model, Apple's displays by name, a generic monitor), the picked one
/// ringed, the main one marked with a menu bar.
private struct DeviceGlyph: View {
  let display: SystemControls.Display
  let picked: Bool
  let size: CGSize

  var body: some View {
    VStack(spacing: 2) {
      if let art = SystemControls.artwork(for: display) {
        Image(nsImage: art)
          .resizable()
          .interpolation(.high)
          .aspectRatio(contentMode: .fit)
          // The artwork carries a margin and a base: draw it a size up.
          .frame(width: size.width * 1.35, height: size.height * 1.35)
          .frame(width: size.width, height: size.height)
      } else {
        RoundedRectangle(cornerRadius: 3).fill(Color(hex: 0x2B3550)).frame(width: size.width, height: size.height)
      }
      HStack(spacing: 3) {
        if display.main { Image(systemName: "menubar.rectangle").font(.system(size: 7)).foregroundStyle(Palette.textDim) }
        Capsule().fill(picked ? Palette.accent : .clear).frame(width: 14, height: 2.5)
      }
      .frame(height: 6)
    }
    .contentShape(Rectangle())
  }
}

private struct ResolutionMenu: View {
  let system: SystemControls
  let display: SystemControls.Display

  var body: some View {
    let modes = system.modes(for: display.id)
    let current = system.currentMode(for: display.id)
    Menu {
      ForEach(modes) { mode in
        Button { system.setMode(mode, for: display.id) } label: {
          if mode.id == current { Label(mode.label, systemImage: "checkmark") } else { Text(mode.label) }
        }
      }
    } label: {
      Text(modes.first { $0.id == current }.map { "\($0.width) × \($0.height)" } ?? "\(Int(display.size.width)) × \(Int(display.size.height))")
        .islandFont(9.5).monospacedDigit()
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("Resolution")
  }
}

private struct BluetoothDetail: View {
  let system: SystemControls

  var body: some View {
    let devices = system.bluetoothOn == true ? system.devices : []
    DetailBox(title: "Bluetooth devices") {
      if system.bluetoothOn != true {
        Text("Bluetooth is off. Click its icon to turn it on.").islandFont(10).foregroundStyle(Palette.textDim)
      } else if devices.isEmpty {
        Text("No paired devices.").islandFont(10).foregroundStyle(Palette.textDim)
      }
      ForEach(devices) { device in
        ChoiceLine(symbol: device.kind, title: device.name, detail: device.connected ? "Connected" : "Connect", on: device.connected) {
          system.toggleDevice(device)
        }
      }
    }
  }
}

private struct WiFiDetail: View {
  let system: SystemControls

  var body: some View {
    DetailBox(title: "Wi-Fi") {
      HStack {
        Text(system.wifiOn == true ? (system.wifiName.map { "Connected to \($0)" } ?? "On") : "Off").islandFont(10.5).foregroundStyle(Palette.text)
        Spacer()
        Toggle("Wi-Fi", isOn: Binding(get: { system.wifiOn == true }, set: { _ in system.toggleWiFi() }))
          .toggleStyle(.switch).controlSize(.mini).labelsHidden()
      }
    }
  }
}

private struct BatteryDetail: View {
  let model: IslandModel

  var body: some View {
    DetailBox(title: "Battery") {
      if let reading = model.power.reading {
        HStack(spacing: 8) {
          BatteryRing(percent: reading.percent, charging: !reading.isOnBattery, low: reading.isLow, size: 22, animated: !model.isPaused)
          VStack(alignment: .leading, spacing: 1) {
            Text(PowerDescription.detail(reading)).islandFont(11, weight: .semibold).foregroundStyle(Palette.text)
            Text("Energy mode: \(model.power.energyMode.rawValue.capitalized)" + (model.system.lowPower ? " · Low Power Mode on" : ""))
              .islandFont(9.5).foregroundStyle(Palette.textDim)
          }
        }
      } else {
        Text(model.settings.battery ? "This Mac runs on power — no battery." : "Battery is off in Live activities.").islandFont(10).foregroundStyle(Palette.textDim)
      }
    }
  }
}

private struct FocusDetail: View {
  let model: IslandModel

  var body: some View {
    let names = model.system.shortcuts ?? []
    let likely = names.filter { name in ["focus", "disturb", "dnd", "sleep", "work"].contains { name.lowercased().contains($0) } }
    DetailBox(title: "Focus") {
      Text(model.focus.active ? "On — \(model.focus.name ?? "Focus")" : "Off")
        .islandFont(11, weight: .semibold).foregroundStyle(Palette.text)
      if model.system.shortcuts == nil {
        Text("Reading your Shortcuts…").islandFont(9.5).foregroundStyle(Palette.textDim)
      } else if names.isEmpty {
        Text("Add a “Set Focus” Shortcut to switch Focus here.").islandFont(9.5).foregroundStyle(Palette.textDim)
      }
      ForEach((likely.isEmpty ? Array(names.prefix(6)) : likely).prefix(8), id: \.self) { name in
        ChoiceLine(symbol: "moon", title: name, on: model.settings.focusShortcut == name) {
          model.changeSettings { $0.focusShortcut = name }
          model.system.focusAction(shortcut: name)
        }
      }
      if model.focus.active {
        TextKey(title: "Mark Focus off", tint: Palette.textDim) { model.setFocus(MacFocus()) }
      }
    }
    .onAppear { model.system.loadShortcuts() }
  }
}

// MARK: - Clipboard

private struct ClipboardTab: View {
  let model: IslandModel
  let now: Date

  var body: some View {
    let clipboard = model.clipboard
    let _ = clipboard.waitingForAccess
    SplitPane(leftWidth: 80) {
      // Left: what to show, and the two switches.
      Grid(horizontalSpacing: 8, verticalSpacing: 8) {
        GridRow {
          CircleKey(symbol: "square.grid.2x2", on: clipboard.filter == nil, size: 28, label: "All") { clipboard.filter = nil }
          filter(.text, "textformat")
        }
        GridRow {
          filter(.link, "link")
          filter(.image, "photo")
        }
        GridRow {
          filter(.file, "doc")
          CircleKey(symbol: clipboard.paused ? "play.fill" : "pause.fill", on: clipboard.paused, tint: Palette.waiting, size: 28, label: clipboard.paused ? "Resume history" : "Pause history") {
            clipboard.paused.toggle()
          }
        }
        GridRow {
          CircleKey(symbol: "trash", size: 28, label: "Clear all") { clipboard.clear() }
          Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Palette.textDim)
            .help("Memory only · secrets skipped\(clipboard.skipped > 0 ? " (\(clipboard.skipped))" : "")")
        }
      }
    } right: {
      if clipboard.shown.isEmpty, !PasteAccess.backgroundAllowed {
        VStack(spacing: 4) {
          Image(systemName: "lock.doc").font(.system(size: 20, weight: .light)).foregroundStyle(Palette.textDim)
          Text("Paste access: Always Allow").islandFont(9).foregroundStyle(Palette.textDim)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .help("macOS asks before apps read the clipboard. To keep history while you work, set Agent Island to Always Allow under Privacy & Security → Paste from Other Apps. Until then, it reads when you open this tab.")
      } else if clipboard.shown.isEmpty {
        Image(systemName: clipboard.paused ? "pause.circle" : "doc.on.clipboard")
          .font(.system(size: 22)).foregroundStyle(Palette.textDim)
          .frame(maxWidth: .infinity, minHeight: 120)
      } else {
        ScrollView {
          VStack(spacing: 3) {
            ForEach(clipboard.shown) { clip in
              ClipRow(model: model, clip: clip, now: now)
            }
          }
        }
        .frame(maxHeight: 200)
        .fixedSize(horizontal: false, vertical: true)
        .help("Click to copy · ⌥-click to delete")
      }
    }
    .onAppear { clipboard.captureNow() }
  }

  private func filter(_ kind: ClipboardHistory.Clip.Kind, _ symbol: String) -> some View {
    let clipboard = model.clipboard
    return CircleKey(symbol: symbol, on: clipboard.filter == kind, size: 28, label: kind.rawValue.capitalized) {
      clipboard.filter = clipboard.filter == kind ? nil : kind
    }
  }
}

private struct ClipRow: View {
  let model: IslandModel
  let clip: ClipboardHistory.Clip
  let now: Date

  var body: some View {
    let clipboard = model.clipboard
    Hovering { hovered in
      HStack(spacing: 8) {
        Button {
          // ⌥-click deletes, as in Finder's list of recent items.
          if NSEvent.modifierFlags.contains(.option) { clipboard.remove(clip.id) } else { clipboard.copy(clip) }
        } label: {
          HStack(spacing: 8) {
            if let files = clip.files, let first = files.first {
              Image(nsImage: NSWorkspace.shared.icon(forFile: first)).resizable().frame(width: 26, height: 26)
            } else if clip.kind == .link {
              Image(systemName: "link").frame(width: 26, height: 26).foregroundStyle(Palette.accent)
            } else if let image = clipboard.thumbnails[clip.id] {
              Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: 34, height: 26).clipShape(RoundedRectangle(cornerRadius: 4))
            } else if clip.image != nil {
              Image(systemName: "photo").frame(width: 34, height: 26).foregroundStyle(Palette.textDim)
            }
            VStack(alignment: .leading, spacing: 1) {
              Text(clip.files.map { $0.map { URL(filePath: $0).lastPathComponent }.joined(separator: ", ") }
                ?? clip.text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "Image")
                .islandFont(11).foregroundStyle(Palette.text).lineLimit(2).multilineTextAlignment(.leading)
              Text([clip.source, clip.date.formatted(.relative(presentation: .named))].compactMap(\.self).joined(separator: " · "))
                .islandFont(9).foregroundStyle(Palette.textDim).lineLimit(1)
            }
            Spacer(minLength: 0)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy again")
        if hovered {
          MiniKey(symbol: "doc.on.doc", label: "Copy") { clipboard.copy(clip) }
          MiniKey(symbol: "trash", label: "Delete") { clipboard.remove(clip.id) }
        }
      }
      .padding(.init(top: 4, leading: 7, bottom: 4, trailing: 7))
      .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(hovered ? 0.08 : 0.035)))
    }
  }
}

// MARK: - Today

private struct AgendaTab: View {
  let model: IslandModel
  let now: Date
  private let draft = State(initialValue: "")

  var body: some View {
    let agenda = model.agenda
    SplitPane(leftWidth: 196) {
      // Left: the month.
      if agenda.eventAccess == .granted {
        MonthView(agenda: agenda, now: now)
      } else {
        CircleKey(symbol: "calendar", caption: agenda.eventAccess == .denied ? "Privacy" : "Allow", size: 40) {
          if agenda.eventAccess == .denied { agenda.openPrivacySettings() } else { agenda.requestAccess() }
        }
        .frame(maxWidth: .infinity, minHeight: 150)
      }
    } right: {
      // Right: the picked day, then your to-dos.
      VStack(alignment: .leading, spacing: 6) {
        Text(agenda.selected, format: .dateTime.weekday(.wide).day().month(.abbreviated))
          .islandFont(10, weight: .semibold).foregroundStyle(Palette.textDim)
        ScrollView {
          VStack(alignment: .leading, spacing: 5) {
            ForEach(agenda.dayEvents) { event in
              HStack(spacing: 7) {
                Circle().fill(event.color.map(Color.init(nsColor:)) ?? Palette.accent).frame(width: 7, height: 7)
                Text(event.allDay ? "all-day" : event.start.formatted(date: .omitted, time: .shortened))
                  .islandFont(9.5).monospacedDigit().foregroundStyle(Palette.textDim).frame(width: 50, alignment: .leading)
                Text(event.title).islandFont(10.5, weight: .medium).foregroundStyle(Palette.text).lineLimit(1)
                Spacer(minLength: 2)
                if event.service != nil {
                  CircleKey(symbol: "video.fill", on: true, tint: QuickPalette.meeting, size: 20, label: "Join") { agenda.join(event) }
                }
              }
              .help(AgendaText.when(event, now: now))
            }
            if Calendar.current.isDateInToday(agenda.selected) {
              ForEach(agenda.reminders) { reminder in
                CheckRow(text: reminder.title, detail: reminder.due.map { $0.formatted(date: .omitted, time: .shortened) }, done: false, tint: reminder.color.map(Color.init(nsColor:))) {
                  agenda.complete(reminder)
                } remove: { nil }
              }
            }
            if !agenda.todos.items.isEmpty {
              Rectangle().fill(.white.opacity(0.06)).frame(height: 1).padding(.vertical, 2)
            }
            ForEach(agenda.todos.sorted) { item in
              CheckRow(text: item.text, detail: nil, done: item.done, tint: nil) { agenda.toggleTodo(item.id) } remove: {
                { agenda.removeTodo(item.id) }
              }
            }
          }
        }
        .frame(maxHeight: 150)
        .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 6) {
          HubField(model: model, placeholder: "New to-do", text: Binding(get: { draft.wrappedValue }, set: { draft.wrappedValue = $0 })) {
            agenda.addTodo(draft.wrappedValue)
            draft.wrappedValue = ""
          }
          if agenda.todos.items.contains(where: \.done) {
            CircleKey(symbol: "checkmark", size: 22, label: "Clear done") { agenda.clearDoneTodos() }
          }
        }
      }
    }
    .onAppear { agenda.refresh() }
  }
}

/// A wall-calendar month: today filled, the picked day ringed, busy days dotted.
private struct MonthView: View {
  let agenda: AgendaService
  let now: Date

  var body: some View {
    let days = MonthGrid.days(of: agenda.month)
    let columns = Array(repeating: GridItem(.fixed(24), spacing: 4), count: 7)
    VStack(spacing: 4) {
      HStack(spacing: 4) {
        Text(agenda.month, format: .dateTime.month(.wide).year())
          .islandFont(11, weight: .semibold).foregroundStyle(Palette.text)
        Spacer()
        CircleKey(symbol: "chevron.left", size: 20, label: "Previous month") { agenda.showMonth(-1) }
        CircleKey(symbol: "circle.fill", size: 20, label: "Today") { agenda.select(now) }
        CircleKey(symbol: "chevron.right", size: 20, label: "Next month") { agenda.showMonth(1) }
      }
      LazyVGrid(columns: columns, spacing: 2) {
        ForEach(Array(MonthGrid.weekdaySymbols().enumerated()), id: \.offset) { _, symbol in
          Text(symbol).islandFont(8.5, weight: .semibold).foregroundStyle(Palette.textDim)
        }
        ForEach(Array(days.enumerated()), id: \.offset) { _, day in
          if let day {
            DayCell(agenda: agenda, day: day, now: now)
          } else {
            Color.clear.frame(width: 24, height: 26)
          }
        }
      }
    }
  }
}

private struct DayCell: View {
  let agenda: AgendaService
  let day: Date
  let now: Date

  var body: some View {
    let calendar = Calendar.current
    let today = calendar.isDate(day, inSameDayAs: now)
    let picked = calendar.isDate(day, inSameDayAs: agenda.selected)
    let colors = agenda.busyDays[AgentStats.dayKey(day)]
    Button { agenda.select(day) } label: {
      VStack(spacing: 1) {
        Text("\(calendar.component(.day, from: day))")
          .islandFont(10, weight: today || picked ? .bold : .regular)
          .monospacedDigit()
          .foregroundStyle(today ? .white : Palette.text)
          .frame(width: 20, height: 20)
          .background(Circle().fill(today ? Palette.failed : .clear))
          .overlay(Circle().strokeBorder(picked && !today ? Palette.accent : .clear, lineWidth: 1.2))
        HStack(spacing: 1.5) {
          ForEach(Array((colors ?? []).prefix(3).enumerated()), id: \.offset) { _, color in
            Circle().fill(Color(nsColor: color)).frame(width: 3, height: 3)
          }
          if colors?.isEmpty == true { Circle().fill(Palette.textDim).frame(width: 3, height: 3) }
        }
        .frame(height: 3)
      }
      .frame(width: 24, height: 26)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

private struct Section_<Content: View>: View {
  let title: String
  let action: (String, () -> Void)?
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title.uppercased()).islandFont(9, weight: .semibold).foregroundStyle(Palette.textDim).kerning(0.6)
        Spacer()
        if let action { TextKey(title: action.0, tint: Palette.textDim, action: action.1) }
      }
      content
    }
  }
}

private struct CheckRow: View {
  let text: String
  let detail: String?
  let done: Bool
  let tint: Color?
  let toggle: () -> Void
  let remove: () -> (() -> Void)?

  var body: some View {
    Hovering { hovered in
      HStack(spacing: 7) {
        Button(action: toggle) {
          Image(systemName: done ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 13))
            .foregroundStyle(done ? Palette.done : tint ?? Palette.textDim)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(done ? "Mark not done" : "Mark done")
        Text(text).islandFont(11).foregroundStyle(done ? Palette.textDim : Palette.text).strikethrough(done).lineLimit(2)
        Spacer(minLength: 4)
        if let detail { Text(detail).islandFont(9.5).foregroundStyle(Palette.textDim) }
        if hovered, let remove = remove() { MiniKey(symbol: "xmark", label: "Delete", action: remove) }
      }
      .padding(.vertical, 2)
    }
  }
}

// MARK: - Timers

private struct TimersTab: View {
  let model: IslandModel
  let now: Date
  private let custom = State(initialValue: "")

  var body: some View {
    let timers = model.timers
    SplitPane(leftWidth: 150) {
      // Left: the running timer, big and round.
      if let timer = timers.featured {
        VStack(spacing: 8) {
          BigTimer(timer: timer, now: now, plan: timers.plan)
          HStack(spacing: 8) {
            CircleKey(symbol: "plus", size: 26, label: "Add a minute") { timers.extend(timer.id, minutes: 1) }
            CircleKey(symbol: timer.isPaused ? "play.fill" : "pause.fill", on: true, tint: QuickPalette.timer(timer), size: 30, label: timer.isPaused ? "Resume" : "Pause") {
              timers.togglePause(timer.id)
            }
            CircleKey(symbol: timer.kind == .pomodoro ? "forward.end.fill" : "xmark", size: 26, label: timer.kind == .pomodoro ? "Next phase" : "Stop") {
              if timer.kind == .pomodoro { timers.skip(timer.id) } else { timers.cancel(timer.id) }
            }
          }
          if timers.timers.count > 1 {
            Text("+\(timers.timers.count - 1) more").islandFont(9).foregroundStyle(Palette.textDim)
          }
        }
        .frame(maxWidth: .infinity)
      } else {
        Image(systemName: "timer").font(.system(size: 30, weight: .light)).foregroundStyle(Palette.textDim)
          .frame(maxWidth: .infinity, minHeight: 110)
      }
    } right: {
      // Right: start one.
      VStack(spacing: 10) {
        Grid(horizontalSpacing: 12, verticalSpacing: 10) {
          GridRow {
            preset(1)
            preset(5)
            preset(10)
          }
          GridRow {
            preset(15)
            preset(30)
            CircleKey(symbol: "leaf.fill", caption: "Pomodoro", on: timers.pomodoro != nil, tint: QuickPalette.focus, size: 38, label: "Pomodoro: 25 / 5") {
              timers.startPomodoro()
            }
          }
        }
        HubField(model: model, placeholder: "Minutes", text: Binding(get: { custom.wrappedValue }, set: { custom.wrappedValue = $0 }), width: 110) {
          let parts = custom.wrappedValue.split(separator: " ", maxSplits: 1).map(String.init)
          if let minutes = parts.first.flatMap(Double.init), minutes > 0 {
            timers.startCountdown(minutes: minutes, label: parts.count > 1 ? parts[1] : "")
            custom.wrappedValue = ""
          }
        }
      }
      .frame(maxWidth: .infinity)
    }
  }

  private func preset(_ minutes: Int) -> some View {
    Button { model.timers.startCountdown(minutes: Double(minutes)) } label: {
      VStack(spacing: -1) {
        Text("\(minutes)").islandFont(13, weight: .semibold).monospacedDigit()
        Text("min").islandFont(7.5).foregroundStyle(Palette.textDim)
      }
      .foregroundStyle(Palette.text)
      .frame(width: 38, height: 38)
      .background(Circle().fill(.white.opacity(0.08)))
      .overlay(Circle().strokeBorder(.white.opacity(0.06)))
      .contentShape(Circle())
    }
    .buttonStyle(PressScale())
    .help("\(minutes)-minute timer")
  }
}

// MARK: - Widgets

private struct WidgetsTab: View {
  let model: IslandModel

  var body: some View {
    SplitPane(leftWidth: 170) {
      // Left: markets.
      VStack(spacing: 8) {
        if model.settings.stocks {
          StocksList(model: model)
        } else {
          CircleKey(symbol: "chart.line.uptrend.xyaxis", caption: "Stocks", size: 34, label: "Turn on stocks") { model.changeSettings { $0.stocks = true } }
        }
      }
      .frame(maxWidth: .infinity)
    } right: {
      // Right: the converter.
      ConverterView(model: model)
    }
  }
}

private struct StocksList: View {
  let model: IslandModel

  var body: some View {
    let stocks = model.stocks
    VStack(spacing: 2) {
      if stocks.quotes.isEmpty {
        Image(systemName: stocks.failed ? "wifi.exclamationmark" : "chart.line.uptrend.xyaxis")
          .font(.system(size: 14)).foregroundStyle(Palette.textDim).frame(maxWidth: .infinity)
      }
      ForEach(stocks.quotes) { quote in
        let up = quote.change >= 0
        HStack(spacing: 6) {
          Text(quote.symbol).islandFont(10, weight: .semibold).foregroundStyle(Palette.text).frame(width: 46, alignment: .leading)
          Sparkline(values: quote.series, color: up ? Palette.done : Palette.failed).frame(width: 44, height: 12)
          Spacer(minLength: 2)
          Text((up ? "+" : "") + quote.changePercent.formatted(.number.precision(.fractionLength(1))) + "%")
            .islandFont(9.5, weight: .semibold).monospacedDigit()
            .foregroundStyle(up ? Palette.done : Palette.failed)
        }
        .help("\(quote.symbol) \(quote.price.formatted(.number.precision(.fractionLength(2)))) \(quote.currency)")
      }
    }
    .onAppear { stocks.refreshIfStale(StockQuote.symbols(model.settings.stockSymbols)) }
  }
}

private struct Sparkline: View {
  let values: [Double]
  let color: Color

  var body: some View {
    GeometryReader { proxy in
      if let low = values.min(), let high = values.max(), values.count > 1 {
        let span = max(high - low, 0.0001)
        Path { path in
          for (index, value) in values.enumerated() {
            let point = CGPoint(
              x: proxy.size.width * CGFloat(index) / CGFloat(values.count - 1),
              y: proxy.size.height * (1 - CGFloat((value - low) / span))
            )
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
          }
        }
        .stroke(color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
      }
    }
  }
}

// MARK: - Teleprompter

private struct PrompterTab: View {
  let model: IslandModel

  var body: some View {
    let prompter = model.prompter
    SplitPane(leftWidth: 74) {
      PrompterKeys(prompter: prompter)
    } right: {
      if prompter.editing {
        PrompterEditor(model: model)
      } else {
        PrompterScroll(prompter: prompter, paused: model.isPaused)
      }
    }
  }
}

/// The prompter's controls as round keys, two to a row.
struct PrompterKeys: View {
  let prompter: TeleprompterState

  var body: some View {
    Grid(horizontalSpacing: 8, verticalSpacing: 8) {
      GridRow {
        CircleKey(symbol: prompter.playing ? "pause.fill" : "play.fill", on: true, tint: Palette.accent, size: 30, label: prompter.playing ? "Pause" : "Play") {
          prompter.togglePlay()
        }
        CircleKey(symbol: "backward.end.fill", size: 30, label: "Back to the start") { prompter.restart() }
      }
      GridRow {
        CircleKey(symbol: "tortoise.fill", size: 30, label: "Slower (\(Int(prompter.speed)))") { prompter.speed = max(Prompter.speeds.lowerBound, prompter.speed - 8) }
        CircleKey(symbol: "hare.fill", size: 30, label: "Faster (\(Int(prompter.speed)))") { prompter.speed = min(Prompter.speeds.upperBound, prompter.speed + 8) }
      }
      GridRow {
        CircleKey(symbol: "textformat.size.smaller", size: 30, label: "Smaller text") { prompter.fontSize = max(Prompter.fontSizes.lowerBound, prompter.fontSize - 2) }
        CircleKey(symbol: "textformat.size.larger", size: 30, label: "Larger text") { prompter.fontSize = min(Prompter.fontSizes.upperBound, prompter.fontSize + 2) }
      }
      GridRow {
        CircleKey(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", on: prompter.mirrored, size: 30, label: "Mirror") { prompter.mirrored.toggle() }
        CircleKey(symbol: prompter.editing ? "checkmark" : "text.cursor", on: prompter.editing, size: 30, label: prompter.editing ? "Done" : "Edit the script") {
          if !prompter.playing { prompter.editing.toggle() }
        }
      }
    }
  }
}

private struct PrompterEditor: View {
  let model: IslandModel
  @FocusState private var focused: Bool

  var body: some View {
    let prompter = model.prompter
    TextEditor(text: Binding(get: { prompter.script }, set: { prompter.script = $0 }))
      .font(.system(size: 12))
      .scrollContentBackground(.hidden)
      .foregroundStyle(Palette.text)
      .focused($focused)
      .padding(6)
      .frame(height: TeleprompterState.viewport)
      .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.06)))
      .onChange(of: focused) { _, now in model.hubTyping = now }
      .onAppear { focused = true }
      .onDisappear { model.hubTyping = false }
  }
}

/// The script scrolling up, faded at both ends.
struct PrompterScroll: View {
  let prompter: TeleprompterState
  let paused: Bool

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 60, paused: !prompter.playing || paused)) { timeline in
      Text(prompter.script)
        .font(.system(size: prompter.fontSize, weight: .semibold))
        .foregroundStyle(.white)
        .lineSpacing(prompter.fontSize * 0.25)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: Double.self) { $0.size.height } action: { prompter.contentHeight = $0 }
        .padding(.top, TeleprompterState.viewport * 0.35)
        .offset(y: -prompter.offset(at: timeline.date))
        .scaleEffect(x: prompter.mirrored ? -1 : 1, y: 1)
    }
    .frame(height: TeleprompterState.viewport, alignment: .top)
    .clipped()
    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18), .init(color: .black, location: 0.8), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
    .contentShape(Rectangle())
    .onTapGesture { prompter.togglePlay() }
    .accessibilityLabel("Teleprompter script")
  }
}

/// While the script rolls, it's all the island shows, right under the camera.
struct PrompterStage: View {
  let model: IslandModel

  var body: some View {
    SplitPane(leftWidth: 74) {
      PrompterKeys(prompter: model.prompter)
    } right: {
      PrompterScroll(prompter: model.prompter, paused: model.isPaused)
    }
    .frame(width: 460)
    .padding(.init(top: 4, leading: 12, bottom: 10, trailing: 12))
  }
}

/// Pick a family, type a number, choose the units; swap with one click.
/// Typing a whole phrase ("72 f to c") still works.
private struct ConverterView: View {
  let model: IslandModel
  private let kindId = State(initialValue: UserDefaults.standard.string(forKey: "converterKind") ?? "length")
  private let from = State(initialValue: "")
  private let to = State(initialValue: "")
  private let value = State(initialValue: "1")

  private var kind: IslandCore.UnitConverter.Kind {
    UnitConverter.kinds.first { $0.id == kindId.wrappedValue } ?? UnitConverter.kinds[0]
  }

  var body: some View {
    let kind = kind
    let fromUnit = kind.units.contains(from.wrappedValue) ? from.wrappedValue : kind.from
    let toUnit = kind.units.contains(to.wrappedValue) ? to.wrappedValue : kind.to
    let text = value.wrappedValue.replacingOccurrences(of: ",", with: ".")
    let result: (value: Double, unit: String)? = if let number = Double(text) {
      UnitConverter.convert(number, from: fromUnit, to: toUnit).map { ($0, toUnit) }
    } else {
      UnitConverter.convert(value.wrappedValue).map { ($0.value, $0.to) }
    }
    VStack(spacing: 8) {
      // The families, as small round keys.
      Grid(horizontalSpacing: 5, verticalSpacing: 5) {
        GridRow { ForEach(UnitConverter.kinds.prefix(6)) { family($0) } }
        GridRow { ForEach(UnitConverter.kinds.dropFirst(6)) { family($0) } }
      }
      // The number, and the two units either side of a swap.
      HStack(spacing: 4) {
        HubField(model: model, placeholder: "1", text: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0 }), width: 62, centered: false)
        unitMenu(kind.units, selected: fromUnit) { from.wrappedValue = $0 }
        CircleKey(symbol: "arrow.left.arrow.right", size: 20, label: "Swap") {
          from.wrappedValue = toUnit
          to.wrappedValue = fromUnit
        }
        unitMenu(kind.units, selected: toUnit) { to.wrappedValue = $0 }
      }
      HStack(spacing: 6) {
        Text(result.map { "\(UnitConverter.format($0.value)) \($0.unit)" } ?? "—")
          .islandFont(18, weight: .semibold).monospacedDigit()
          .foregroundStyle(result == nil ? Palette.textDim : Palette.text)
          .lineLimit(1).minimumScaleFactor(0.6)
          .contentTransition(.numericText())
          .textSelection(.enabled)
        if let result {
          CircleKey(symbol: "doc.on.doc", size: 20, label: "Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(UnitConverter.format(result.value), forType: .string)
          }
        }
      }
    }
    .frame(maxWidth: .infinity)
    .animation(.easeOut(duration: 0.12), value: result?.value)
  }

  private func family(_ kind: IslandCore.UnitConverter.Kind) -> some View {
    CircleKey(symbol: kind.symbol, on: kind.id == kindId.wrappedValue, size: 22, label: kind.name) {
      kindId.wrappedValue = kind.id
      from.wrappedValue = kind.from
      to.wrappedValue = kind.to
      UserDefaults.standard.set(kind.id, forKey: "converterKind")
    }
  }

  private func unitMenu(_ units: [String], selected: String, pick: @escaping (String) -> Void) -> some View {
    Menu {
      ForEach(units, id: \.self) { unit in
        Button { pick(unit) } label: {
          if unit == selected { Label(unit, systemImage: "checkmark") } else { Text(unit) }
        }
      }
    } label: {
      Text(selected).islandFont(11, weight: .semibold).foregroundStyle(Palette.text)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .padding(.init(top: 3, leading: 8, bottom: 3, trailing: 8))
    .background(Capsule().fill(.white.opacity(0.08)))
  }
}

/// The Timers page's big round clock: a glowing ring that empties as it runs,
/// nothing drawn over the numbers, and the Pomodoro rounds as dots beneath.
private struct BigTimer: View {
  let timer: IslandTimer
  let now: Date
  let plan: PomodoroPlan

  var body: some View {
    let tint = QuickPalette.timer(timer)
    let left = 1 - timer.progress(at: now)
    VStack(spacing: 6) {
      ZStack {
        Circle().stroke(.white.opacity(0.07), lineWidth: 6)
        Circle()
          .trim(from: 0, to: left)
          .stroke(
            AngularGradient(colors: [tint.opacity(0.55), tint], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * left)),
            style: StrokeStyle(lineWidth: 6, lineCap: .round)
          )
          .rotationEffect(.degrees(-90))
          .shadow(color: tint.opacity(timer.isPaused ? 0 : 0.45), radius: 6)
          .animation(.linear(duration: 1), value: left)
        VStack(spacing: 1) {
          Text(Clock.countdown(timer.remaining(at: now)))
            .islandFont(20, weight: .semibold)
            .monospacedDigit()
            .foregroundStyle(timer.isPaused ? Palette.textDim : .white)
            .contentTransition(.numericText(countsDown: true))
          Text(timer.isPaused ? "Paused" : timer.kind == .pomodoro ? timer.phase.label : (timer.label.isEmpty ? "Timer" : timer.label))
            .islandFont(9, weight: .medium)
            .foregroundStyle(timer.isPaused ? Palette.textDim : tint)
            .lineLimit(1)
        }
        .frame(width: 76)
      }
      .frame(width: 96, height: 96)
      if timer.kind == .pomodoro {
        // Where you are in the cycle: done rounds filled, this one ringed.
        let done = (timer.round - 1) % plan.roundsBeforeLongBreak + (timer.phase == .focus ? 0 : 1)
        HStack(spacing: 5) {
          ForEach(0..<plan.roundsBeforeLongBreak, id: \.self) { index in
            Circle()
              .fill(index < done ? QuickPalette.focus : .clear)
              .overlay(Circle().strokeBorder(QuickPalette.focus.opacity(index < done ? 0 : 0.5), lineWidth: 1))
              .frame(width: 6, height: 6)
          }
        }
        .help("Round \(timer.round)")
      }
    }
  }
}

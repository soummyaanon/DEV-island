import AppKit
import IslandCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// The Settings window's own state: which section is open, and a few flags.
@Observable
final class SettingsWindowState {
  enum Section: String, CaseIterable, Identifiable {
    case integrations, intelligence, appearance, sounds, weather, live, accessibility, general, updates

    var id: String { rawValue }

    var label: String {
      switch self {
      case .integrations: "Integrations"
      case .intelligence: "Intelligence"
      case .appearance: "Appearance"
      case .sounds: "Sounds"
      case .weather: "Weather"
      case .live: "Live activities"
      case .accessibility: "Accessibility"
      case .general: "General"
      case .updates: "Updates"
      }
    }

    var symbol: String {
      switch self {
      case .integrations: "square.stack.3d.up.fill"
      case .intelligence: "sparkles"
      case .appearance: "paintpalette.fill"
      case .sounds: "music.note"
      case .weather: "cloud.sun.fill"
      case .live: "waveform.path.ecg"
      case .accessibility: "accessibility"
      case .general: "slider.horizontal.3"
      case .updates: "arrow.down.circle.fill"
      }
    }

    var tile: UInt32 {
      switch self {
      case .integrations: 0xFF8C42
      case .intelligence: 0xA77BFF
      case .appearance: 0x3D8BFF
      case .sounds: 0xFF5A7A
      case .weather: 0x35B8FF
      case .live: 0x2FCB7A
      case .accessibility: 0x3D6BFF
      case .general: 0x8E8E93
      case .updates: 0xFFB020
      }
    }

    /// What lives here, in plain words.
    var blurb: String {
      switch self {
      case .integrations: "Which agents the island watches."
      case .intelligence: "The on-device assistant, its voice, and its glow."
      case .appearance: "How the island looks and opens."
      case .sounds: "What you hear when agents finish, ask, or need you."
      case .weather: "A small live scene when nothing is running."
      case .live: "Battery, Focus and resource moments in the wings."
      case .accessibility: "Text size, keyboard focus and VoiceOver."
      case .general: "Login, menu bar and the app itself."
      case .updates: "Stay on the latest release."
      }
    }
  }

  var section = Section.integrations
  var checking = false
  var installing = false
  var copied: String?
  var weatherLocation = ""
}

/// Everything the Settings window can change, persisted to the shared
/// `settings.json` (1.x's settings.tsx, section for section).
struct SettingsView: View {
  let model: IslandModel
  let state: SettingsWindowState
  let sounds: SoundPlayer
  let applyIntegration: (AgentKind, Bool) -> Void

  var body: some View {
    HStack(spacing: 0) {
      sidebar
        .frame(width: 210)
        .background(.regularMaterial)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          header
          detail
        }
        .padding(.init(top: 28, leading: 28, bottom: 28, trailing: 28))
        .frame(maxWidth: 620, alignment: .leading)
        .modifier(PageIn())
        .id(state.section)
      }
      .frame(maxWidth: .infinity)
    }
    .frame(minWidth: 760, minHeight: 520)
  }

  // MARK: Chrome

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        // A tiny island: the black pill with one of the crew in its wing.
        Capsule().fill(.black)
          .frame(width: 34, height: 16)
          .overlay(alignment: .trailing) {
            BotAvatar(look: BotLook.crew[0].look, state: .idle, size: 12, seed: 0.12, paused: true, style: BotPose.Style(jumpEvery: 0), interactive: false).padding(.trailing, 4)
          }
        Text("Agent Island").font(.system(size: 13, weight: .semibold))
      }
      .padding(.init(top: 40, leading: 12, bottom: 14, trailing: 12))
      ForEach(SettingsWindowState.Section.allCases) { section in
        Button { state.section = section } label: {
          HStack(spacing: 9) {
            Tile(symbol: section.symbol, color: section.tile, size: 20)
            Text(section.label).font(.system(size: 13))
            Spacer()
            if section == .updates && model.updates.available != nil {
              Circle().fill(Color(hex: 0xFF5F56)).frame(width: 7, height: 7)
            }
          }
          .padding(.init(top: 5, leading: 8, bottom: 5, trailing: 8))
          .background(RoundedRectangle(cornerRadius: 7).fill(state.section == section ? Color.accentColor.opacity(0.22) : .clear))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.12), value: state.section)
      }
      Spacer()
      VStack(alignment: .leading, spacing: 2) {
        Text("v\(UpdateChecker.currentVersion)")
        Text("everything stays on this Mac")
      }
      .font(.system(size: 10.5))
      .foregroundStyle(.secondary)
      .padding(16)
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Tile(symbol: state.section.symbol, color: state.section.tile, size: 38)
      VStack(alignment: .leading, spacing: 2) {
        Text(state.section.label).font(.system(size: 20, weight: .bold))
        Text(state.section.blurb).font(.system(size: 12.5)).foregroundStyle(.secondary)
      }
    }
    .padding(.bottom, 6)
  }

  @ViewBuilder private var detail: some View {
    switch state.section {
    case .integrations: integrations
    case .intelligence: intelligence
    case .appearance: appearance
    case .sounds: soundsSection
    case .weather: weather
    case .live: live
    case .accessibility: accessibility
    case .general: general
    case .updates: updates
    }
  }

  private func binding(_ key: WritableKeyPath<IslandSettings, Bool>) -> Binding<Bool> {
    Binding(get: { model.settings[keyPath: key] }, set: { value in model.changeSettings { $0[keyPath: key] = value } })
  }

  private func pick<V>(_ key: WritableKeyPath<IslandSettings, V>) -> Binding<V> {
    Binding(get: { model.settings[keyPath: key] }, set: { value in model.changeSettings { $0[keyPath: key] = value } })
  }

  // MARK: Sections

  private var integrations: some View {
    Group_ {
      ForEach(AgentKind.allCases, id: \.self) { agent in
        SettingRow(
          title: agent.displayName,
          detail: Self.integrationDetail(agent),
          isOn: Binding(get: { model.settings.agents.contains(agent) }, set: { on in
            model.changeSettings { if on { $0.agents.insert(agent) } else { $0.agents.remove(agent) } }
            applyIntegration(agent, on)
          })
        ) {
          AgentMarkView(agent: agent, size: 16, color: .primary)
        }
      }
    }
  }

  private static func integrationDetail(_ agent: AgentKind) -> String {
    switch agent {
    case .claudeCode: "Lifecycle hooks in ~/.claude/settings.json — removed cleanly when off."
    case .codex: "Read-only tail of local session logs. Nothing to install."
    case .cursor: "Bridge in ~/.cursor/hooks.json — removed cleanly when off."
    }
  }

  private var intelligence: some View {
    VStack(alignment: .leading, spacing: 14) {
      let status = assistantStatus
      HStack(spacing: 8) {
        Circle().fill(status.ok ? Color(hex: 0x2FCB7A) : Color(hex: 0xFFB020)).frame(width: 8, height: 8)
        Text(status.text).font(.system(size: 12))
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
      Group_ {
        SettingRow(title: "Assistant", detail: "The Ask bar: the bots when the island is empty, ✦ while agents work.", isOn: binding(\.assistant))
        SettingRow(title: "Apple Intelligence", detail: "Use the on-device model for answers and multi-step actions. Off keeps simple commands only.", isOn: binding(\.assistantModel))
        SettingRow(title: "Edge glow", detail: "A soft silver pulse inside the island's edge while the assistant is open.", isOn: binding(\.edgeGlow))
        SettingRow(title: "Say hello", detail: "A greeting from the bots when the island starts and when you come back to your Mac, written on-device.", isOn: binding(\.greeting))
      }
      SubHeading("Voice")
      Group_ {
        SettingRow(title: "Voice mode", detail: "A mic in the Ask bar. Speech is transcribed on this Mac; nothing is recorded.", isOn: binding(\.voice))
        SettingRow(title: "Speak answers", detail: "Read the answer aloud in Siri's voice when you asked by voice.", isOn: binding(\.speakReplies))
      }
    }
  }

  private var assistantStatus: (ok: Bool, text: String) {
    switch model.assistant.support {
    case .available: return (true, "Apple Intelligence is ready. Answers and actions run on this Mac.")
    case let .basic(reason):
      let why: [String: String] = [
        "off": model.settings.assistantModel ? "Starting Apple Intelligence…" : "Answers are off. Commands still work.",
        "not-enabled": "Turn on Apple Intelligence in System Settings for answers. Commands work now.",
        "model-not-ready": "Apple Intelligence is still downloading its model. Commands work now.",
        "device-not-eligible": "This Mac can't run Apple Intelligence. Commands (open, search, timers, volume, Shortcuts) work.",
        "os": "Answers need macOS 26. Commands (open, search, timers, volume, Shortcuts) work now.",
        "sdk": "This build has no Apple Intelligence. Commands work.",
      ]
      return (false, why[reason] ?? "Commands work; answers need Apple Intelligence.")
    }
  }

  private var appearance: some View {
    Group_ {
      SettingRow(
        title: "Liquid Glass panel",
        detail: NSClassFromString("NSGlassEffectView") != nil
          ? "Off: the island is one solid deep-black body. On: the panel below the notch becomes real macOS glass that refracts your wallpaper (the band stays black). Reduce transparency and Increase contrast switch it off automatically."
          : "Off: the island is one solid deep-black body. On: real see-through blur beneath the panel. macOS 26 adds Liquid Glass refraction to this.",
        isOn: binding(\.glass)
      )
      ChoiceRow(
        title: "Open with",
        detail: model.settings.openWith == .swipe
          ? "Two-finger swipe down (or a click) opens the island; grazing the top of the screen doesn't. Swipe up closes it."
          : "Hovering the notch opens the island. Swipe up closes it either way."
      ) {
        Picker("Open the island with", selection: pick(\.openWith)) {
          Text("Hover").tag(IslandSettings.OpenWith.hover)
          Text("Swipe").tag(IslandSettings.OpenWith.swipe)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
      }
      ChoiceRow(
        title: "Sessions",
        detail: model.settings.sessionView == .compact
          ? "Each session is a small avatar bubble; hover one for what it's doing, click to jump."
          : "Full rows: project, activity, model, host app and CPU/memory for every session."
      ) {
        Picker("Show sessions as", selection: pick(\.sessionView)) {
          Text("Compact").tag(IslandSettings.SessionView.compact)
          Text("Detailed").tag(IslandSettings.SessionView.detailed)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
      }
    }
  }

  private var soundsSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      Group_ {
        SettingRow(title: "Sound effects", detail: "Chimes when agents finish, ask, need you — and when you allow.", isOn: binding(\.sounds))
      }
      SubHeading("Theme")
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
        ForEach(SoundTheme.allCases, id: \.self) { theme in
          let on = model.settings.soundTheme == theme
          Button {
            // A theme switch is a fresh start: per-event overrides reset.
            model.changeSettings {
              $0.soundTheme = theme
              $0.soundOverrides = [:]
            }
            sounds.preview(.success, theme: theme)
          } label: {
            HStack(alignment: .top) {
              VStack(alignment: .leading, spacing: 2) {
                Text(theme.label).font(.system(size: 12.5, weight: .semibold))
                Text(theme.blurb).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.leading)
              }
              Spacer(minLength: 4)
              Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 9).fill(on ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(on ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(on ? .isSelected : [])
        }
      }
      SubHeading("Per event")
      Group_ {
        ForEach(SoundEvent.allCases, id: \.self) { event in
          let custom = model.settings.customSounds[event]
          HStack(spacing: 8) {
            Text(event.label).font(.system(size: 13, weight: .medium))
            Spacer()
            Button {
              if let custom { sounds.playFile(URL(filePath: custom), volume: 0.6) } else { sounds.preview(event, theme: model.settings.theme(for: event)) }
            } label: { Image(systemName: "play.fill").font(.system(size: 10)) }
              .buttonStyle(.borderless)
              .help("Preview")
            if custom != nil {
              Text(model.settings.customSoundNames[event] ?? "Custom")
                .font(.system(size: 11))
                .padding(.init(top: 2, leading: 7, bottom: 2, trailing: 7))
                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                .help("Playing your imported sound")
              Button("✕") { clearSound(event) }.buttonStyle(.borderless).help("Remove custom sound")
            } else {
              Picker("Sound for \(event.label)", selection: Binding(
                get: { model.settings.soundOverrides[event] },
                set: { value in model.changeSettings { $0.soundOverrides[event] = value } }
              )) {
                Text("Theme default").tag(SoundTheme?.none)
                ForEach(SoundTheme.allCases, id: \.self) { Text($0.label).tag(SoundTheme?.some($0)) }
              }
              .labelsHidden().fixedSize()
            }
            Button(custom != nil ? "Replace" : "Import") { importSound(event) }
              .help("Import your own audio file (mp3, wav, m4a…)")
          }
          .padding(.vertical, 6)
        }
      }
    }
  }

  private var weather: some View {
    Group_ {
      SettingRow(title: "Local weather", detail: "Animates in the island whenever no agent is working. Off by default.", isOn: binding(\.weather))
      ChoiceRow(title: "Location", detail: "Blank uses your time zone — no permission needed, accurate to the nearest big city. Enter “latitude, longitude” to be exact.") {
        TextField("22.57, 88.36", text: Binding(get: { state.weatherLocation }, set: { state.weatherLocation = $0 }))
          .frame(width: 150)
          // On commit, not per keystroke: every change is a network request.
          .onSubmit { model.changeSettings { $0.weatherLocation = state.weatherLocation } }
          .onAppear { state.weatherLocation = model.settings.weatherLocation }
          .accessibilityLabel("Weather location as latitude, longitude")
      }
      ChoiceRow(title: "Units", detail: "Automatic follows your Mac’s region.") {
        Picker("Units", selection: pick(\.weatherUnits)) {
          Text("Automatic").tag(IslandSettings.TemperatureUnit.auto)
          Text("Celsius").tag(IslandSettings.TemperatureUnit.c)
          Text("Fahrenheit").tag(IslandSettings.TemperatureUnit.f)
        }
        .labelsHidden().fixedSize()
      }
      Note(model.settings.weather
        ? "Weather comes from open-meteo.com — no account, no API key. Your coordinates are rounded to about a kilometre before the request, and nothing else about you or your sessions is sent." + (model.weather.reading.map { " Currently using \(Self.sourceWords($0.locationSource))." } ?? "")
        : "While this is off, Agent Island makes no weather requests at all. Turning it on adds one request to open-meteo.com every 15 minutes.")
    }
  }

  private static func sourceWords(_ source: Coordinates.Source) -> String {
    switch source {
    case .manual: "the location you entered"
    case .device: "your device location"
    case .timezone: "your time zone (approximate)"
    }
  }

  private var live: some View {
    Group_ {
      SettingRow(title: "Battery", detail: "A moment in the notch when the charger comes or goes, and a small red battery under 20%. Nothing on desktop Macs.", isOn: binding(\.battery))
      SettingRow(title: "Agent resource meter", detail: "CPU and memory per session, summed over the agent's whole process tree. Sampled only while the island is open.", isOn: binding(\.procStats))
      SettingRow(title: "Quiet during Focus", detail: "Mutes sounds and notification taps while a Focus is on. Approvals and questions still open the island.", isOn: binding(\.respectFocus))
      ChoiceRow(
        title: "Focus status",
        detail: model.focus.active
          ? "On — \(model.focus.name ?? "Focus"). If it stayed on by mistake, click the ☾ chip in the island."
          : "Off, or no signal yet. macOS keeps Focus state private, so a Shortcuts automation tells Agent Island instead — two links, set up once."
      ) {
        Button("Open Shortcuts") { NSWorkspace.shared.open(URL(string: "shortcuts://")!) }
      }
      Note("In Shortcuts: Automation → New → Focus → choose the Focus → When turning on → Run immediately → add the action Open URLs with the first link below. Repeat with When turning off and the second link. One pair per Focus you use.")
      LinkRow(label: "Focus turned on", url: DeepLink.focusOn, state: state)
      LinkRow(label: "Focus turned off", url: DeepLink.focusOff, state: state)
    }
  }

  private var accessibility: some View {
    Group_ {
      SettingRow(title: "Haptic feedback", detail: "A distinct tap for finishing, failing, asking, and deciding. Force Touch trackpads only.", isOn: binding(\.haptics))
      ChoiceRow(title: "Text size", detail: "Scales everything in the island. macOS has no system setting we can read.") {
        Picker("Text size", selection: pick(\.textSize)) {
          Text("Default").tag(IslandSettings.TextSize.standard)
          Text("Large").tag(IslandSettings.TextSize.large)
          Text("Larger").tag(IslandSettings.TextSize.larger)
        }
        .labelsHidden().fixedSize()
      }
      ChoiceRow(title: "Focus the island", detail: "The island never takes focus on its own, so VoiceOver can't reach it. This hands it focus; Escape gives it back.") {
        Text("⌃⌥⌘I")
          .font(.system(size: 12, weight: .medium, design: .rounded))
          .padding(.init(top: 3, leading: 8, bottom: 3, trailing: 8))
          .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.08)))
      }
      Note("Reduce motion, Increase contrast, and Reduce transparency are followed automatically from System Settings → Accessibility → Display.")
    }
  }

  private var general: some View {
    Group_ {
      let needsApproval = LoginItem.isAvailable && SMAppService.mainApp.status == .requiresApproval
      SettingRow(
        title: "Open at login",
        detail: needsApproval
          ? "Requested — macOS wants your approval first: System Settings → General → Login Items & Extensions."
          : "Start silently with your Mac — no Dock, no windows.",
        isOn: Binding(get: { LoginItem.isEnabled || needsApproval }, set: { LoginItem.isEnabled = $0 })
      )
      .disabled(!LoginItem.isAvailable)
      SettingRow(title: "Menu-bar icon", detail: "Optional 🏝 in the menu bar with a status count.", isOn: binding(\.tray))
      SettingRow(title: "Check for updates", detail: "One anonymous version check against GitHub Releases, hourly.", isOn: binding(\.updateCheck))
    }
  }

  private var updates: some View {
    Group_ {
      let version = model.updates.available
      ChoiceRow(
        title: version.map { "Update available — v\($0)" } ?? "Agent Island",
        detail: version != nil
          ? "You're on v\(UpdateChecker.currentVersion). Installing replaces the app and relaunches."
          : state.checking ? "Checking for updates…" : "You're on v\(UpdateChecker.currentVersion) — up to date."
      ) {
        if version != nil {
          Button(state.installing ? "Installing…" : "Install & Restart") {
            state.installing = true
            Task {
              // On success the app quits and relaunches.
              if !(await model.updates.install()) { state.installing = false }
            }
          }
          .disabled(state.installing)
          .buttonStyle(.borderedProminent)
        } else {
          Button(state.checking ? "Checking…" : "Check now") { checkNow() }.disabled(state.checking)
        }
      }
      if version != nil {
        Note("After updating, re-enable Agent Island in System Settings → Privacy & Security → Accessibility (ad-hoc builds lose the grant on replace).")
      }
    }
    .onAppear { checkNow() }
  }

  private func checkNow() {
    state.checking = true
    Task {
      await model.updates.check()
      state.checking = false
    }
  }

  // MARK: Sounds on disk

  /// Copies an audio file into the shared userData's sounds folder, one per event.
  private func importSound(_ event: SoundEvent) {
    let panel = NSOpenPanel()
    panel.title = "Choose a sound"
    panel.allowedContentTypes = ["mp3", "wav", "m4a", "aac", "ogg", "oga", "aif", "aiff", "flac"].compactMap { UTType(filenameExtension: $0) }
    guard panel.runModal() == .OK, let source = panel.url else { return }
    let folder = IslandSettings.userData.appending(path: "sounds")
    let destination = folder.appending(path: "\(event.rawValue).\(source.pathExtension.lowercased().isEmpty ? "mp3" : source.pathExtension.lowercased())")
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      // A new extension would orphan the old file.
      if let previous = model.settings.customSounds[event], previous != destination.path { try? FileManager.default.removeItem(atPath: previous) }
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.copyItem(at: source, to: destination)
    } catch {
      Log.app.error("sound import failed: \(error.localizedDescription, privacy: .public)")
      return
    }
    model.changeSettings {
      $0.customSounds[event] = destination.path
      $0.customSoundNames[event] = source.lastPathComponent
    }
  }

  private func clearSound(_ event: SoundEvent) {
    if let path = model.settings.customSounds[event] { try? FileManager.default.removeItem(atPath: path) }
    model.changeSettings {
      $0.customSounds[event] = nil
      $0.customSoundNames[event] = nil
    }
  }
}

// MARK: - Pieces

/// A rounded group of rows, like System Settings.
private struct Group_<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) { content }
      .padding(.horizontal, 14)
      .padding(.vertical, 4)
      .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07)))
  }
}

private struct SettingRow<Icon: View>: View {
  let title: String
  let detail: String
  let isOn: Binding<Bool>
  @ViewBuilder var icon: Icon

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      icon
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 13, weight: .medium))
        Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
      Toggle(title, isOn: isOn).toggleStyle(.switch).labelsHidden()
    }
    .padding(.vertical, 9)
  }
}

extension SettingRow where Icon == EmptyView {
  fileprivate init(title: String, detail: String, isOn: Binding<Bool>) {
    self.init(title: title, detail: detail, isOn: isOn) { EmptyView() }
  }
}

private struct ChoiceRow<Control: View>: View {
  let title: String
  let detail: String
  @ViewBuilder var control: Control

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 13, weight: .medium))
        Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 12)
      control
    }
    .padding(.vertical, 9)
  }
}

private struct Note: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
  }
}

private struct SubHeading: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text).font(.system(size: 13, weight: .semibold)).padding(.top, 6)
  }
}

/// One agent-island:// link with a copy button, for the Focus automation.
private struct LinkRow: View {
  let label: String
  let url: String
  let state: SettingsWindowState

  var body: some View {
    ChoiceRow(title: label, detail: url) {
      Button(state.copied == url ? "Copied" : "Copy") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        state.copied = url
        Task {
          try? await Task.sleep(for: .milliseconds(1200))
          if state.copied == url { state.copied = nil }
        }
      }
    }
  }
}

private struct Tile: View {
  let symbol: String
  let color: UInt32
  let size: CGFloat

  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.26)
      .fill(LinearGradient(colors: [Color(hex: color), Color(hex: color).opacity(0.8)], startPoint: .top, endPoint: .bottom))
      .frame(width: size, height: size)
      .overlay(Image(systemName: symbol).font(.system(size: size * 0.52, weight: .semibold)).foregroundStyle(.white))
  }
}

/// `s-page-in`: each section fades up 6px as it arrives; the old one just goes.
private struct PageIn: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let shown = State(initialValue: false)

  func body(content: Content) -> some View {
    let on = shown.wrappedValue || reduceMotion
    content
      .opacity(on ? 1 : 0)
      .offset(y: on ? 0 : 6)
      .animation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.24), value: on)
      .onAppear { shown.wrappedValue = true }
  }
}

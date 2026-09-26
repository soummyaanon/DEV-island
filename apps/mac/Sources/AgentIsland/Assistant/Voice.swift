import AppKit
import AVFoundation
import Speech

/// What listening reports.
enum VoiceEvent: Sendable {
  case listening(id: String)
  /// First use downloads the on-device speech model.
  case downloading(id: String)
  case partial(id: String, text: String)
  case final(id: String, text: String)
  case error(id: String, reason: String)
  /// A 0–1 loudness for the orb.
  case level(id: String, value: Double)
  /// A spoken reply finished.
  case spoken
}

/// Voice mode (moved in from the sidecar): hear a question, say the answer,
/// all on-device. A second and a half of quiet after speech, or `stop`, or 30
/// seconds ends the turn.
final class Voice {
  var onEvent: (VoiceEvent) -> Void = { _ in }
  private let speaker = Speaker()
  private var listener: AnyObject?

  init() {
    speaker.onDone = { [weak self] in self?.onEvent(.spoken) }
  }

  func speak(_ text: String) { speaker.say(text) }
  func stopSpeaking() { speaker.stop() }

  func start(id: String) {
    speaker.stop()
    stopListening(superseded: true)
    let send: @MainActor @Sendable (VoiceEvent) -> Void = { [weak self] event in
      if case .final = event { self?.listener = nil }
      if case .error = event { self?.listener = nil }
      self?.onEvent(event)
    }
    if #available(macOS 26.0, *) {
      let listener = Listener(id: id, send: send)
      self.listener = listener
      Task { await listener.start() }
    } else {
      let listener = LegacyListener(id: id, send: send)
      self.listener = listener
      listener.start()
    }
  }

  func stop(id: String) {
    if #available(macOS 26.0, *), let listener = listener as? Listener, listener.id == id { listener.stop() }
    if let listener = listener as? LegacyListener, listener.id == id { listener.stop() }
  }

  private func stopListening(superseded: Bool) {
    if #available(macOS 26.0, *), let listener = listener as? Listener { listener.fail("superseded") }
    if let listener = listener as? LegacyListener { listener.fail("superseded") }
    listener = nil
  }
}

/// Speaks like the user's Siri: reads Siri's voice setting and picks the
/// closest voice an app may use. The Mac's "system voice" is often unset,
/// which spoke nothing at all.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
  private let synth = AVSpeechSynthesizer()
  private let voice = Speaker.bestVoice()
  var onDone: () -> Void = {}

  override init() {
    super.init()
    synth.delegate = self
  }

  /// Siri's voice (Settings → Siri → Voice): name, language, gender (1 male, 2 female).
  static func siriPreference() -> (name: String, language: String, gender: Int)? {
    guard let voice = CFPreferencesCopyAppValue("Output Voice" as CFString, "com.apple.assistant.backedup" as CFString) as? [String: Any] else { return nil }
    return ((voice["Name"] as? String ?? "").lowercased(), (voice["Language"] as? String ?? "").replacingOccurrences(of: "_", with: "-"), voice["Gender"] as? Int ?? 0)
  }

  /// Siri's own voice if it's ever installed for speech, else one of the
  /// same gender, language and region, else the best in the user's language.
  static func bestVoice() -> AVSpeechSynthesisVoice? {
    let siri = siriPreference()
    let wanted = siri?.language.isEmpty == false ? siri!.language : Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
    let parts = wanted.split(separator: "-").map(String.init)
    let language = parts.first ?? "en"
    let region = parts.count > 1 ? parts[1] : (Locale.current.region?.identifier ?? "")
    let wantedGender: AVSpeechSynthesisVoiceGender? = siri?.gender == 2 ? .female : siri?.gender == 1 ? .male : nil
    var best: (voice: AVSpeechSynthesisVoice, score: Int)?
    for voice in AVSpeechSynthesisVoice.speechVoices() {
      let locale = voice.language.split(separator: "-").map(String.init)
      guard locale.first == language else { continue }
      // Novelty voices (Bells, Zarvox…) are never Siri.
      if voice.voiceTraits.contains(.isNoveltyVoice) { continue }
      var score = 1
      if let name = siri?.name, !name.isEmpty, voice.name.lowercased().hasPrefix(name) || voice.identifier.lowercased().contains(".\(name)") { score += 500 }
      if let wantedGender, voice.gender == wantedGender { score += 100 }
      if locale.count > 1, locale[1] == region { score += 40 }
      switch voice.quality {
      case .premium: score += 13
      case .enhanced: score += 9
      default: break
      }
      if best == nil || score > best!.score { best = (voice, score) }
    }
    return best?.voice
  }

  func say(_ text: String) {
    synth.stopSpeaking(at: .immediate)
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = voice
    synth.speak(utterance)
  }

  func stop() { synth.stopSpeaking(at: .immediate) }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor in self.onDone() }
  }
}

/// RMS of a buffer's first channel.
nonisolated private func loudness(_ buffer: AVAudioPCMBuffer) -> Float {
  guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
  var sum: Float = 0
  for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
  return (sum / Float(buffer.frameLength)).squareRoot()
}

/// Shared turn-taking: quiet after speech, or too long, ends the turn.
private struct TurnClock {
  static let quietLevel: Float = 0.012
  static let silenceAfter: TimeInterval = 1.5
  static let maxDuration: TimeInterval = 30

  let started = Date.now
  var heardSpeech = false
  var lastLoud = Date.now

  mutating func heard(_ rms: Float) {
    if rms > Self.quietLevel {
      heardSpeech = true
      lastLoud = .now
    }
  }

  var isOver: Bool {
    Date.now.timeIntervalSince(started) > Self.maxDuration || (heardSpeech && Date.now.timeIntervalSince(lastLoud) > Self.silenceAfter)
  }
}

/// macOS 26: SpeechAnalyzer's on-device transcriber, which needs only the
/// microphone (no speech-recognition grant, so no second prompt).
@available(macOS 26.0, *)
final class Listener {
  let id: String
  private let send: @MainActor @Sendable (VoiceEvent) -> Void
  private let engine = AVAudioEngine()
  private var analyzer: SpeechAnalyzer?
  private var input: AsyncStream<AnalyzerInput>.Continuation?
  private var finished = false
  private var clock = TurnClock()
  private var watchdog: Task<Void, Never>?
  private var finalText = ""
  private var volatileText = ""

  init(id: String, send: @escaping @MainActor @Sendable (VoiceEvent) -> Void) {
    self.id = id
    self.send = send
  }

  func start() async {
    guard await AVCaptureDevice.requestAccess(for: .audio) else { return fail("mic-denied") }
    let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
    let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
    do {
      if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        send(.downloading(id: id))
        try await install.downloadAndInstall()
      }
    } catch { return fail("model-unavailable") }
    guard !finished else { return }

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    self.analyzer = analyzer
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return fail("no-format") }
    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    input = continuation

    // Volatile text replaces itself; finals accumulate.
    Task { [weak self] in
      do {
        for try await result in transcriber.results {
          guard let self else { return }
          let text = String(result.text.characters)
          if result.isFinal {
            finalText += text
            volatileText = ""
          } else {
            volatileText = text
          }
          send(.partial(id: id, text: finalText + volatileText))
        }
      } catch {}
    }
    do { try await analyzer.start(inputSequence: stream) } catch { return fail("analyzer") }

    let node = engine.inputNode
    let inputFormat = node.outputFormat(forBus: 0)
    guard inputFormat.channelCount > 0, let converter = AVAudioConverter(from: inputFormat, to: format) else { return fail("no-microphone") }
    // The tap runs on the audio thread; the converter is used only there.
    let audioConverter = converter
    let id = id
    let send = send
    let level: @Sendable (Float) -> Void = { [weak self] rms in
      Task { @MainActor in
        self?.clock.heard(rms)
        send(.level(id: id, value: Double(min(1, rms * 6))))
      }
    }
    node.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
      level(loudness(buffer))
      let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / inputFormat.sampleRate + 32)
      guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
      nonisolated(unsafe) var fed = false
      var error: NSError?
      audioConverter.convert(to: out, error: &error) { _, status in
        if fed {
          status.pointee = .noDataNow
          return nil
        }
        fed = true
        status.pointee = .haveData
        return buffer
      }
      if error == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
    }
    do { try engine.start() } catch { return fail("mic-start") }
    send(.listening(id: id))
    watchdog = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(100))
        guard let self else { return }
        if clock.isOver { stop() }
      }
    }
  }

  func stop() {
    guard !finished else { return }
    finished = true
    watchdog?.cancel()
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    input?.finish()
    Task { [weak self] in
      guard let self else { return }
      try? await analyzer?.finalizeAndFinishThroughEndOfInput()
      send(.final(id: id, text: (finalText + volatileText).trimmingCharacters(in: .whitespacesAndNewlines)))
    }
  }

  func fail(_ reason: String) {
    guard !finished else { return }
    finished = true
    watchdog?.cancel()
    if engine.isRunning {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
    input?.finish()
    send(.error(id: id, reason: reason))
  }
}

/// macOS 14–15: SFSpeechRecognizer, on-device where the Mac supports it.
/// Needs the speech-recognition grant as well as the microphone.
final class LegacyListener {
  let id: String
  private let send: @MainActor @Sendable (VoiceEvent) -> Void
  private let engine = AVAudioEngine()
  private let recognizer = SFSpeechRecognizer()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var finished = false
  private var clock = TurnClock()
  private var watchdog: Task<Void, Never>?
  private var text = ""

  init(id: String, send: @escaping @MainActor @Sendable (VoiceEvent) -> Void) {
    self.id = id
    self.send = send
  }

  func start() {
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      Task { @MainActor in
        guard let self else { return }
        guard status == .authorized else { return self.fail("speech-denied") }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { return self.fail("mic-denied") }
        self.begin()
      }
    }
  }

  private func begin() {
    guard !finished, let recognizer, recognizer.isAvailable else { return fail("model-unavailable") }
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
    self.request = request
    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      let text = result?.bestTranscription.formattedString
      let isFinal = result?.isFinal ?? false
      let failed = error != nil
      Task { @MainActor in
        guard let self else { return }
        if let text {
          self.text = text
          self.send(.partial(id: self.id, text: text))
          if isFinal { self.finish() }
        } else if failed {
          self.finish()
        }
      }
    }
    let node = engine.inputNode
    let format = node.outputFormat(forBus: 0)
    guard format.channelCount > 0 else { return fail("no-microphone") }
    nonisolated(unsafe) let audioRequest = request
    let id = id
    let send = send
    let level: @Sendable (Float) -> Void = { [weak self] rms in
      Task { @MainActor in
        self?.clock.heard(rms)
        send(.level(id: id, value: Double(min(1, rms * 6))))
      }
    }
    node.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
      audioRequest.append(buffer)
      level(loudness(buffer))
    }
    do { try engine.start() } catch { return fail("mic-start") }
    send(.listening(id: id))
    watchdog = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(100))
        guard let self else { return }
        if clock.isOver { stop() }
      }
    }
  }

  func stop() {
    guard !finished else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    request?.endAudio()
    // The final result usually follows endAudio; if not, finish with what we have.
    Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(1200))
      self?.finish()
    }
  }

  private func finish() {
    guard !finished else { return }
    finished = true
    watchdog?.cancel()
    if engine.isRunning {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
    task?.cancel()
    send(.final(id: id, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
  }

  func fail(_ reason: String) {
    guard !finished else { return }
    finished = true
    watchdog?.cancel()
    if engine.isRunning {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
    task?.cancel()
    send(.error(id: id, reason: reason))
  }
}

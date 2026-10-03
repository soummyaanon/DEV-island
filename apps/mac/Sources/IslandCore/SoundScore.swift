import Foundation

/// The island's synthesized sounds, note for note from 1.x's `sounds.ts`: six
/// themes of Web Audio oscillators with exponential envelopes. The anime pack
/// plays bundled MP3s instead (`SoundScore.file`).
public struct SoundScore: Equatable, Sendable {
  public enum Wave: Sendable { case square, sine, triangle }

  /// One oscillator: a steady note, or a slide between two pitches.
  public struct Voice: Equatable, Sendable {
    public var from: Double
    public var to: Double
    /// Start and length, in seconds.
    public var at: Double
    public var duration: Double
    public var volume: Double
    public var wave: Wave
    public var attack: Double
  }

  public var voices: [Voice]

  /// A bundled MP3 for the anime theme, and its volume.
  public static func file(_ event: SoundEvent) -> (name: String, volume: Double) {
    switch event {
    case .success: ("thik-ha", 0.55)
    case .attention: ("anime-wow", 0.55)
    case .question: ("anime-shine", 0.5)
    case .approve: ("fahhhhh", 0.55)
    case .timer: ("anime-shine", 0.55)
    }
  }

  // MARK: Instruments

  private static func note(_ f: Double, _ at: Double, _ dur: Double, _ volume: Double = 0.045, _ wave: Wave = .square, _ attack: Double = 0.008) -> [Voice] {
    [Voice(from: f, to: f, at: at, duration: dur, volume: volume, wave: wave, attack: attack)]
  }

  /// A pitch slide: an arcade power-up.
  private static func slide(_ from: Double, _ to: Double, _ at: Double, _ dur: Double, _ volume: Double = 0.06) -> [Voice] {
    [Voice(from: from, to: to, at: at, duration: dur, volume: volume, wave: .square, attack: 0.01)]
  }

  /// A struck tone with overtones decaying faster the higher they sit, and an
  /// optional detuned twin that beats slowly: mallet, glass, bowl.
  private static func strike(_ f: Double, _ at: Double, _ dur: Double, _ volume: Double, _ partials: [(Double, Double)], detune: Double = 0) -> [Voice] {
    var tones = [(f, volume, dur)]
    for (ratio, relative) in partials { tones.append((f * ratio, volume * relative, dur / ratio.squareRoot())) }
    if detune != 0 { tones.append((f * pow(2, detune / 1200), volume * 0.6, dur)) }
    return tones.flatMap { note($0.0, at, $0.2, $0.1, .sine, 0.004) }
  }

  private static func glass(_ f: Double, _ at: Double, _ v: Double = 0.05) -> [Voice] {
    strike(f, at, 0.9, v, [(2.76, 0.25), (5.4, 0.08)], detune: 7)
  }

  private static func wood(_ f: Double, _ at: Double, _ v: Double = 0.09) -> [Voice] {
    strike(f, at, 0.32, v, [(4, 0.3), (9.9, 0.06)])
  }

  private static func bowl(_ f: Double, _ at: Double, _ v: Double = 0.06) -> [Voice] {
    strike(f, at, 2.2, v, [(2.71, 0.35), (5.1, 0.12)], detune: 4)
  }

  /// A struck bell: inharmonic partials, a long ring.
  private static func bell(_ f: Double, _ at: Double, _ v: Double = 0.06) -> [Voice] {
    strike(f, at, 1.6, v, [(2.0, 0.5), (3.01, 0.28), (4.2, 0.12)], detune: 3)
  }

  /// A bubble: a quick sine falling into its note.
  private static func bubble(_ f: Double, _ at: Double, _ v: Double = 0.08) -> [Voice] {
    [Voice(from: f * 1.7, to: f, at: at, duration: 0.09, volume: v, wave: .sine, attack: 0.004)]
  }

  /// A water drop: a sine flicking upward, with a faint echo.
  private static func drop(_ f: Double, _ at: Double, _ v: Double = 0.08) -> [Voice] {
    [Voice(from: f, to: f * 1.9, at: at, duration: 0.11, volume: v, wave: .sine, attack: 0.003),
     Voice(from: f * 1.1, to: f * 2, at: at + 0.13, duration: 0.08, volume: v * 0.3, wave: .sine, attack: 0.003)]
  }

  /// The score for `event` in `theme`; nil for the anime theme (a file).
  public static func score(_ theme: SoundTheme, _ event: SoundEvent) -> SoundScore? {
    let voices: [Voice]
    switch (theme, event) {
    case (.eightBit, .success):
      voices = note(523.25, 0, 0.09, 0.06) + note(659.25, 0.07, 0.09, 0.06) + note(783.99, 0.14, 0.09, 0.06) + note(1046.5, 0.21, 0.16, 0.08)
    case (.eightBit, .attention):
      voices = note(1318.5, 0, 0.08, 0.14) + note(1318.5, 0.13, 0.12, 0.16)
    case (.eightBit, .question):
      voices = note(659.25, 0, 0.09, 0.09) + note(987.77, 0.09, 0.16, 0.11)
    case (.eightBit, .approve):
      voices = note(880, 0, 0.06, 0.07) + note(1318.5, 0.06, 0.1, 0.08)

    case (.arcade, .success):
      voices = note(987.77, 0, 0.06, 0.07) + slide(1318.5, 2637, 0.06, 0.14, 0.07)
    case (.arcade, .attention):
      voices = note(783.99, 0, 0.1, 0.14) + note(1174.7, 0.11, 0.1, 0.14) + note(783.99, 0.22, 0.1, 0.14) + note(1174.7, 0.33, 0.12, 0.16)
    case (.arcade, .question):
      voices = note(1046.5, 0, 0.07, 0.09) + note(1568, 0.08, 0.07, 0.09) + note(1318.5, 0.16, 0.12, 0.09)
    case (.arcade, .approve):
      voices = slide(1046.5, 2093, 0, 0.12, 0.07)

    case (.soft, .success):
      voices = note(523.25, 0, 0.5, 0.05, .sine, 0.06) + note(783.99, 0.12, 0.6, 0.045, .sine, 0.06)
    case (.soft, .attention):
      voices = note(880, 0, 0.4, 0.08, .triangle, 0.02) + note(880, 0.28, 0.5, 0.09, .triangle, 0.02)
    case (.soft, .question):
      voices = note(1046.5, 0, 0.45, 0.07, .triangle, 0.02)
    case (.soft, .approve):
      voices = note(659.25, 0, 0.3, 0.06, .sine, 0.03)

    case (.glass, .success):
      voices = glass(1567.98, 0) + glass(2093, 0.1, 0.055)
    case (.glass, .attention):
      voices = glass(2349.3, 0, 0.09) + glass(2349.3, 0.12, 0.09) + glass(2793.8, 0.24, 0.1)
    case (.glass, .question):
      voices = glass(1760, 0, 0.06) + glass(2637, 0.14, 0.05)
    case (.glass, .approve):
      voices = glass(2093, 0, 0.06)

    case (.marimba, .success):
      voices = wood(392, 0) + wood(440, 0.08) + wood(523.25, 0.16) + wood(659.25, 0.24, 0.1)
    case (.marimba, .attention):
      voices = (0..<4).flatMap { wood(880, Double($0) * 0.11, 0.14) }
    case (.marimba, .question):
      voices = wood(523.25, 0, 0.1) + wood(783.99, 0.12, 0.11)
    case (.marimba, .approve):
      voices = wood(659.25, 0, 0.09) + wood(523.25, 0.07, 0.09)

    case (.zen, .success):
      voices = bowl(261.63, 0) + bowl(392, 0.35, 0.045)
    case (.zen, .attention):
      voices = bowl(523.25, 0, 0.1) + bowl(523.25, 0.45, 0.11)
    case (.zen, .question):
      voices = bowl(440, 0, 0.08)
    case (.zen, .approve):
      voices = bowl(329.63, 0, 0.05)

    case (.eightBit, .timer):
      voices = (0..<2).flatMap { r in
        note(783.99, Double(r) * 0.42, 0.08, 0.07) + note(1046.5, Double(r) * 0.42 + 0.09, 0.08, 0.07) + note(1318.5, Double(r) * 0.42 + 0.18, 0.14, 0.08)
      }
    case (.arcade, .timer):
      voices = note(1046.5, 0, 0.08, 0.08) + note(1046.5, 0.1, 0.08, 0.08) + note(1046.5, 0.2, 0.08, 0.08) + slide(1318.5, 2093, 0.32, 0.22, 0.08)
    case (.soft, .timer):
      voices = note(659.25, 0, 0.5, 0.05, .sine, 0.05) + note(783.99, 0.22, 0.5, 0.05, .sine, 0.05) + note(1046.5, 0.44, 0.8, 0.05, .sine, 0.05)
    case (.glass, .timer):
      voices = [1567.98, 1975.5, 2349.3, 3135.96].enumerated().flatMap { glass($0.element, Double($0.offset) * 0.11, 0.06) }
    case (.marimba, .timer):
      voices = [523.25, 659.25, 783.99, 1046.5, 783.99].enumerated().flatMap { wood($0.element, Double($0.offset) * 0.1) }
    case (.zen, .timer):
      voices = bowl(261.63, 0) + bowl(329.63, 0.5, 0.05) + bowl(392, 1.0, 0.05)

    case (.bell, .success):
      voices = bell(783.99, 0) + bell(1046.5, 0.18, 0.05)
    case (.bell, .attention):
      voices = bell(1318.5, 0, 0.08) + bell(1318.5, 0.22, 0.08) + bell(1318.5, 0.44, 0.09)
    case (.bell, .question):
      voices = bell(987.77, 0, 0.06) + bell(1318.5, 0.16, 0.06)
    case (.bell, .approve):
      voices = bell(1046.5, 0, 0.05)
    case (.bell, .timer):
      voices = bell(659.25, 0) + bell(783.99, 0.3) + bell(1046.5, 0.6, 0.07)

    case (.pop, .success):
      voices = bubble(523.25, 0) + bubble(659.25, 0.08) + bubble(783.99, 0.16)
    case (.pop, .attention):
      voices = (0..<4).flatMap { bubble(987.77, Double($0) * 0.1, 0.12) }
    case (.pop, .question):
      voices = bubble(659.25, 0, 0.1) + bubble(987.77, 0.12, 0.1)
    case (.pop, .approve):
      voices = bubble(783.99, 0, 0.09)
    case (.pop, .timer):
      voices = [523.25, 659.25, 783.99, 1046.5, 1318.5].enumerated().flatMap { bubble($0.element, Double($0.offset) * 0.07, 0.1) }

    case (.chime, .success):
      voices = [1174.7, 1318.5, 1568].enumerated().flatMap { glass($0.element, Double($0.offset) * 0.09, 0.045) }
    case (.chime, .attention):
      voices = [1760, 1568, 1760, 1568].enumerated().flatMap { glass($0.element, Double($0.offset) * 0.12, 0.08) }
    case (.chime, .question):
      voices = glass(1318.5, 0, 0.05) + glass(1760, 0.1, 0.05)
    case (.chime, .approve):
      voices = glass(1568, 0, 0.045)
    case (.chime, .timer):
      voices = [1046.5, 1174.7, 1318.5, 1568, 1760, 2093].enumerated().flatMap { glass($0.element, Double($0.offset) * 0.08, 0.05) }

    case (.droplet, .success):
      voices = drop(880, 0) + drop(1174.7, 0.15)
    case (.droplet, .attention):
      voices = drop(1318.5, 0, 0.12) + drop(1318.5, 0.2, 0.12) + drop(1318.5, 0.4, 0.13)
    case (.droplet, .question):
      voices = drop(987.77, 0, 0.1)
    case (.droplet, .approve):
      voices = drop(783.99, 0, 0.08)
    case (.droplet, .timer):
      voices = drop(659.25, 0) + drop(880, 0.18) + drop(1174.7, 0.36, 0.1)

    case (.anime, _):
      return nil
    }
    return SoundScore(voices: voices)
  }

  public var length: Double { voices.map { $0.at + $0.duration + 0.02 }.max() ?? 0 }

  /// Mono samples at `rate`, the way Web Audio renders it: an exponential
  /// ramp from silence to the volume over the attack, then down to silence at
  /// the end; slides ramp their frequency exponentially too.
  public func render(rate: Double = 44_100) -> [Float] {
    let count = Int((length * rate).rounded(.up))
    var out = [Float](repeating: 0, count: count)
    let floor = 0.0001
    for voice in voices {
      let start = Int(voice.at * rate)
      let end = min(count, Int((voice.at + voice.duration + 0.02) * rate))
      guard start < end else { continue }
      var phase = 0.0
      for i in start..<end {
        let t = Double(i) / rate - voice.at
        let gain: Double
        if t < voice.attack {
          gain = floor * pow(voice.volume / floor, t / voice.attack)
        } else if t < voice.duration {
          gain = voice.volume * pow(floor / voice.volume, (t - voice.attack) / (voice.duration - voice.attack))
        } else {
          gain = 0
        }
        let frequency = voice.from == voice.to
          ? voice.from
          : voice.from * pow(voice.to / voice.from, min(1, t / voice.duration))
        phase += frequency / rate
        phase -= phase.rounded(.down)
        let sample: Double = switch voice.wave {
        case .sine: sin(2 * .pi * phase)
        case .square: phase < 0.5 ? 1 : -1
        case .triangle: 4 * abs(phase - 0.5) - 1
        }
        out[i] += Float(sample * gain)
      }
    }
    return out
  }
}

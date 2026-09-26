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

import Foundation
import os

/// A robot's pose at a moment: where the body is and what the face does. The
/// native port of `bot-avatars`' rig (`BotAvatarSim`), move for move: the idle
/// look from corner to corner with the head turning, nodding and tilting after
/// it, the eyes darting and leading each turn, blinks (now and then a double),
/// a breath, a bob, the flip every `jumpEvery` seconds; the working hop with a
/// full turn every third, its lean from side to side and a laugh now and then;
/// the sleeping nod; and the cross-fade from one state to the next. The rig
/// draws its "now and then"s from a random stream as it goes; here each comes
/// from a seeded stream per stretch of time, with the same ranges, so a pose is
/// a function of the clock alone. Units are the robot's 100-unit design box.
public struct BotPose: Equatable, Sendable {
  /// Up is negative, like the design box.
  public var y: Double = 0
  public var scaleX: Double = 1
  public var scaleY: Double = 1
  /// The head's roll, degrees clockwise.
  public var tilt: Double = 0
  /// The nod, radians: positive tips the face up.
  public var pitch: Double = 0
  /// The turn about the vertical axis, radians: a look to the side, or a spin 0 → 2π.
  public var yaw: Double = 0
  /// 0 open … 1 shut.
  public var blink: Double = 0
  public var lookX: Double = 0
  public var lookY: Double = 0
  /// The happy ^ ^ eyes, 0…1; they show as much as the working face does.
  public var laugh: Double = 0
  /// The breath, −1…1 (the sleeping eyes swell with it).
  public var breath: Double = 0
  /// How much of the working and the sleeping face shows; the rest is the idle one.
  public var working: Double = 0
  public var sleeping: Double = 0
  /// How much of the ring round a spin shows, 0…1 (already times its strength).
  public var whirl: Double = 0
  /// Where the ring's leading edge is, radians.
  public var whirlAngle: Double = 0

  public init() {}

  /// Eyes drawn as closed arcs: asleep, or counting in hide and seek.
  public var asleep: Bool { sleeping > 0.5 }

  /// How a robot moves beyond its state: the package's props, with its defaults.
  public struct Style: Sendable {
    /// How far the head turns to the side while it looks about, 0–2 (`turn`).
    public var turn: Double
    /// Faster or slower than life (`speed`).
    public var speed: Double

    /// The ring swept round a spin, 0 (none) to 2 (`whirl`).
    public var whirl: Double
    /// The ring's size, stroke width, arc length and flattening (`whirlSize`,
    /// `whirlWidth`, `whirlLength`, `whirlTilt`), each 1 as the package has it.
    public var whirlSize: Double
    public var whirlWidth: Double
    public var whirlLength: Double
    public var whirlTilt: Double
    /// The idle flip: how high (design units), how hard it squashes, how many
    /// turns (`jumpHeight`, `jumpSquash`, `jumpSpin`). The working hop is the
    /// package's own, whatever these say.
    public var jumpHeight: Double
    public var jumpSquash: Double
    public var jumpSpin: Double
    /// An idle bot jumps and flips about every this many seconds, give or take
    /// 37.5 % (`jumpEvery`); 0 never.
    public var jumpEvery: Double

    public init(
      turn: Double = 1, speed: Double = 1,
      whirl: Double = 0, whirlSize: Double = 1, whirlWidth: Double = 1, whirlLength: Double = 1, whirlTilt: Double = 1,
      jumpHeight: Double = 26, jumpSquash: Double = 1.15, jumpSpin: Double = 1, jumpEvery: Double = 8
    ) {
      self.turn = turn
      self.speed = speed
      self.whirl = whirl
      self.whirlSize = whirlSize
      self.whirlWidth = whirlWidth
      self.whirlLength = whirlLength
      self.whirlTilt = whirlTilt
      self.jumpHeight = jumpHeight
      self.jumpSquash = jumpSquash
      self.jumpSpin = jumpSpin
      self.jumpEvery = jumpEvery
    }

    /// Without the extras that only make sense in motion: what a paused or
    /// Reduce Motion bot is drawn with, so its still frame never lands mid-spin.
    public var still: Style {
      var style = self
      style.whirl = 0
      style.jumpEvery = 0
      return style
    }
  }

  /// The last change of state, for the cross-fade: from what, and when (the
  /// same clock as the pose's time).
  public struct Change: Equatable, Sendable {
    public var from: AvatarState
    public var at: TimeInterval

    public init(from: AvatarState, at: TimeInterval) {
      self.from = from
      self.at = at
    }
  }

  /// A click at `time` (`poke`): the new click time, or `last` when the
  /// robot is less than 0.6 through a jump already (the package ignores it then).
  public static func poke(
    at time: TimeInterval, state: AvatarState, seed: Double, style: Style = Style(), change: Change? = nil,
    last: TimeInterval?
  ) -> TimeInterval? {
    let speed = max(0, style.speed)
    let t = time * speed + seed * 10
    var changed = -Double.infinity
    if let change, change.from != state { changed = change.at * speed + seed * 10 }
    let clicked = last.map { $0 * speed + seed * 10 }
    guard let jump = Jump.underWay(at: t, state: state, every: style.jumpEvery, seed: seed, changed: changed, clicked: clicked),
      jump.elapsed / Jump.duration(poked: jump.poked) < 0.6
    else { return time }
    return last
  }

  /// A state held still (`restPose`): its head angle, no blink, no motion.
  public static func rest(_ state: AvatarState, eyesShut: Bool = false) -> BotPose {
    let base = Rig.base(state)
    var pose = BotPose()
    pose.pitch = base.pitch
    pose.tilt = base.roll / Rig.degree
    pose.y = base.y
    pose.lookY = base.lookY
    let w = Rig.weights(state)
    (pose.working, pose.sleeping) = eyesShut ? (0, 1) : (w.y, w.z)
    return pose
  }

  /// The pose at `time`. `attention` is the pointer the head follows (none by
  /// default), and `poke` the time of the last click on the robot, which makes
  /// it hop and turn round (see `poke(at:…)`); both on the same clock as `time`.
  public static func at(
    _ time: TimeInterval, state: AvatarState, seed: Double, style: Style = Style(), eyesShut: Bool = false,
    change: Change? = nil, attention: BotAttention = BotAttention(), poke: TimeInterval? = nil
  ) -> BotPose {
    let speed = max(0, style.speed)
    // The rig's own clock: scaled by the speed, and each robot's started somewhere else.
    let t = time * speed + seed * 10
    let rig = Rig(seed: seed, turn: min(2, max(0, style.turn)))

    // The cross-fade: 1.2 s into idle, 0.7 s into working, 1.4 s into sleep, 1 s out of it.
    var from = state
    var changed = -Double.infinity
    var fadeTime = 1.0
    if let change, change.from != state {
      from = change.from
      changed = change.at * speed + seed * 10
      fadeTime = Rig.fadeTime(from: from, to: state)
    }
    let mixAt = { (τ: Double) -> Double in
      guard changed.isFinite else { return 1 }
      return Rig.ease(min(1, max(0, (τ - changed) / fadeTime)))
    }
    let mix = mixAt(t)
    let w = Rig.weights(from) * (1 - mix) + Rig.weights(state) * mix
    let awake = w.x + w.y
    let base = Rig.Base.mixed(Rig.base(from), Rig.base(state), mix)

    // The head and eyes, each following its own targets; mid-fade, both states' blended.
    let now = rig.head(state, upTo: t)
    let before = mix < 1 ? rig.head(from, upTo: t) : nil
    var head = now.at(t)
    if let before { head = Rig.Angles.mixed(before.at(t), head, mix) }

    // A pointer nearby takes over three quarters of the head and adds its own
    // turn, nod and look (the rig's `ptrX`, `ptrY`, `ptrS`).
    let near = attention.strength, own = 1 - 0.75 * near
    var pose = BotPose()
    var yaw = head.yaw * own + attention.yaw
    var pitch = base.pitch + head.pitch * own - 12 * Rig.degree * attention.y * near
    var roll = base.roll + head.roll * own
    var y = base.y
    var sx = 1.0, sy = 1.0
    var laugh = 0.0, whirl = 0.0, whirlAngle = 0.0
    var lookX = base.lookX + head.lookX * own + 4.5 * attention.x * near
    var lookY = base.lookY + head.lookY * own + 3 * attention.y * near

    // The eyes lead a turn and the body wobbles with it (`gazeLead`, `jelly`),
    // run over the last 0.6 s of the head's turning (the pointer's turn taken
    // back along its current speed).
    let yawAt = { (τ: Double) -> Double in
      let m = mixAt(τ)
      let a = now.yaw(τ)
      let pointer = attention.yaw - attention.yawSpeed * (t - τ)
      guard let before, m < 1 else { return a * own + pointer }
      return (before.yaw(τ) * (1 - m) + a * m) * own + pointer
    }
    let (lead, jelly) = Rig.leadAndJelly(yawAt, at: t)
    lookX += lead

    // Blinks, now and then a double, and darts of the eyes, while awake.
    if awake > 0.5 {
      pose.blink = rig.blink(at: t)
      let dart = rig.dart(at: t)
      lookX += dart.x * awake
      lookY += dart.y * awake
    }

    // The flip, every `jumpEvery` or so while idle, or a click's in any state.
    let clicked = poke.map { $0 * speed + seed * 10 }
    if let flip = Jump.underWay(at: t, state: state, every: style.jumpEvery, seed: seed, changed: changed, clicked: clicked) {
      let jump = Jump.apply(
        flip.elapsed, side: flip.side, height: style.jumpHeight, squash: style.jumpSquash,
        spin: max(0, style.jumpSpin.rounded()), poked: flip.poked
      )
      yaw += jump.yaw
      y += jump.y
      sx += jump.scaleX
      sy += jump.scaleY
      roll += jump.lean * Rig.degree
      laugh = max(laugh, jump.laugh)
      if jump.whirl > 0 { (whirl, whirlAngle) = (jump.whirl, jump.whirlAngle) }
    }

    // The working hop, and the last one finishing after the work stops.
    if let hop = Rig.hop(at: t, state: state, from: from, changed: changed, gain: w.y, seed: seed) {
      let k = min(1, hop.phase)
      let lift = sin(.pi * k)
      let spins = (hop.count % 3 + 3) % 3 == 2
      y -= (spins ? Jump.height : Jump.hop) * lift * hop.gain
      let squashed = hop.landed.map {
        $0 < Jump.groundTime ? 1 + 0.25 * Jump.pulse($0 / Jump.groundTime) : Jump.release(($0 - Jump.groundTime) / Jump.riseTime)
      } ?? Jump.landing(hop.phase)
      sx += (0.16 * squashed - 0.06 * lift) * hop.gain
      sy += (-0.18 * squashed + 0.09 * lift) * hop.gain
      if spins {
        yaw += 2 * .pi * Jump.easeInOut(k) * hop.gain
        laugh = max(laugh, lift * hop.gain)
        if Jump.window(k) * hop.gain > whirl { (whirl, whirlAngle) = (Jump.window(k) * hop.gain, Jump.whirlAngle(k)) }
      }
      roll += ((hop.count % 2 + 2) % 2 == 0 ? 1 : -1) * 6 * Rig.degree * lift * hop.gain
    }
    // A laugh now and then while working, and a nod now and then asleep.
    if state == .working { laugh = max(laugh, rig.laugh(at: t, after: changed)) }
    if state == .sleeping { pitch -= 13 * Rig.degree * rig.nod(at: t, after: changed) * w.z }

    // A breath, slower and deeper asleep, and a bob while awake.
    let breath = sin(2 * .pi * Rig.breathPhase(at: t, state: state, from: from, changed: changed, fadeTime: fadeTime, seed: seed))
    sx += breath * (0.008 + 0.014 * w.z)
    sy += breath * (0.012 + 0.02 * w.z)
    y += sin(t * 2 * .pi / 3.4) * 2 * (1 - w.z)
    let wobble = max(-0.08, min(0.28, jelly)) * 0.6
    sx *= 1 + wobble
    sy *= 1 - 0.55 * wobble

    pose.yaw = yaw
    pose.pitch = pitch
    pose.tilt = roll / Rig.degree
    pose.y = y
    pose.scaleX = sx
    pose.scaleY = sy
    pose.lookX = lookX
    pose.lookY = lookY
    pose.laugh = laugh
    pose.breath = breath
    pose.working = w.y
    pose.sleeping = w.z
    pose.whirl = min(1, whirl * min(2, max(0, style.whirl)))
    pose.whirlAngle = whirlAngle
    if eyesShut {
      pose.working = 0
      pose.sleeping = 1
      pose.blink = 0
    }
    return pose
  }
}

/// A pointer near a robot, as the rig follows it (`setPointer`, eased in
/// `update`): where it is across the head (−1.2…1.2, one head width each way,
/// down positive) and how strongly the head follows it (1 within a head width
/// of the middle, fading to 0 three widths away). The robot takes its eyes and
/// head after it: the strength eases at 8 /s, the place at 14 /s, and the turn
/// it asks for (22° across) through the rig's 5 /s smoothing of the head.
/// Stepped by the frame; while nothing's near it settles at rest and a pose
/// with it is the same as one without.
public struct BotAttention: Equatable, Sendable {
  /// Beyond this many head widths from the middle, the pointer is ignored.
  public static let reach = 3.0
  /// The turn at full strength, one head width across, radians.
  public static let turn = 22 * Double.pi / 180

  public private(set) var x = 0.0
  public private(set) var y = 0.0
  public private(set) var strength = 0.0
  /// The pointer's part of the head's turn, and how fast it's changing (per second).
  public private(set) var yaw = 0.0
  public private(set) var yawSpeed = 0.0
  public private(set) var target = Target()

  public struct Target: Equatable, Sendable {
    public var x = 0.0, y = 0.0, strength = 0.0

    public init(x: Double = 0, y: Double = 0, strength: Double = 0) {
      self.x = max(-1.2, min(1.2, x))
      self.y = max(-1.2, min(1.2, y))
      self.strength = max(0, min(1, strength))
    }

    /// For a pointer `dx`, `dy` head widths from the middle of the robot's box
    /// (down positive): the direction, within one width, and the strength.
    public init(dx: Double, dy: Double) {
      let distance = (dx * dx + dy * dy).squareRoot()
      let strength = distance < 1 ? 1 : distance > BotAttention.reach ? 0 : 1 - (distance - 1) / (BotAttention.reach - 1)
      let scale = max(1, distance)
      self.init(x: dx / scale, y: dy / scale, strength: strength)
    }
  }

  public init() {}

  /// Aim at a pointer (nil, or out of reach, lets go).
  public mutating func aim(_ target: Target?) {
    self.target = target ?? Target()
  }

  /// Nothing to follow and nothing left to ease back.
  public var atRest: Bool {
    target.strength == 0 && strength < 1e-4 && abs(yaw) < 1e-5 && abs(x) < 1e-4 && abs(y) < 1e-4
  }

  /// Moves on a frame `dt` seconds long (at most 0.05 s of it, as the rig
  /// takes a frame; already scaled by the robot's speed).
  public mutating func advance(by dt: Double) {
    guard dt > 0 else { return }
    if target.strength == 0, atRest {
      self = BotAttention()
      return
    }
    let step = min(0.05, dt)
    let ease = { (value: Double, goal: Double, rate: Double) in value + (goal - value) * (1 - exp(-rate * step)) }
    strength = ease(strength, target.strength, 8)
    x = ease(x, target.x, 14)
    y = ease(y, target.y, 14)
    let next = ease(yaw, Self.turn * x * strength, 5)
    yawSpeed = (next - yaw) / step
    yaw = next
  }
}

/// One eye as the package draws it (`eyes` face): a quadratic stroke from
/// (−`halfWidth`, `ends`) bending through `bend` to (`halfWidth`, `ends`),
/// `stroke` wide with round caps, at (`x`, `y`) from the face's centre, scaled
/// by (`scaleX`, `scaleY`) as it turns round the head. Open it's a tall pill;
/// blinking, a line; laughing, a ^; asleep, a ∪ that swells with the breath.
public struct BotEye: Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var scaleX: Double
  public var scaleY: Double
  public var opacity: Double
  public var halfWidth: Double
  public var ends: Double
  public var bend: Double
  public var stroke: Double

  /// Both eyes for a pose, left then right; one turned out of sight is left out.
  public static func eyes(for pose: BotPose) -> [BotEye] {
    let clamp = { (v: Double) in max(-1, min(1, v)) }
    let dead = { (v: Double, zone: Double) in abs(v) <= zone ? 0 : (v < 0 ? -1 : 1) * (abs(v) - zone) / (1 - zone) }
    let up = dead(clamp(-pose.pitch / 0.26 - pose.lookY / 7), 0.34)
    let aside = abs(dead(clamp(pose.lookX / 4.5), 0.4))
    let tall = max(0.3, 1 + 0.55 * up - 0.1 * aside)
    let wide = 1 - 0.05 * up + 0.12 * aside
    let working = pose.working, sleeping = pose.sleeping
    let idle = max(0, 1 - working - sleeping)
    let awake = idle + working * (1 - pose.laugh)
    let happy = working * pose.laugh
    let high = max(0, -pose.y) / 26
    let swell = 0.5 + 0.5 * pose.breath
    var out: [BotEye] = []
    for side in [-1.0, 1.0] {
      let open = max(0, min(1, 1 - pose.blink))
      let (o, s) = (awake * open, awake * (1 - open))
      let lx = pose.lookX * (o + 0.5 * (s + happy)), ly = pose.lookY * (o + 0.5 * s)
      // Round the head: the face is a ball 30 across its middle.
      let radius = 30.0
      let across = asin(clamp((side * 12.5 + lx) / radius)) + pose.yaw
      let down = asin(clamp(-(1 + ly) / radius)) + pose.pitch
      let depth = cos(across) * cos(down)
      guard depth > 0.02 else { continue }
      out.append(BotEye(
        x: radius * sin(across) * cos(down), y: -radius * sin(down),
        scaleX: max(0.02, cos(across)), scaleY: max(0.02, cos(down)), opacity: min(1, depth * 5),
        halfWidth: o * 0.01 + s * 5.4 + happy * 6.2 + sleeping * 6,
        ends: o * 1.1 * tall + s * 0.6 + happy * (2.2 - high * 1.5) + sleeping * (-1.4 + swell),
        bend: o * -3.3 * tall + s * 0.6 + happy * (-11.4 - 4 * high) + sleeping * (5.4 + 2 * swell),
        stroke: o * 6.3 * 2 * wide + s * 2.8 + happy * 4.4 + sleeping * 4
      ))
    }
    return out
  }
}

/// The rig's numbers and its now-and-then events, as pure functions of its clock.
struct Rig {
  static let degree = Double.pi / 180
  /// Each stretch of this many seconds draws its own events from its own seeded stream.
  static let epoch = 24.0

  static func ease(_ t: Double) -> Double { 0.5 - 0.5 * cos(.pi * t) }

  /// How much of each state (idle, working, sleeping).
  static func weights(_ state: AvatarState) -> SIMD3<Double> {
    switch state {
    case .idle: SIMD3(1, 0, 0)
    case .working: SIMD3(0, 1, 0)
    case .sleeping: SIMD3(0, 0, 1)
    }
  }

  static func fadeTime(from: AvatarState, to: AvatarState) -> Double {
    if from == .sleeping { return 1 }
    return switch to {
    case .idle: 1.2
    case .working: 0.7
    case .sleeping: 1.4
    }
  }

  /// Where each state holds the head: working looks up a touch; asleep it hangs, tipped over.
  struct Base {
    var pitch = 0.0, roll = 0.0, y = 0.0, lookX = 0.0, lookY = 0.0

    static func mixed(_ a: Base, _ b: Base, _ m: Double) -> Base {
      Base(
        pitch: a.pitch + (b.pitch - a.pitch) * m, roll: a.roll + (b.roll - a.roll) * m, y: a.y + (b.y - a.y) * m,
        lookX: a.lookX + (b.lookX - a.lookX) * m, lookY: a.lookY + (b.lookY - a.lookY) * m
      )
    }
  }

  static func base(_ state: AvatarState) -> Base {
    switch state {
    case .idle: Base()
    case .working: Base(pitch: 5 * degree)
    case .sleeping: Base(pitch: -16 * degree, roll: 6 * degree, y: 3, lookY: 1)
    }
  }

  /// A channel that picks a new target (±`amp`) every `hold` seconds and goes
  /// there: the head as a lightly damped spring, the eyes with an exponential dart.
  struct Channel {
    var amp: Double
    var hold: ClosedRange<Double>
    var rate: Double
    var spring: Bool
  }

  /// The head's five channels in a state (the package's `setState`), built once.
  static func channels(_ state: AvatarState) -> [Channel] {
    switch state {
    case .idle: idleChannels
    case .working: workingChannels
    case .sleeping: sleepingChannels
    }
  }

  private static let idleChannels = [
    Channel(amp: 35 * degree, hold: 2.6...5.4, rate: 2, spring: true),
    Channel(amp: 14 * degree, hold: 2.8...5.8, rate: 1.8, spring: true),
    Channel(amp: 3.2 * degree, hold: 3.4...6.6, rate: 1.5, spring: true),
    Channel(amp: 3.6, hold: 0.6...2.2, rate: 13, spring: false),
    Channel(amp: 2.4, hold: 0.6...2.2, rate: 13, spring: false),
  ]
  private static let workingChannels = [
    Channel(amp: 16 * degree, hold: 0.9...1.8, rate: 4, spring: true),
    Channel(amp: 3 * degree, hold: 1.2...2.4, rate: 3, spring: true),
    Channel(amp: 0, hold: 1...2, rate: 3, spring: true),
    Channel(amp: 2, hold: 0.5...1.2, rate: 12, spring: false),
    Channel(amp: 1, hold: 0.5...1.2, rate: 12, spring: false),
  ]
  private static let sleepingChannels = [
    Channel(amp: 7 * degree, hold: 3...6, rate: 0.7, spring: true),
    Channel(amp: 3 * degree, hold: 3...6, rate: 0.7, spring: true),
    Channel(amp: 2 * degree, hold: 3...6, rate: 0.6, spring: true),
    Channel(amp: 0, hold: 2...4, rate: 2, spring: false),
    Channel(amp: 0, hold: 2...4, rate: 2, spring: false),
  ]

  struct Angles {
    var yaw = 0.0, pitch = 0.0, roll = 0.0, lookX = 0.0, lookY = 0.0

    static func mixed(_ a: Angles, _ b: Angles, _ m: Double) -> Angles {
      Angles(
        yaw: a.yaw + (b.yaw - a.yaw) * m, pitch: a.pitch + (b.pitch - a.pitch) * m, roll: a.roll + (b.roll - a.roll) * m,
        lookX: a.lookX + (b.lookX - a.lookX) * m, lookY: a.lookY + (b.lookY - a.lookY) * m
      )
    }
  }

  /// The head's targets up to a moment, ready to be followed at any time before it.
  struct Head {
    var channels: [Channel]
    var yawLane: Lane, pitchLane: Lane, rollLane: Lane, lookXLane: Lane, lookYLane: Lane

    func at(_ t: Double) -> Angles {
      Angles(
        yaw: yaw(t), pitch: value(pitchLane, 1, t), roll: value(rollLane, 2, t), lookX: value(lookXLane, 3, t),
        lookY: value(lookYLane, 4, t)
      )
    }

    /// The head's turn, low-passed after the spring as the rig's `baseYaw` is.
    func yaw(_ t: Double) -> Double {
      Rig.follow(yawLane, at: t, rate: channels[0].rate, spring: true, smooth: 5)
    }

    private func value(_ lane: Lane, _ i: Int, _ t: Double) -> Double {
      Rig.follow(lane, at: t, rate: channels[i].rate, spring: channels[i].spring)
    }
  }

  /// One channel's targets: each beat's `a` (or `b`) times `scale`, at its time.
  /// A view into the cached beats, so following it allocates nothing.
  struct Lane {
    var beats: ArraySlice<Beat>
    var useB = false
    /// Applied one after another, as the rig multiplies them.
    var scale: (Double, Double, Double) = (1, 1, 1)

    var count: Int { beats.count }
    func time(_ i: Int) -> Double { beats[beats.startIndex + i].time }
    func value(_ i: Int) -> Double {
      let beat = beats[beats.startIndex + i]
      return (useB ? beat.b : beat.a) * scale.0 * scale.1 * scale.2
    }
  }

  /// A seeded stream of uniform numbers in 0..<1 (SplitMix64).
  struct Dice {
    var state: UInt64

    init(_ seed: Double, _ stream: UInt64, _ epoch: Int) {
      state = UInt64(seed * 1e6) &* 0xBF58_476D_1CE4_E5B9 ^ stream &* 0x94D0_49BB_1331_11EB
        ^ UInt64(bitPattern: Int64(epoch)) &* 0x9E37_79B9_7F4A_7C15
    }

    mutating func roll() -> Double {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      z ^= z >> 31
      return Double(z >> 11) / Double(1 << 53)
    }
  }

  struct Beat: Sendable {
    var time: Double
    var a = 0.0, b = 0.0, c = 0.0
  }

  /// A robot's now-and-then events up to `t`, the last `keep` of them. Each
  /// epoch rolls its own: the first within `first` seconds of its start, then
  /// each `fire` says what it is and how long until the next, as the rig's
  /// `…At = now + …` do. `memory` carries what an event remembers of the last.
  /// An epoch's first event waits at least `spacing` after the last one before
  /// it, as any other does. Looks back at most three epochs.
  ///
  /// Each stream's events for a stretch (its epoch and the three before) are
  /// rolled once and cached, so a frame only finds where `t` falls in them.
  /// A stream number always goes with the same `fire`, `first` and `spacing`.
  static func beats(
    upTo t: Double, keep: Int, seed: Double, stream: UInt64, first: Double, spacing: Double,
    _ fire: (inout Dice, inout SIMD2<Double>) -> (beat: (Double, Double, Double), wait: Double)
  ) -> ArraySlice<Beat> {
    let e = Int((t / epoch).rounded(.down))
    let key = BeatCache.Key(seed: seed.bitPattern, stream: stream, epoch: e)
    let list: [Beat]
    if let cached = BeatCache.shared.get(key) {
      list = cached
    } else {
      list = stretch(e, seed: seed, stream: stream, first: first, spacing: spacing, fire)
      BeatCache.shared.set(key, list)
    }
    var end = list.count
    while end > 0, list[end - 1].time > t { end -= 1 }
    return list[max(0, end - keep) ..< end]
  }

  /// Every event of epochs e − 3 … e, in time order.
  private static func stretch(
    _ e: Int, seed: Double, stream: UInt64, first: Double, spacing: Double,
    _ fire: (inout Dice, inout SIMD2<Double>) -> (beat: (Double, Double, Double), wait: Double)
  ) -> [Beat] {
    func run(_ e: Int, spaced: Bool = true) -> [Beat] {
      var dice = Dice(seed, stream, e)
      var memory = SIMD2<Double>(0, 0)
      let close = Double(e + 1) * epoch
      var time = Double(e) * epoch + dice.roll() * first
      if spaced, let last = run(e - 1, spaced: false).last {
        time = max(time, last.time + spacing)
      }
      var out: [Beat] = []
      while time < close {
        let (beat, wait) = fire(&dice, &memory)
        out.append(Beat(time: time, a: beat.0, b: beat.1, c: beat.2))
        time += max(0.01, wait)
      }
      return out
    }
    return (e - 3 ... e).flatMap { run($0) }
  }

  let seed: Double
  let turn: Double

  init(seed: Double, turn: Double) {
    self.seed = seed
    self.turn = turn
  }

  private static func stream(_ state: AvatarState) -> UInt64 {
    switch state {
    case .idle: 0
    case .working: 8
    case .sleeping: 16
    }
  }

  /// The head's targets in `state` up to `t`. Idle, the head is aimed by the
  /// gaze: from a corner it mostly swings across to the opposite one (66 %), now
  /// and then only sideways (19 %) or back to the middle (15 %), from the middle
  /// to any corner; each look held 2.6–4.4 s, 84–100 % of the way out, the yaw
  /// and roll times `turn`.
  func head(_ state: AvatarState, upTo t: Double) -> Head {
    let channels = Self.channels(state)
    let base = Self.stream(state)
    func wander(_ i: Int) -> Lane {
      let channel = channels[i]
      let beats = Self.beats(
        upTo: t, keep: 5, seed: seed, stream: base + 1 + UInt64(i), first: channel.hold.upperBound,
        spacing: channel.hold.lowerBound
      ) { dice, _ in
        let target = (dice.roll() * 2 - 1) * channel.amp
        return ((target, 0, 0), channel.hold.lowerBound + dice.roll() * (channel.hold.upperBound - channel.hold.lowerBound))
      }
      return Lane(beats: beats)
    }
    let yaw: Lane, pitch: Lane, roll: Lane
    if state == .idle {
      let gaze = Self.beats(upTo: t, keep: 5, seed: seed, stream: base, first: 4.4, spacing: 2.6) { dice, memory in
        let next: SIMD2<Double>
        if memory != .zero {
          let r = dice.roll()
          next = r < 0.66 ? -memory : r < 0.85 ? SIMD2(-memory.x, memory.y) : .zero
        } else {
          next = Self.corners[min(3, Int(dice.roll() * 4))]
        }
        memory = next
        let reach = 0.84 + dice.roll() * 0.16
        return ((next.x * reach, next.y * reach, 0), 2.6 + dice.roll() * 1.8)
      }
      yaw = Lane(beats: gaze, scale: (35, Self.degree, turn))
      pitch = Lane(beats: gaze, useB: true, scale: (14, Self.degree, 1))
      roll = Lane(beats: gaze, scale: (3.2, Self.degree, turn))
    } else {
      (yaw, pitch, roll) = (wander(0), wander(1), wander(2))
    }
    return Head(channels: channels, yawLane: yaw, pitchLane: pitch, rollLane: roll, lookXLane: wander(3), lookYLane: wander(4))
  }

  private static let corners: [SIMD2<Double>] = [SIMD2(1, -1), SIMD2(-1, 1), SIMD2(-1, -1), SIMD2(1, 1)]

  /// A channel's value at `t`: at rest on the first target, then going after
  /// each next one, as a spring (ω = 1.6·rate, damping 0.9) or an exponential
  /// approach at `rate`, solved exactly; with `smooth`, the spring's output is
  /// also low-passed at that rate.
  static func follow(_ targets: Lane, at t: Double, rate: Double, spring: Bool, smooth: Double = 0) -> Double {
    guard targets.count > 0 else { return 0 }
    // Targets are in time order: the ones reached by `t`.
    var reached = 0
    while reached < targets.count, targets.time(reached) <= t { reached += 1 }
    guard reached > 1 else { return targets.value(0) }
    var x = targets.value(0), v = 0.0, y = targets.value(0)
    let omega = rate * 1.6, damp = 0.9 * omega, ring = omega * (1 - 0.81).squareRoot()
    for i in 1..<reached {
      let goal = targets.value(i)
      let span = (i + 1 < reached ? targets.time(i + 1) : t) - targets.time(i)
      guard spring else {
        x = goal + (x - goal) * exp(-rate * span)
        continue
      }
      let a = x - goal, b = (v + damp * a) / ring
      let decay = exp(-damp * span), c = cos(ring * span), s = sin(ring * span)
      if smooth > 0 {
        let k = smooth, det = (k - damp) * (k - damp) + ring * ring
        let p = k * (a * (k - damp) - b * ring) / det
        let q = k * (b * (k - damp) + a * ring) / det
        y = goal + (y - goal - p) * exp(-k * span) + decay * (p * c + q * s)
      }
      x = goal + decay * (a * c + b * s)
      v = decay * ((ring * b - damp * a) * c - (ring * a + damp * b) * s)
    }
    return smooth > 0 ? y : x
  }

  /// The eyes running ahead of a turn (up to 2.2 across, `gazeLead`) and the
  /// body's wobble from turning fast (`jelly`), stepped over the last 0.6 s.
  static func leadAndJelly(_ yaw: (Double) -> Double, at t: Double) -> (lead: Double, jelly: Double) {
    // 0.6 s at 30 steps a second: the island draws at 30 fps, and the wobble's
    // spring (ω 16) stays well inside what semi-implicit Euler handles.
    let step = 1.0 / 30, steps = 18
    var lead = 0.0, jelly = 0.0, jellyV = 0.0
    var previous = yaw(t - Double(steps) * step)
    let follow = 1 - exp(-9 * step)
    for i in 1...steps {
      let now = yaw(t - Double(steps - i) * step)
      let speed = (now - previous) / step
      previous = now
      lead += (max(-2.2, min(2.2, speed * 2.4)) - lead) * follow
      let push = min(0.22, 0.055 * abs(speed))
      jellyV += (16 * 16 * (push - jelly) - 2 * 0.45 * 16 * jellyV) * step
      jelly += jellyV * step
    }
    return (lead, jelly)
  }

  /// A blink (0.17 s) every 2.2–4.8 s; after one, a 22 % chance of a second 0.28 s on.
  func blink(at t: Double) -> Double {
    let beats = Self.beats(upTo: t, keep: 1, seed: seed, stream: 30, first: 4.8, spacing: 2.2) { dice, memory in
      let again = memory.x == 0 && dice.roll() < 0.22
      memory.x = again ? 1 : 0
      return ((0, 0, 0), again ? 0.28 : 2.2 + dice.roll() * 2.6)
    }
    guard let last = beats.last, t - last.time < 0.17 else { return 0 }
    return sin(.pi * (t - last.time) / 0.17)
  }

  /// A quick look aside (±4, ±2) for 0.25–0.7 s, every 1.2–3.8 s.
  func dart(at t: Double) -> (x: Double, y: Double) {
    let beats = Self.beats(upTo: t, keep: 1, seed: seed, stream: 31, first: 3.8, spacing: 1.2) { dice, _ in
      let length = 0.25 + dice.roll() * 0.45
      let x = (dice.roll() * 2 - 1) * 4, y = (dice.roll() * 2 - 1) * 2
      return ((length, x, y), 1.2 + dice.roll() * 2.6)
    }
    guard let last = beats.last else { return (0, 0) }
    let p = (t - last.time) / last.a
    guard p < 1 else { return (0, 0) }
    let k = p < 0.15 ? p / 0.15 : p > 0.8 ? (1 - p) / 0.2 : 1
    return (last.b * k, last.c * k)
  }

  /// Working, a laugh of 0.6–1.1 s every 1.6–3.8 s.
  func laugh(at t: Double, after changed: Double) -> Double {
    let beats = Self.beats(upTo: t, keep: 1, seed: seed, stream: 32, first: 3.8, spacing: 1.6) { dice, _ in
      ((0.6 + dice.roll() * 0.5, 0, 0), 1.6 + dice.roll() * 2.2)
    }
    guard let last = beats.last, last.time >= changed else { return 0 }
    let p = (t - last.time) / last.a
    guard p < 1 else { return 0 }
    return p < 0.18 ? p / 0.18 : p > 0.78 ? (1 - p) / 0.22 : 1
  }

  /// Asleep, a deeper nod (1.7 s: down over 72 %, back up) every 4–8 s.
  func nod(at t: Double, after changed: Double) -> Double {
    let beats = Self.beats(upTo: t, keep: 1, seed: seed, stream: 33, first: 6.5, spacing: 4) { dice, _ in
      ((0, 0, 0), 4 + dice.roll() * 4)
    }
    guard let last = beats.last, last.time >= changed else { return 0 }
    let p = (t - last.time) / 1.7
    guard p < 1 else { return 0 }
    return p < 0.72 ? Jump.easeInOut(p / 0.72) : 1 - Jump.easeInOut((p - 0.72) / 0.28)
  }

  /// The working hop at `t`: one every 0.68 s, in the air the whole beat,
  /// fading in with the working state; after the work stops the hop under way
  /// lands and settles, then no more.
  static func hop(
    at t: Double, state: AvatarState, from: AvatarState, changed: Double, gain: Double, seed: Double
  ) -> (phase: Double, count: Int, gain: Double, landed: Double?)? {
    let beat = t / Jump.time + seed
    if state == .working {
      guard gain > 0.02 else { return nil }
      let count = beat.rounded(.down)
      return (beat - count, Int(count), gain, nil)
    }
    guard from == .working, changed.isFinite else { return nil }
    let last = (changed / Jump.time + seed).rounded(.down)
    if beat < last + 1 { return (beat - last, Int(last), 1, nil) }
    let landed = (beat - last - 1) * Jump.time
    guard landed < Jump.groundTime + Jump.riseTime else { return nil }
    return (1, Int(last), 1, landed)
  }

  /// Where the breath is, in cycles: one every 3.6 s awake, 4.8 s asleep,
  /// changing pace smoothly through a fade into or out of sleep.
  static func breathPhase(
    at t: Double, state: AvatarState, from: AvatarState, changed: Double, fadeTime: Double, seed: Double
  ) -> Double {
    let period = { (sleep: Double) in 3.6 + 1.2 * sleep }
    let before = weights(from).z, after = weights(state).z
    guard changed.isFinite, before != after, t > changed else { return t / period(after) + seed }
    let end = min(t, changed + fadeTime)
    // Simpson's rule over the fade.
    let n = 8, h = (end - changed) / Double(n)
    var sum = 0.0
    for i in 0...n {
      let sleep = before + (after - before) * ease(Double(i) * h / fadeTime)
      sum += (i == 0 || i == n ? 1 : i % 2 == 1 ? 4 : 2) / period(sleep)
    }
    return changed / period(before) + sum * h / 3 + max(0, t - changed - fadeTime) / period(after) + seed
  }
}

/// Each stream's rolled events per stretch, shared by every robot on every
/// thread. Small: a stretch lasts 24 s, and the whole cache is dropped when it
/// passes a few hundred of them.
final class BeatCache: Sendable {
  struct Key: Hashable, Sendable {
    var seed: UInt64
    var stream: UInt64
    var epoch: Int
  }

  static let shared = BeatCache()
  private static let limit = 512
  private let store = OSAllocatedUnfairLock(initialState: [Key: [Rig.Beat]]())

  func get(_ key: Key) -> [Rig.Beat]? {
    store.withLock { $0[key] }
  }

  func set(_ key: Key, _ beats: [Rig.Beat]) {
    store.withLock {
      if $0.count >= Self.limit { $0.removeAll(keepingCapacity: true) }
      $0[key] = beats
    }
  }
}

/// The package's jump (`botAvatarJumpDefaults`) and the idle flip built on it:
/// crouch, leap with a full turn and a lean, land in a squash that settles.
/// `height`, `squash`, the spin and `every` are style options; the rest are the
/// package defaults.
public enum Jump {
  public static let height = 26.0
  static let time = 0.68
  static let stretch = 1.0
  public static let squash = 1.15
  static let squashTime = 0.37
  static let groundTime = 0.11
  static let riseTime = 0.33
  /// Degrees the body leans into the jump.
  static let lean = 6.0
  /// A working bot's everyday hop, against which its third, spinning hop is `height`.
  static let hop = 18.0
  /// The crouch before an unprompted jump.
  static let crouch = 0.2 * time
  /// Where the "pulse" squash peaks, as a share of `squashTime`.
  static let pulsePeak = 2.0 / 7
  static let duration = crouch + time + pulsePeak * squashTime + groundTime + riseTime + 0.05
  /// A click's jump crouches, and lands, over this long instead (`jumpClickSquashTime`).
  public static let clickSquashTime = 0.24

  /// How long a jump lasts, a click's or an unprompted one.
  public static func duration(poked: Bool) -> Double {
    poked ? clickSquashTime + time + pulsePeak * clickSquashTime + groundTime + riseTime + 0.05 : duration
  }

  /// The jump under way at `t` (rig time), if any: the last click's (at
  /// `clicked`), else the flip due while idle and since the last change of
  /// state. A flip that falls due while a click's jump runs is skipped.
  static func underWay(
    at t: Double, state: AvatarState, every: Double, seed: Double, changed: Double, clicked: Double?
  ) -> (elapsed: Double, side: Double, poked: Bool)? {
    if let clicked, let jump = poked(at: t, clicked: clicked, seed: seed) { return jump }
    guard state == .idle, let due = flip(at: t, every: every, seed: seed) else { return nil }
    let start = t - due.elapsed
    guard start >= changed else { return nil }
    if let clicked, start >= clicked, start < clicked + duration(poked: true) { return nil }
    return (due.elapsed, due.side, false)
  }

  /// The click's jump under way at `t` (rig time), if any, and which way it leans.
  static func poked(at t: Double, clicked: Double, seed: Double) -> (elapsed: Double, side: Double, poked: Bool)? {
    let elapsed = t - clicked
    guard elapsed >= 0, elapsed < duration(poked: true) else { return nil }
    let side = random(Int((clicked * 1000).rounded()), seed, 2) < 0.5 ? -1.0 : 1.0
    return (elapsed, side, true)
  }

  /// The flip under way at `t`, if any: seconds since it began, and which way
  /// it leans. Starts sit about `every` apart, give or take 37.5 % (the
  /// package's `every · (0.625 + 0.75·rand)` range, found from the time alone
  /// so any frame can be drawn on its own); one never cuts another short.
  static func flip(at t: Double, every: Double, seed: Double) -> (elapsed: Double, side: Double)? {
    guard every > 0 else { return nil }
    let start = { (k: Int) in every * (Double(k) + 0.375 * (random(k, seed, 0) - 0.5)) }
    let slot = Int((t / every).rounded(.down))
    // The latest start not after `t`, unless the one before it still runs.
    guard var k = (slot - 1...slot + 1).reversed().first(where: { start($0) <= t }) else { return nil }
    if start(k - 1) + duration > t { k -= 1 }
    let elapsed = t - start(k)
    guard elapsed < duration else { return nil }
    return (elapsed, random(k, seed, 1) < 0.5 ? -1 : 1)
  }

  /// What the jump adds to a pose, `elapsed` seconds in.
  struct Offset {
    var yaw = 0.0, y = 0.0, scaleX = 0.0, scaleY = 0.0
    /// Degrees.
    var lean = 0.0
    var laugh = 0.0, whirl = 0.0, whirlAngle = 0.0
  }

  /// The jump, `elapsed` seconds in: `height` high, squashing `squash` hard,
  /// `spin` turns (with a smile, and the ring, while it turns). A click's
  /// (`poked`) crouches and lands over `clickSquashTime`, easing down into the
  /// crouch rather than bumping.
  static func apply(
    _ elapsed: Double, side: Double, height: Double = height, squash: Double = squash, spin: Double = 1,
    poked: Bool = false
  ) -> Offset {
    var out = Offset()
    let crouch = poked ? clickSquashTime : crouch
    let squashTime = poked ? clickSquashTime : squashTime
    let y = (elapsed - crouch) / time
    let q = min(1, max(0, y))
    let w = sin(.pi * q)
    out.yaw = 2 * .pi * spin * easeInOut(q)
    out.y = -height * w
    // Seconds since landing, and the squash through crouch, landing and settling.
    let x = (y - 1) * time
    let peak = pulsePeak * squashTime
    let rising = x - peak - groundTime
    let settle = x <= peak ? pulse(x / squashTime)
      : rising <= 0 ? 1 + 0.25 * pulse((x - peak) / groundTime)
      : release(rising / riseTime)
    let down = { (u: Double) in poked ? u * u * (3 - 2 * u) : landing(u - 1) }
    let squashed = (y < 0 ? down(max(0, 1 + y * time / crouch)) : x > 0 ? settle : y < 0.2 ? landing(y) : 0) * squash
    out.scaleX = 0.16 * squashed - 0.06 * w * stretch
    out.scaleY = -0.18 * squashed + 0.09 * w * stretch
    out.lean = side * lean * w
    if spin > 0 {
      out.laugh = w
      out.whirl = window(q)
      out.whirlAngle = whirlAngle(q)
    }
    return out
  }

  /// The ring fades in as the turn gets going and out before it ends.
  static func window(_ q: Double) -> Double {
    smoothstep(0.1, 0.26, q) * (1 - smoothstep(0.66, 0.9, q))
  }

  /// The ring runs ahead of the body: one and a half turns steady plus most of one eased.
  static func whirlAngle(_ q: Double) -> Double {
    2 * .pi * (1.5 * q + 0.9 * easeInOut(q))
  }

  static func easeInOut(_ t: Double) -> Double {
    t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
  }

  static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let q = min(1, max(0, (x - a) / (b - a)))
    return q * q * (3 - 2 * q)
  }

  /// A bump at each end of the leap, 0.11 wide.
  static func landing(_ t: Double) -> Double {
    exp(-pow(min(abs(t), abs(t - 1)) / 0.11, 2))
  }

  /// The "pulse" squash: up to 1 at `pulsePeak`, eased away before 1.
  static func pulse(_ t: Double) -> Double {
    guard t > 0, t < 1 else { return 0 }
    let i = 7 * t
    let s = i * i * exp(2 - i) / 4
    let a = t > 0.85 ? 1 - (t - 0.85) / 0.15 : 1
    return s * a * a * (3 - 2 * a)
  }

  /// The "pulse" release from the ground: 1 down to 0.
  static func release(_ t: Double) -> Double {
    if t <= 0 { return 1 }
    if t >= 1 { return 0 }
    let s = 4.2 * t
    return (1 + s) * exp(-s) - t * t * t * 0.078
  }

  /// 0..<1 from a flip's index, the robot's seed and a stream.
  static func random(_ k: Int, _ seed: Double, _ stream: UInt64) -> Double {
    var z = UInt64(bitPattern: Int64(k)) &* 0x9E37_79B9_7F4A_7C15
      ^ UInt64(seed * 1e6) &* 0xBF58_476D_1CE4_E5B9 ^ stream &* 0x94D0_49BB_1331_11EB
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    z ^= z >> 31
    return Double(z >> 11) / Double(1 << 53)
  }
}

/// The ring swept round a spinning bot, as the package draws it: 34 short arcs
/// of a tilted ellipse about the body, thick and bright at the leading edge and
/// thinning behind, the half behind the body drawn before it and the near half
/// (with a soft shadow) after. Units are the design box, centred on the body.
public struct WhirlRing: Sendable {
  public enum Tone: Sendable { case shadow, halo, dark, base, light, shine }

  /// One arc: from `start` to `end` (radians, clockwise from 3 o'clock) on the
  /// ellipse moved `dy` down, `width` wide.
  public struct Arc: Sendable {
    public var start: Double
    public var end: Double
    public var width: Double
    public var dy: Double
    public var tone: Tone
    public var opacity: Double
  }

  /// The whole ring leans this much (radians) and sits this far below centre.
  public static let lean = -0.28
  public static let drop = 5.0
  static let segments = 34
  /// Where the light comes from (the package's 265°), as an angle on the ring.
  static let light = atan2(-cos(265 * Double.pi / 180), sin(265 * Double.pi / 180)) - lean

  public var radiusX: Double
  public var radiusY: Double
  public var arcs: [Arc]

  /// The front or back half for this pose, or nil when there's nothing to see.
  public init?(pose: BotPose, style: BotPose.Style, front: Bool) {
    let strength = min(1, pose.whirl)
    guard strength > 0.01 else { return nil }
    let size = min(1.6, max(0.6, style.whirlSize))
    let widthK = min(2, max(0.4, style.whirlWidth))
    let span = Double.pi * 1.55 * min(1.6, max(0.4, style.whirlLength))
    let tilt = min(1.8, max(0.5, style.whirlTilt))
    radiusX = 57 * size
    radiusY = radiusX * 0.4 * tilt * (front ? 1.14 : 0.86)
    let lead = -pose.whirlAngle
    let n = Double(Self.segments)
    var arcs: [Arc] = []
    if front {
      for i in 0..<Self.segments {
        let t = Double(i) / n
        let a = lead + t * span, b = a + span / n + 0.012
        guard sin((a + b) / 2) > 0 else { continue }
        let fade = pow(1 - t, 1.3)
        arcs.append(Arc(start: a, end: b, width: (2 + 8 * fade) * 1.5 * widthK, dy: 3.5, tone: .shadow, opacity: 0.2 * strength * fade))
      }
    }
    for i in 0..<Self.segments {
      let t = Double(i) / n
      let a = lead + t * span, b = a + span / n + 0.012, mid = (a + b) / 2
      guard (sin(mid) > 0) == front else { continue }
      let near = 0.6 + 0.4 * sin(mid)
      let fade = pow(1 - t, 1.3)
      let ripple = 1 + 0.18 * sin(t * 9 + 1.2)
      let w = (2 + 8 * fade) * near * widthK * ripple
      let v = strength * (0.3 + 0.7 * fade) * near
      let lit = 0.5 + 0.5 * cos(mid - Self.light)
      arcs.append(Arc(start: a, end: b, width: w * 2.6, dy: 0, tone: .halo, opacity: v * 0.2))
      arcs.append(Arc(start: a, end: b, width: w * 0.8, dy: w * 0.32, tone: .dark, opacity: v * 0.45))
      arcs.append(Arc(start: a, end: b, width: w, dy: 0, tone: .base, opacity: v * 0.72))
      arcs.append(Arc(start: a, end: b, width: w * 0.62, dy: -w * 0.16, tone: .light, opacity: v * 0.78 * (0.4 + 0.6 * lit)))
      arcs.append(Arc(start: a, end: b, width: w * 0.24, dy: -w * 0.3, tone: .shine, opacity: v * 0.9 * (0.15 + 0.85 * lit * lit)))
    }
    self.arcs = arcs
  }

  /// Each tone's colour for a robot of `color` (0xRRGGBB), from the colour the
  /// package paints it (its default saturation 1.5 lifts it first).
  public static func color(_ tone: Tone, for color: UInt32) -> UInt32 {
    let painted = HSL(color).adjusted(lightness: 0, saturation: 0.25)
    return switch tone {
    case .shadow: 0x000000
    case .shine: 0xFFFFFF
    case .base: painted.adjusted(lightness: 0.1, saturation: 0.02).rgb
    case .light: painted.adjusted(lightness: 0.3, saturation: 0.04).rgb
    case .dark: painted.adjusted(lightness: -0.22, saturation: 0.08).rgb
    case .halo: painted.adjusted(lightness: 0.2, saturation: 0).rgb
    }
  }
}

/// A colour as hue, saturation, lightness (each 0…1), for the package's
/// lighten-and-saturate tweaks.
public struct HSL: Equatable, Sendable {
  public var h: Double
  public var s: Double
  public var l: Double

  public init(_ rgb: UInt32) {
    let r = Double(rgb >> 16 & 0xFF) / 255, g = Double(rgb >> 8 & 0xFF) / 255, b = Double(rgb & 0xFF) / 255
    let high = max(r, g, b), low = min(r, g, b)
    l = (high + low) / 2
    guard high != low else { (h, s) = (0, 0); return }
    let d = high - low
    s = l > 0.5 ? d / (2 - high - low) : d / (high + low)
    h = switch high {
    case r: ((g - b) / d + (g < b ? 6 : 0)) / 6
    case g: ((b - r) / d + 2) / 6
    default: ((r - g) / d + 4) / 6
    }
  }

  /// Lighter (or darker) by `lightness`, more saturated by `saturation`, and a
  /// darkening also saturates by a quarter of itself, as the package does.
  public func adjusted(lightness: Double, saturation: Double) -> HSL {
    var out = self
    out.s = min(1, max(0, s + saturation + (lightness < 0 ? -lightness * 0.25 : 0)))
    out.l = min(1, max(0, l + lightness))
    return out
  }

  public var rgb: UInt32 {
    let channel = { (value: Double) in UInt32(min(255, max(0, (value * 255).rounded()))) }
    guard s > 0 else { let v = channel(l); return v << 16 | v << 8 | v }
    let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
    let hue = { (t: Double) -> Double in
      let t = (t.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
      return t < 1.0 / 6 ? p + (q - p) * 6 * t : t < 0.5 ? q : t < 2.0 / 3 ? p + (q - p) * (2.0 / 3 - t) * 6 : p
    }
    return channel(hue(h + 1.0 / 3)) << 16 | channel(hue(h)) << 8 | channel(hue(h - 1.0 / 3))
  }
}

import Foundation
import IslandCore
import Testing

// The rig's motion, ported from `bot-avatars`' `BotAvatarSim`.

@Suite struct BotMotionTests {
  private let seed = 0.47

  /// Pose samples every 10 ms over `seconds`.
  private func poses(_ state: AvatarState, style: BotPose.Style, seconds: Double) -> [(t: Double, pose: BotPose)] {
    stride(from: 0.0, to: seconds, by: 0.01).map { ($0, BotPose.at(1_000 + $0, state: state, seed: seed, style: style)) }
  }

  private let degree = Double.pi / 180

  /// Moments where `rises` turns true after being false.
  private func onsets(_ samples: [(t: Double, pose: BotPose)], _ rises: (BotPose) -> Bool) -> [Double] {
    var out: [Double] = []
    var was = true
    for (t, pose) in samples {
      let now = rises(pose)
      if now && !was { out.append(t) }
      was = now
    }
    return out
  }

  @Test func `the package's defaults`() {
    let style = BotPose.Style()
    #expect(style.turn == 1 && style.speed == 1)
    #expect(style.jumpEvery == 8 && style.jumpHeight == 26 && style.jumpSquash == 1.15 && style.jumpSpin == 1)
    #expect(style.whirl == 0)
  }

  @Test func `a pose is a function of the clock`() {
    for state in [AvatarState.idle, .working, .sleeping] {
      for t in [0.0, 12.3, 8e8 + 0.5] {
        #expect(BotPose.at(t, state: state, seed: seed) == BotPose.at(t, state: state, seed: seed))
      }
    }
  }

  @Test func `nothing jumps between frames, epoch boundaries included`() {
    // Rig time is time + seed · 10; the stretches are 24 s long.
    let edge = 24.0 * 50 - seed * 10
    var previous = BotPose.at(edge - 1, state: .idle, seed: seed, style: BotPose.Style(jumpEvery: 0))
    for t in stride(from: edge - 1, to: edge + 1, by: 1.0 / 120) {
      let pose = BotPose.at(t, state: .idle, seed: seed, style: BotPose.Style(jumpEvery: 0))
      #expect(abs(pose.yaw - previous.yaw) < 0.05)
      #expect(abs(pose.pitch - previous.pitch) < 0.05)
      #expect(abs(pose.y - previous.y) < 0.5)
      previous = pose
    }
  }

  @Test func `idle, the head looks from corner to corner`() {
    let samples = poses(.idle, style: BotPose.Style(jumpEvery: 0), seconds: 300)
    let yaws = samples.map(\.pose.yaw), pitches = samples.map(\.pose.pitch)
    // Out to 35° · (0.84…1) either side, 14° up and down.
    #expect(yaws.max()! > 28 * degree && yaws.max()! < 37 * degree)
    #expect(yaws.min()! < -28 * degree && yaws.min()! > -37 * degree)
    #expect(pitches.max()! > 11 * degree && pitches.min()! < -11 * degree)
    // A look every 2.6–4.4 s, most of them across: ~85 looks, most crossing the middle.
    let crossings = onsets(samples) { $0.yaw > 0 }.count + onsets(samples) { $0.yaw < 0 }.count
    #expect((40...90).contains(crossings))
    // The roll goes with the turn, 3.2° at most.
    #expect(samples.allSatisfy { abs($0.pose.tilt) < 3.6 })
    #expect(samples.contains { abs($0.pose.tilt) > 2.6 })
    // A breath and a bob: up and down by 2.
    #expect(samples.map(\.pose.y).min()! < -1.9 && samples.map(\.pose.y).max()! > 1.9)
  }

  @Test func `turn scales the look to the side, not the nod`() {
    let still = poses(.idle, style: BotPose.Style(turn: 0, jumpEvery: 0), seconds: 60)
    #expect(still.allSatisfy { abs($0.pose.yaw) < 1e-9 && abs($0.pose.tilt) < 1e-9 })
    #expect(still.contains { abs($0.pose.pitch) > 10 * degree })
    let far = poses(.idle, style: BotPose.Style(turn: 1.6, jumpEvery: 0), seconds: 120)
    #expect(far.map { abs($0.pose.yaw) }.max()! > 1.6 * 30 * degree)
  }

  @Test func `the eyes dart, lead the turn, and blink every few seconds, sometimes twice`() {
    let samples = poses(.idle, style: BotPose.Style(jumpEvery: 0), seconds: 600)
    let blinks = onsets(samples) { $0.blink > 0 }
    // 2.2–4.8 s apart, a second 0.28 s on 22 % of the time: ~200 in 10 min.
    #expect((150...250).contains(blinks.count))
    let gaps = zip(blinks.dropFirst(), blinks).map { $0 - $1 }
    let doubles = gaps.filter { abs($0 - 0.28) < 0.02 }.count
    #expect(doubles > 15 && doubles < 60)
    #expect(gaps.allSatisfy { abs($0 - 0.28) < 0.02 || ($0 > 2.1 && $0 < 9.7) })
    // Each blink is 0.17 s: shut at the middle.
    #expect(samples.map(\.pose.blink).max()! > 0.99)
    #expect(samples.allSatisfy { abs($0.pose.lookX) < 3.6 + 4 + 2.2 + 0.01 })
    #expect(samples.contains { abs($0.pose.lookX) > 5 })
  }

  @Test func `an idle bot flips about every jumpEvery seconds, give or take`() {
    let every = 2.4
    let samples = poses(.idle, style: BotPose.Style(jumpEvery: every), seconds: 240)
    let starts = onsets(samples) { $0.y < -10 }
    // 240 s at 2.4 s is about a hundred jumps.
    #expect((90...110).contains(starts.count))
    for gap in zip(starts.dropFirst(), starts).map({ $0 - $1 }) {
      #expect(gap > every * 0.6 && gap < every * 1.4)
    }
    // By default, one about every 8 s.
    let defaults = onsets(poses(.idle, style: BotPose.Style(), seconds: 240)) { $0.y < -10 }
    #expect((25...35).contains(defaults.count))
  }

  @Test func `the flip leaps the package's height, turns right round and smiles`() {
    let samples = poses(.idle, style: BotPose.Style(turn: 0, whirl: 1, jumpEvery: 2.4), seconds: 30)
    let highest = samples.map(\.pose.y).min() ?? 0
    #expect(abs(highest + 26) < 2.5)
    let yaws = samples.map(\.pose.yaw)
    #expect((yaws.max() ?? 0) > 2 * .pi - 0.05)
    #expect(yaws.allSatisfy { $0 >= 0 && $0 <= 2 * .pi + 1e-9 })
    #expect((samples.map(\.pose.whirl).max() ?? 0) > 0.99)
    #expect((samples.map(\.pose.laugh).max() ?? 0) > 0.99)
  }

  @Test func `without the ring an idle flip still spins but shows none`() {
    let samples = poses(.idle, style: BotPose.Style(turn: 0, jumpEvery: 2.4), seconds: 30)
    #expect(samples.contains { $0.pose.yaw > 1 })
    #expect(samples.allSatisfy { $0.pose.whirl == 0 })
    // No spin, no turn.
    let flat = poses(.idle, style: BotPose.Style(turn: 0, jumpSpin: 0, jumpEvery: 2.4), seconds: 30)
    #expect(flat.allSatisfy { $0.pose.yaw == 0 })
  }

  @Test func `working, a hop every 0.68 s, every third higher and right round`() {
    let samples = poses(.working, style: BotPose.Style(whirl: 1), seconds: 0.68 * 30)
    let hops = onsets(samples) { $0.y < -8 }
    #expect((29...31).contains(hops.count))
    let spins = onsets(samples) { $0.yaw > .pi }
    #expect((9...11).contains(spins.count))
    // 18 up, 26 on the spinning hop (a bob of 2 either way).
    let ys = samples.map(\.pose.y)
    #expect(ys.min()! < -26 && ys.min()! > -28.5)
    #expect(samples.allSatisfy { $0.pose.whirl <= 1 })
    #expect(samples.contains { $0.pose.whirl > 0.99 })
    // Leaning left, then right, 6° at the top of each hop.
    #expect(samples.contains { $0.pose.tilt > 5 } && samples.contains { $0.pose.tilt < -5 })
  }

  @Test func `working, a laugh now and then between the spins`() {
    let samples = poses(.working, style: BotPose.Style(), seconds: 120)
    let laughs = onsets(samples) { $0.laugh > 0.9 && abs($0.yaw) < 0.5 }
    // A 0.6–1.1 s laugh every 1.6–3.8 s, besides the ones on a spin.
    #expect(laughs.count > 25)
  }

  @Test func `asleep, the head hangs, breathes slowly and nods now and then`() {
    let samples = poses(.sleeping, style: BotPose.Style(), seconds: 120)
    #expect(samples.allSatisfy { $0.pose.sleeping == 1 && $0.pose.blink == 0 && $0.pose.asleep })
    let pitches = samples.map(\.pose.pitch)
    #expect(pitches.max()! < -12 * degree)
    // A nod of 13° more every 4–8 s: ~20 in two minutes.
    let nods = onsets(samples) { $0.pitch < -26 * degree }
    #expect((12...30).contains(nods.count))
    #expect(pitches.min()! > -33 * degree)
  }

  @Test func `a change of state cross-fades`() {
    let at = 1_000.0
    let change = BotPose.Change(from: .working, at: at)
    let pose = { (t: Double) in BotPose.at(t, state: .idle, seed: self.seed, style: BotPose.Style(jumpEvery: 0), change: change) }
    #expect(pose(at).working == 1)
    #expect(pose(at + 0.6).working > 0.3 && pose(at + 0.6).working < 0.7)
    #expect(pose(at + 1.2).working == 0)
    // The hop under way lands and settles; no more after it.
    #expect((0..<100).allSatisfy { pose(at + 1.2 + Double($0) * 0.05).y > -3 })
    // Into sleep over 1.4 s, out of it over 1.
    let dozing = BotPose.at(at + 0.7, state: .sleeping, seed: seed, change: BotPose.Change(from: .idle, at: at))
    #expect(abs(dozing.sleeping - 0.5) < 0.01)
    let waking = BotPose.at(at + 0.5, state: .idle, seed: seed, change: BotPose.Change(from: .sleeping, at: at))
    #expect(abs(waking.sleeping - 0.5) < 0.01)
  }

  @Test func `speed runs the clock faster`() {
    let hops = { (speed: Double) in
      self.onsets(self.poses(.working, style: BotPose.Style(speed: speed), seconds: 20.4)) { $0.y < -8 }.count
    }
    #expect(abs(hops(2) - 2 * hops(1)) <= 2)
  }

  @Test func `held still, each state rests on its own pose`() {
    let asleep = BotPose.rest(.sleeping)
    #expect(abs(asleep.pitch + 16 * degree) < 1e-9 && asleep.tilt == 6 && asleep.y == 3 && asleep.lookY == 1)
    #expect(BotPose.rest(.working).working == 1)
    #expect(BotPose.rest(.idle) == BotPose())
    #expect(BotPose.rest(.idle, eyesShut: true).asleep)
  }

  @Test func `the eyes go round the head as it turns`() {
    var pose = BotPose()
    let ahead = BotEye.eyes(for: pose)
    #expect(ahead.count == 2)
    #expect(abs(ahead[0].x + 12.5) < 0.01 && abs(ahead[1].x - 12.5) < 0.01)
    // Open: a pill 12.6 wide.
    #expect(abs(ahead[0].stroke - 12.6) < 1e-9 && ahead[0].halfWidth < 0.02)
    pose.yaw = 0.6
    let turned = BotEye.eyes(for: pose)
    #expect(turned[0].x > -12.5 + 10 && turned[1].scaleX < 0.9)
    pose.yaw = .pi
    #expect(BotEye.eyes(for: pose).isEmpty)
    pose.yaw = 0
    pose.blink = 1
    #expect(abs(BotEye.eyes(for: pose)[0].halfWidth - 5.4) < 1e-9)
  }

  @Test func `a still frame drops the spin and the jumps`() {
    let style = BotPose.Style(whirl: 1, jumpHeight: 14, jumpEvery: 2.4).still
    #expect(style.whirl == 0)
    #expect(style.jumpEvery == 0)
    #expect(style.jumpHeight == 14)
  }

  @Test func `the ring splits into a back and a front half`() {
    var pose = BotPose()
    #expect(WhirlRing(pose: pose, style: BotPose.Style(whirl: 1), front: true) == nil)
    pose.whirl = 1
    pose.whirlAngle = 1.3
    let style = BotPose.Style(whirl: 1)
    let back = WhirlRing(pose: pose, style: style, front: false)!
    let front = WhirlRing(pose: pose, style: style, front: true)!
    #expect(back.radiusX == 57)
    #expect(abs(front.radiusY - 57 * 0.4 * 1.14) < 1e-9)
    #expect(abs(back.radiusY - 57 * 0.4 * 0.86) < 1e-9)
    // 34 segments of five strokes between the halves, plus a shadow under each front one.
    let backSegments = back.arcs.count / 5
    let frontShadows = front.arcs.filter { $0.tone == .shadow }.count
    #expect(back.arcs.allSatisfy { $0.tone != .shadow })
    #expect(backSegments + frontShadows == 34)
    #expect(front.arcs.count == frontShadows * 6)
    // Thick at the leading edge, thin at the tail.
    let bases = (back.arcs + front.arcs).filter { $0.tone == .base }.sorted { $0.start < $1.start }
    #expect(bases.first!.width / (0.6 + 0.4 * sin((bases.first!.start + bases.first!.end) / 2)) > 9)
  }

  @Test func `colours round-trip and adjust as the package does`() {
    for rgb: UInt32 in [0x35B8FF, 0xFFD32B, 0x9BE85A, 0x000000, 0xFFFFFF, 0x808080] {
      #expect(HSL(rgb).rgb == rgb)
    }
    let star = HSL(0xFFD32B)
    let darker = star.adjusted(lightness: -0.2, saturation: 0)
    #expect(abs(darker.l - (star.l - 0.2)) < 1e-9)
    #expect(darker.s == min(1, star.s + 0.05))
    #expect(WhirlRing.color(.shine, for: 0xFFD32B) == 0xFFFFFF)
  }
}

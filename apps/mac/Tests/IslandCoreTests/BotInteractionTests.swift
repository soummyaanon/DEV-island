import Foundation
import IslandCore
import Testing

// The package's `interactive` avatar: the head and eyes follow a pointer
// nearby, and a click makes the robot hop and turn round.

@Suite struct BotInteractionTests {
  private let seed = 0.47
  private let degree = Double.pi / 180

  // MARK: Pointer

  @Test func `the pointer's pull: full within a head width, gone past three`() {
    let near = BotAttention.Target(dx: 0.5, dy: -0.25)
    #expect(near.strength == 1 && near.x == 0.5 && near.y == -0.25)
    // Two widths out: half strength, the direction scaled back to one width.
    let mid = BotAttention.Target(dx: 2, dy: 0)
    #expect(abs(mid.strength - 0.5) < 1e-12 && abs(mid.x - 1) < 1e-12)
    let far = BotAttention.Target(dx: 0, dy: 3.2)
    #expect(far.strength == 0)
    // Clamped as `setPointer` clamps.
    let wild = BotAttention.Target(x: 3, y: -3, strength: 4)
    #expect(wild.x == 1.2 && wild.y == -1.2 && wild.strength == 1)
  }

  @Test func `it eases after the pointer at the rig's rates, a frame at most 0.05 s`() {
    var a = BotAttention()
    a.aim(BotAttention.Target(dx: 1, dy: 0))
    a.advance(by: 0.05)
    #expect(abs(a.strength - (1 - exp(-8 * 0.05))) < 1e-12)
    #expect(abs(a.x - (1 - exp(-14 * 0.05))) < 1e-12)
    var long = BotAttention()
    long.aim(BotAttention.Target(dx: 1, dy: 0))
    long.advance(by: 1)
    #expect(long == a)
    // Held there, the head settles on 22° across, eyes and all.
    for _ in 0 ..< 400 { a.advance(by: 1.0 / 30) }
    #expect(abs(a.strength - 1) < 1e-6 && abs(a.yaw - 22 * degree) < 1e-6 && abs(a.yawSpeed) < 1e-4)
  }

  @Test func `let go, it eases back and comes to rest`() {
    var a = BotAttention()
    a.aim(BotAttention.Target(dx: -0.6, dy: 0.4))
    for _ in 0 ..< 60 { a.advance(by: 1.0 / 30) }
    #expect(!a.atRest)
    a.aim(nil)
    for _ in 0 ..< 300 { a.advance(by: 1.0 / 30) }
    #expect(a.atRest)
    #expect(a == BotAttention())
  }

  @Test func `nothing near, the pose is the same as without a pointer`() {
    for state in [AvatarState.idle, .working, .sleeping] {
      for t in stride(from: 5_000.0, to: 5_030, by: 0.73) {
        #expect(BotPose.at(t, state: state, seed: seed, attention: BotAttention()) == BotPose.at(t, state: state, seed: seed))
      }
    }
  }

  @Test func `the head and eyes turn to the pointer`() {
    func held(_ dx: Double, _ dy: Double) -> BotAttention {
      var a = BotAttention()
      a.aim(BotAttention.Target(dx: dx, dy: dy))
      for _ in 0 ..< 300 { a.advance(by: 1.0 / 30) }
      return a
    }
    let style = BotPose.Style(jumpEvery: 0)
    for t in stride(from: 9_000.0, to: 9_060, by: 1.3) {
      let right = BotPose.at(t, state: .idle, seed: seed, style: style, attention: held(0.8, 0))
      let left = BotPose.at(t, state: .idle, seed: seed, style: style, attention: held(-0.8, 0))
      let below = BotPose.at(t, state: .idle, seed: seed, style: style, attention: held(0, 0.8))
      // A quarter of its own wandering left; 22° · 0.8 toward the pointer.
      #expect(right.yaw > left.yaw + 2 * 22 * degree * 0.8 - 2 * 0.25 * 35 * degree - 0.05)
      #expect(abs(right.yaw - 22 * degree * 0.8) <= 0.25 * 35 * degree + 0.02)
      // Down: the face tips down, the eyes look down.
      #expect(abs(below.pitch - (-12 * degree * 0.8)) <= 0.25 * 14 * degree + 1e-6)
      #expect(right.lookX - left.lookX > 2 * 4.5 * 0.8 - 2 * 0.25 * (3.6 + 4) - 2 * 2.2)
    }
  }

  // MARK: Click

  private let clickDuration = 0.24 + 0.68 + 2.0 / 7 * 0.24 + 0.11 + 0.33 + 0.05

  @Test func `a click's jump: crouch, leap with a full turn, land, settle`() {
    #expect(abs(Jump.duration(poked: true) - clickDuration) < 1e-12)
    #expect(Jump.clickSquashTime == 0.24)
    let style = BotPose.Style(jumpEvery: 0)
    let click = 7_000.0
    let at = { (dt: Double) in BotPose.at(click + dt, state: .idle, seed: self.seed, style: style, poke: click) }
    let plain = { (dt: Double) in BotPose.at(click + dt, state: .idle, seed: self.seed, style: style) }
    // The crouch: squashed down, still on the ground.
    let crouched = at(0.2), before = plain(0.2)
    #expect(crouched.scaleY < before.scaleY - 0.05 && crouched.scaleX > before.scaleX)
    #expect(abs(crouched.y - before.y) < 1e-9)
    // Top of the leap, half way round.
    let top = at(0.24 + 0.34)
    #expect(top.y < plain(0.58).y - 25)
    #expect(abs(top.yaw - plain(0.58).yaw - .pi) < 1e-9)
    // Landed and settled: as if it never happened.
    #expect(at(clickDuration + 0.01) == plain(clickDuration + 0.01))
    #expect(abs(at(0.24 + 0.68).yaw - plain(0.92).yaw - 2 * .pi) < 1e-9)
  }

  @Test func `a click works in any state`() {
    let click = 7_100.0
    for state in [AvatarState.working, .sleeping] {
      let clicked = BotPose.at(click + 0.58, state: state, seed: seed, poke: click)
      let plain = BotPose.at(click + 0.58, state: state, seed: seed)
      #expect(clicked.y < plain.y - 25)
    }
  }

  @Test func `a click during a jump less than 0.6 through is ignored`() {
    let style = BotPose.Style(jumpEvery: 0)
    let first = 8_000.0
    #expect(BotPose.poke(at: first, state: .idle, seed: seed, style: style, last: nil) == first)
    let early = first + 0.5 * clickDuration
    #expect(BotPose.poke(at: early, state: .idle, seed: seed, style: style, last: first) == first)
    let late = first + 0.7 * clickDuration
    #expect(BotPose.poke(at: late, state: .idle, seed: seed, style: style, last: first) == late)
    #expect(BotPose.poke(at: first + 5, state: .idle, seed: seed, style: style, last: first) == first + 5)
  }

  @Test func `an idle flip under way takes a click only past 0.6, and none starts during one`() {
    let style = BotPose.Style()
    // Find an unprompted flip: the first moment the bot leaves the ground by 20.
    var start = 20_000.0
    let calm = BotPose.Style(jumpEvery: 0)
    while BotPose.at(start, state: .idle, seed: seed, style: style).y > BotPose.at(start, state: .idle, seed: seed, style: calm).y - 20 {
      start += 0.01
    }
    #expect(BotPose.poke(at: start, state: .idle, seed: seed, style: style, last: nil) == nil)
    // A click just before that flip's take-off: it's the click's jump that plays, not the flip.
    let click = start - 0.3
    #expect(BotPose.poke(at: click - 2, state: .idle, seed: seed, style: calm, last: nil) != nil)
    let withClick = BotPose.at(start + 0.5, state: .idle, seed: seed, style: style, poke: click)
    let onlyClick = BotPose.at(start + 0.5, state: .idle, seed: seed, style: calm, poke: click)
    #expect(abs(withClick.yaw - onlyClick.yaw) < 1e-9 && abs(withClick.y - onlyClick.y) < 1e-9)
  }

  // MARK: The code review's leans

  @Test func `the crew's leans ease in over 0.35 s`() {
    // Before the game, straight; the reviewer turns to the writer from the start.
    #expect(CodeReview.easedLean(1, at: -1) == 0)
    #expect(CodeReview.easedLean(1, at: 0.4) == -7)
    let partway = CodeReview.easedLean(1, at: 0.1)
    #expect(partway < 0 && partway > -7)
    // The writer turns to the reviewer at 2.6 s: half way at half time, there by 0.35 s.
    #expect(CodeReview.easedLean(0, at: 2.59) == 0)
    #expect(abs(CodeReview.easedLean(0, at: 2.6 + 0.175) - 3.5) < 0.2)
    #expect(CodeReview.easedLean(0, at: 2.6 + 0.36) == 7)
    // Held, it's what the scene says.
    for t in [1.0, 2.2, 5.9, 8, 9.6] {
      for i in 0 ..< 3 { #expect(abs(CodeReview.easedLean(i, at: t + 20) - CodeReview(at: t).leans[i]) < 1e-12) }
    }
  }
}

import IslandCore
import Testing

// Ported from 1.x's `renderer/gesture.test.ts` (milliseconds → seconds).

@Suite struct WheelGestureTests {
  @Test func `fires down once the window's sum crosses the threshold`() {
    var g = WheelGesture(threshold: 28)
    #expect(g.feed(10, at: 0) == nil)
    #expect(g.feed(10, at: 0.020) == nil)
    #expect(g.feed(10, at: 0.040) == .down)
  }

  @Test func `fires up for negative deltas`() {
    var g = WheelGesture(threshold: 28)
    _ = g.feed(-15, at: 0)
    #expect(g.feed(-15, at: 0.010) == .up)
  }

  @Test func `forgets deltas older than the window`() {
    var g = WheelGesture(window: 0.160, threshold: 28)
    _ = g.feed(20, at: 0)
    #expect(g.feed(10, at: 0.500) == nil)
  }

  @Test func `locks out further decisions after firing`() {
    var g = WheelGesture(threshold: 28, lock: 0.250)
    #expect(g.feed(30, at: 0) == .down)
    #expect(g.feed(30, at: 0.100) == nil)
    #expect(g.feed(30, at: 0.249) == nil)
    #expect(g.feed(30, at: 0.251) == .down)
  }

  @Test func `reports progress toward the threshold, clamped`() {
    var g = WheelGesture(threshold: 40)
    _ = g.feed(10, at: 0)
    #expect(abs(g.progress(at: 0) - 0.25) < 1e-9)
    _ = g.feed(-30, at: 0.005)
    #expect(abs(g.progress(at: 0.005) - -0.5) < 1e-9)
    _ = g.feed(-100, at: 0.006)
    #expect(g.progress(at: 0.006) == 0)
  }

  @Test func `progress decays to 0 once the window expires`() {
    var g = WheelGesture(window: 0.160, threshold: 40)
    _ = g.feed(20, at: 0)
    #expect(g.progress(at: 1) == 0)
  }

  @Test func `reset clears everything including the lock`() {
    var g = WheelGesture(threshold: 28, lock: 0.250)
    _ = g.feed(30, at: 0)
    g.reset()
    #expect(g.feed(30, at: 0.001) == .down)
  }

  @Test func `with natural scrolling, content moving down means the fingers moved down`() {
    #expect(WheelGesture.fingerDelta(scrollingDeltaY: 12, invertedFromDevice: true) == 12)
  }

  @Test func `without natural scrolling, content and fingers move opposite ways`() {
    #expect(WheelGesture.fingerDelta(scrollingDeltaY: 12, invertedFromDevice: false) == -12)
  }
}

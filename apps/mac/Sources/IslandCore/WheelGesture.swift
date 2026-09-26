import Foundation

/// Two-finger swipe detection from scroll-wheel events, ported from 1.x's
/// `gesture.ts`.
///
/// Trackpad scrolls arrive as a stream of small deltas. This sums them over a
/// short sliding window, fires once the sum crosses a threshold, then locks
/// briefly so the tail of the same swipe can't fire twice.
///
/// Direction is FINGER motion (down = fingers moved down), never the raw
/// scroll sign: natural scrolling inverts the two, and the island's gestures
/// must mean the same thing on every Mac.
public struct WheelGesture: Sendable {
  public enum Direction: Sendable {
    case down, up
  }

  /// Deltas older than this (seconds) no longer count.
  public var window: TimeInterval
  /// Summed finger travel (pt) that counts as a swipe.
  public var threshold: Double
  /// Quiet period (seconds) after firing, during which nothing else fires.
  public var lock: TimeInterval

  private var samples: [(time: TimeInterval, dy: Double)] = []
  private var lockedUntil = -TimeInterval.infinity

  public init(window: TimeInterval = 0.160, threshold: Double = 28, lock: TimeInterval = 0.250) {
    self.window = window
    self.threshold = threshold
    self.lock = lock
  }

  /// Feeds one event's finger delta. Returns a decision at most once per swipe.
  public mutating func feed(_ fingerDy: Double, at now: TimeInterval) -> Direction? {
    guard now >= lockedUntil else { return nil }
    prune(now)
    samples.append((now, fingerDy))
    let sum = self.sum
    guard abs(sum) >= threshold else { return nil }
    samples.removeAll()
    lockedUntil = now + lock
    return sum > 0 ? .down : .up
  }

  /// How far toward a decision the current swipe is, −1…1. Positive is down.
  public mutating func progress(at now: TimeInterval) -> Double {
    guard now >= lockedUntil else { return 0 }
    prune(now)
    return min(1, max(-1, sum / threshold))
  }

  public mutating func reset() {
    samples.removeAll()
    lockedUntil = -.infinity
  }

  private mutating func prune(_ now: TimeInterval) {
    let cutoff = now - window
    samples.removeAll { $0.time < cutoff }
  }

  private var sum: Double { samples.reduce(0) { $0 + $1.dy } }

  /// Finger travel from an AppKit scroll event. `scrollingDeltaY` follows the
  /// content: positive moves it down. Natural scrolling (the macOS default,
  /// `isDirectionInvertedFromDevice`) moves content WITH the fingers; the
  /// classic setting moves it against them.
  public static func fingerDelta(scrollingDeltaY: Double, invertedFromDevice: Bool) -> Double {
    invertedFromDevice ? scrollingDeltaY : -scrollingDeltaY
  }
}

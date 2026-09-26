import IslandCore
import Testing

// The field glow's motion against border-beam 1.4.1's own keyframes and oscillators.

@Suite struct BeamLine {
  @Test func `starts at the left end, invisible`() {
    let start = BeamMotion.line(at: 0)
    #expect(abs(start.x - 0.06) < 1e-9)
    #expect(start.w == 0.5)
    #expect(start.edge == 0)
    #expect(start.h == 0.8)
    #expect(start.spike == 0.8)
    #expect(start.spike2 == 1.2)
  }

  @Test func `is widest and fully lit mid-travel`() {
    let mid = BeamMotion.line(at: 3.1 / 2)
    #expect(abs(mid.x - 0.5) < 1e-9)
    #expect(abs(mid.w - 1.5) < 1e-9)
    #expect(mid.edge == 1)
  }

  @Test func `fades in between 12.5% and 32.5% of the trip`() {
    #expect(abs(BeamMotion.line(at: 3.1 * 0.225).edge - 0.5) < 1e-9)
  }

  @Test func `breathes with ease-in-out between keyframes`() {
    // Halfway through the first segment, ease-in-out sits at exactly half.
    #expect(abs(BeamMotion.line(at: 4.0 * 0.125).h - (0.8 + 0.45 / 2)) < 1e-6)
    #expect(abs(BeamMotion.line(at: 4.0 * 0.25).h - 1.25) < 1e-9)
  }

  @Test func `loops`() {
    #expect(abs(BeamMotion.line(at: 3.1 * 0.3).x - BeamMotion.line(at: 3.1 * 100.3).x) < 1e-9)
  }
}

@Suite struct BeamPulse {
  @Test func `rests at each oscillator's first value`() {
    let p = BeamMotion.pulse(at: 0)
    #expect(abs(p.w[0] - 0.72) < 1e-9)
    #expect(abs(p.h[2] - 1.21) < 1e-9)
    #expect(abs(p.dx[0] + 33) < 1e-9)
    #expect(abs(p.height - 0.66) < 1e-9)
    #expect(abs(p.tl - 0.52) < 1e-9)
  }

  @Test func `reaches the far value half a period in`() {
    // bw1 runs 0.72 → 1.308 over 2.6 × 0.9 s.
    #expect(abs(BeamMotion.pulse(at: 2.6 * 0.9 / 2).w[0] - 1.308) < 1e-9)
    #expect(abs(BeamMotion.pulse(at: 1.9 / 2).tl - 1) < 1e-9)
  }

  @Test func `staggers the corners`() {
    // Top-right starts 0.28 periods late, so it's still at rest then.
    #expect(abs(BeamMotion.pulse(at: 1.9 * 0.28).tr - 0.52) < 1e-9)
  }
}

@Suite struct Bezier {
  @Test func `ease-in-out is symmetric and pinned at the ends`() {
    let curve = CubicBezier.easeInOutCurve
    #expect(curve.y(at: 0) == 0)
    #expect(curve.y(at: 1) == 1)
    #expect(abs(curve.y(at: 0.5) - 0.5) < 1e-9)
    #expect(abs(curve.y(at: 0.2) + curve.y(at: 0.8) - 1) < 1e-9)
  }
}

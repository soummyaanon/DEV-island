import AppKit
import IslandCore
import os
import SwiftUI

/// Parsed once: the robots' outlines and the agents' marks. The path data is
/// constant and covered by IslandCore's tests, so a parse failure is a bug.
nonisolated enum Shapes {
  /// Immutable once built (CGPath isn't marked Sendable, but is read-only).
  nonisolated(unsafe) static let bots: [BotLook.Kind: (body: CGPath, parts: CGPath?)] = Dictionary(
    uniqueKeysWithValues: BotLook.Kind.allCases.map { kind in
      let look = BotLook(kind)
      // swiftlint:disable:next force_try
      return (kind, (try! SVGPath.parse(look.outline), look.parts.map { try! SVGPath.parse($0) }))
    }
  )

  /// Each mark as one path in its own view box (the OpenAI petal repeated).
  static let marks: [AgentKind: (path: Path, box: CGFloat)] = Dictionary(
    uniqueKeysWithValues: AgentKind.allCases.map { agent in
      let mark = AgentMark.path(agent)
      let combined = CGMutablePath()
      for data in mark.data {
        let petal = try! SVGPath.parse(data)
        for degrees in mark.turns {
          let centre = mark.box / 2
          let turn = CGAffineTransform(translationX: centre, y: centre)
            .rotated(by: degrees * .pi / 180)
            .translatedBy(x: -centre, y: -centre)
          combined.addPath(petal, transform: turn)
        }
      }
      return (agent, (Path(combined), mark.box))
    }
  )
}

extension Color {
  nonisolated init(hex: UInt32, opacity: Double = 1) {
    self.init(
      .sRGB,
      red: Double(hex >> 16 & 0xFF) / 255,
      green: Double(hex >> 8 & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255,
      opacity: opacity
    )
  }
}

/// A robot: a glossy body in its colour, antennae behind, and a face that
/// blinks and looks about. It hops while its agent works and dozes when quiet,
/// cross-fading from one to the next. Interactive (the package's default), its
/// eyes and head follow a pointer nearby and a click makes it hop and turn
/// round; whatever the click lands on still gets it. Frozen on its state's
/// rest pose while paused or with Reduce Motion, and then it neither follows
/// nor hops.
struct BotAvatar: View {
  let look: BotLook
  var state: AvatarState
  var size: CGFloat
  var seed: Double
  var paused = false
  var style = BotPose.Style()
  /// Hide and seek: "it" counts with its eyes shut.
  var eyesShut = false
  var interactive = true

  var body: some View {
    BotStage(
      bots: [StageBot(look: look, state: state, seed: seed, size: size, style: style, eyesShut: eyesShut, box: CGRect(x: 0, y: 0, width: size, height: size))],
      size: CGSize(width: size, height: size), paused: paused, interactive: interactive
    )
  }
}

/// One robot on a stage: who it is, how it moves, and its layout box.
struct StageBot {
  var look: BotLook
  var state: AvatarState
  var seed: Double
  var size: CGFloat
  var style = BotPose.Style()
  var eyesShut = false
  /// Where it sits, in the stage's layout space (it overhangs this by 30 %).
  var box: CGRect
}

/// Several robots (or one) on one clock, drawn in one canvas: a frame is one
/// view update and one draw, however many there are. The canvas overhangs the
/// layout box so a hop isn't clipped, and never takes a click itself.
struct BotStage: View {
  let bots: [StageBot]
  let size: CGSize
  var paused = false
  var interactive = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let motion = State(initialValue: StageMotion())

  var body: some View {
    let still = paused || reduceMotion
    let motion = motion.wrappedValue
    let _ = motion.track(bots, still: still, interactive: interactive, at: Date.now.timeIntervalSinceReferenceDate)
    let pad = (bots.map(\.size).max() ?? 0) * 0.3
    Color.clear
      .frame(width: size.width, height: size.height)
      .overlay {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { timeline in
          let poses = motion.poses(at: timeline.date.timeIntervalSinceReferenceDate, pad: pad)
          Canvas { context, _ in
            for (bot, pose) in zip(bots, poses) {
              BotRenderer.draw(
                bot.look, pose: pose, style: still ? bot.style.still : bot.style, in: context,
                box: bot.box.offsetBy(dx: pad, dy: pad)
              )
            }
          }
        }
        .frame(width: size.width + 2 * pad, height: size.height + 2 * pad)
        .background { if interactive { PointerProbe(motion: motion) } }
        .allowsHitTesting(false)
      }
      .onAppear { if interactive { BotClicks.shared.watch(motion) } }
      .onDisappear { BotClicks.shared.forget(motion) }
      .accessibilityHidden(true)
  }
}

/// What a stage remembers from frame to frame: each robot's last change of
/// state (the pose fades across it), its last click, and the pointer it's
/// following. Plain storage, read and written while drawing, so a frame never
/// invalidates a view.
final class StageMotion {
  private(set) var bots: [StageBot] = []
  private(set) var still = true
  private(set) var interactive = false
  private var states: [Int: AvatarState] = [:]
  private var changes: [Int: BotPose.Change] = [:]
  private var pokes: [Int: TimeInterval] = [:]
  private var attention: [Int: BotAttention] = [:]
  private var lastFrame: TimeInterval?
  /// How far the canvas overhangs the layout box, as last drawn.
  private var pad: CGFloat = 0
  /// The canvas, for where the pointer is.
  weak var probe: NSView?

  /// The robots as the stage now has them; a change of state is timed from now.
  func track(_ bots: [StageBot], still: Bool, interactive: Bool, at now: TimeInterval) {
    self.bots = bots
    self.still = still
    self.interactive = interactive
    for (i, bot) in bots.enumerated() {
      if let old = states[i], old != bot.state { changes[i] = BotPose.Change(from: old, at: now) }
      states[i] = bot.state
    }
    if still || !interactive {
      attention.removeAll()
      pokes.removeAll()
    }
  }

  /// Each robot's pose for the frame at `now`, the pointer followed a step.
  func poses(at now: TimeInterval, pad: CGFloat) -> [BotPose] {
    self.pad = pad
    let dt = lastFrame.map { max(0, now - $0) } ?? 0
    lastFrame = now
    let follows = interactive && !still
    let pointer = follows ? pointerInCanvas() : nil
    return bots.enumerated().map { i, bot in
      if still { return BotPose.rest(bot.state, eyesShut: bot.eyesShut) }
      var aim = attention[i] ?? BotAttention()
      if follows {
        let centre = CGPoint(x: bot.box.midX + pad, y: bot.box.midY + pad)
        aim.aim(pointer.map { BotAttention.Target(dx: ($0.x - centre.x) / bot.size, dy: ($0.y - centre.y) / bot.size) })
        aim.advance(by: dt * max(0, bot.style.speed))
        attention[i] = aim.atRest ? nil : aim
      }
      return BotPose.at(
        now, state: bot.state, seed: bot.seed, style: bot.style, eyesShut: bot.eyesShut, change: changes[i],
        attention: aim, poke: pokes[i]
      )
    }
  }

  /// The robot a click at `point` (canvas space) lands on: its whole canvas,
  /// half as big again as it and raised a tenth, as the package's is; the one
  /// drawn last wins.
  func bot(at point: CGPoint) -> Int? {
    guard interactive, !still else { return nil }
    return bots.indices.last { i in
      let box = bots[i].box.offsetBy(dx: pad, dy: pad)
      let side = box.width * 1.5
      let target = CGRect(x: box.midX - side / 2, y: box.midY - 0.1 * box.width - side / 2, width: side, height: side)
      return target.contains(point)
    }
  }

  /// A click on robot `i`: a hop and a full turn, unless one's well under way.
  func poke(_ i: Int, at now: TimeInterval) {
    guard bots.indices.contains(i), interactive, !still else { return }
    let bot = bots[i]
    pokes[i] = BotPose.poke(at: now, state: bot.state, seed: bot.seed, style: bot.style, change: changes[i], last: pokes[i])
  }

  /// The pointer in the canvas's space, while it's over the canvas's window
  /// (the package lets go when it leaves the page).
  private func pointerInCanvas() -> CGPoint? {
    guard let probe, let window = probe.window, window.isVisible else { return nil }
    let screen = NSEvent.mouseLocation
    guard window.frame.contains(screen) else { return nil }
    return probe.convert(window.convertPoint(fromScreen: screen), from: nil)
  }

  /// Where a mouse event falls on the canvas, if it's in the canvas's window.
  func location(of event: NSEvent) -> CGPoint? {
    guard let probe, let window = probe.window, event.window === window else { return nil }
    return probe.convert(event.locationInWindow, from: nil)
  }
}

/// An empty, flipped view the size of a stage's canvas: how the stage finds
/// the pointer and clicks in its own space. Transparent to clicks.
private struct PointerProbe: NSViewRepresentable {
  let motion: StageMotion

  final class Probe: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }

  func makeNSView(context: Context) -> Probe {
    let view = Probe()
    motion.probe = view
    return view
  }

  func updateNSView(_ view: Probe, context: Context) {
    motion.probe = view
  }
}

/// Clicks on interactive robots, seen on their way to whatever is under them
/// (a row, a button), which still gets them: a press and release on the same
/// robot makes it hop. Only listens while an interactive robot is on screen,
/// and only to presses and releases.
final class BotClicks {
  static let shared = BotClicks()

  private final class Weak {
    weak var motion: StageMotion?
    init(_ motion: StageMotion) { self.motion = motion }
  }

  private var stages: [Weak] = []
  private var monitor: Any?
  private var pressed: (stage: StageMotion, bot: Int)?

  func watch(_ motion: StageMotion) {
    stages.removeAll { $0.motion == nil || $0.motion === motion }
    stages.append(Weak(motion))
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
      MainActor.assumeIsolated { BotClicks.shared.handle(event) }
      return event
    }
  }

  func forget(_ motion: StageMotion) {
    stages.removeAll { $0.motion == nil || $0.motion === motion }
    if pressed?.stage === motion { pressed = nil }
    if stages.isEmpty, let monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
  }

  private func handle(_ event: NSEvent) {
    // The robot under the pointer, the last-watched stage first (it's on top).
    let hit = stages.reversed().lazy.compactMap { entry -> (StageMotion, Int)? in
      guard let stage = entry.motion, let point = stage.location(of: event), let bot = stage.bot(at: point) else { return nil }
      return (stage, bot)
    }.first
    if event.type == .leftMouseDown {
      pressed = hit.map { (stage: $0.0, bot: $0.1) }
    } else {
      defer { pressed = nil }
      guard let pressed, let hit, hit.0 === pressed.stage, hit.1 == pressed.bot else { return }
      pressed.stage.poke(pressed.bot, at: Date.now.timeIntervalSinceReferenceDate)
    }
  }
}

/// Draws a robot with Core Graphics, so the same drawing serves a SwiftUI
/// canvas (through `withCGContext`) and a plain layer-backed view that
/// redraws itself without a SwiftUI update (the resting crew). Coordinates are
/// y-down, as a flipped view and a canvas both have them.
nonisolated enum BotRenderer {
  /// Half the body's depth (the package's 15 · 0.65): how far a turned body's
  /// front and back sit apart sideways.
  private static let depth = 9.75

  static func draw(
    _ look: BotLook, pose: BotPose, style: BotPose.Style = BotPose.Style(),
    in context: inout GraphicsContext, canvas: CGSize, size: CGFloat
  ) {
    context.withCGContext { cg in draw(look, pose: pose, style: style, in: cg, canvas: canvas, size: size) }
  }

  /// A robot whose layout box is `box` in `context`: its drawing overhangs the
  /// box by 30 % each way, as a lone avatar's canvas does.
  static func draw(_ look: BotLook, pose: BotPose, style: BotPose.Style, in context: GraphicsContext, box: CGRect) {
    context.withCGContext { cg in draw(look, pose: pose, style: style, in: cg, box: box) }
  }

  static func draw(_ look: BotLook, pose: BotPose, style: BotPose.Style, in cg: CGContext, box: CGRect) {
    let size = box.width
    cg.saveGState()
    cg.translateBy(x: box.minX - 0.3 * size, y: box.minY - 0.3 * size)
    draw(look, pose: pose, style: style, in: cg, canvas: CGSize(width: size * 1.6, height: size * 1.6), size: size)
    cg.restoreGState()
  }

  static func draw(_ look: BotLook, pose: BotPose, style: BotPose.Style, in cg: CGContext, canvas: CGSize, size: CGFloat) {
    guard let shapes = Shapes.bots[look.kind] else { return }
    cg.saveGState()
    defer { cg.restoreGState() }
    // 100 design units fill the avatar's box; the body sits a little low so a
    // hop has room above it.
    let unit = size / 100
    cg.translateBy(x: (canvas.width - size) / 2, y: (canvas.height - size) / 2 + size * 0.04)
    cg.scaleBy(x: unit, y: unit)
    // Turn about the middle, squash and stretch from the feet, hop.
    cg.translateBy(x: 50, y: 50 + pose.y)
    cg.rotate(by: pose.tilt * .pi / 180)
    cg.translateBy(x: 0, y: 50 * (1 - pose.scaleY))
    cg.scaleBy(x: pose.scaleX, y: pose.scaleY)
    cg.translateBy(x: -50, y: -50)
    let unturned = cg.ctm

    // The ring's far half goes behind everything.
    drawWhirl(look, pose: pose, style: style, front: false, in: cg)

    // A turn narrows the body (never thinner than 0.22 of it) and slides its
    // near face across; a nod shortens it and slides the face up or down. The
    // depth between shows as darker slices behind, as the package lays them.
    let (cosYaw, sinYaw) = (cos(pose.yaw), sin(pose.yaw))
    let (cosPitch, sinPitch) = (cos(pose.pitch), sin(pose.pitch))
    let facing = cosYaw * cosPitch
    let edge = { (v: Double) in abs(v) < 0.22 ? (v < 0 ? -0.22 : 0.22) : v }
    let (wide, tall) = (edge(cosYaw), edge(cosPitch))
    let front = facing >= 0 ? 1.0 : -1.0
    // The slice `st` of the way from the middle to the front (−1 the back), `reach` deep.
    let slice = { (st: Double, reach: Double) -> CGAffineTransform in
      let z = st * depth * reach
      return CGAffineTransform(
        a: wide, b: sinYaw * sinPitch, c: 0, d: tall,
        tx: 50 - 50 * wide + z * sinYaw,
        ty: 50 - 50 * sinYaw * sinPitch - 50 * tall - z * wide * sinPitch
      )
    }
    let fill = { (path: CGPath, transform: CGAffineTransform, color: CGColor) in
      cg.saveGState()
      cg.concatenate(transform)
      cg.addPath(path)
      cg.setFillColor(color)
      cg.fillPath()
      cg.restoreGState()
    }
    if max(abs(sinYaw), abs(wide * sinPitch)) * depth > 0.01 {
      let tones = Tones.of(look.color).slices
      for (path, reach) in [(shapes.parts, 0.4), (shapes.body, 1.0)] {
        guard let path else { continue }
        for i in 0..<tones.count {
          let f = Double(i) / Double(tones.count)
          fill(path, slice(front * (2 * f - 1), reach), tones[i])
        }
      }
    }

    if let parts = shapes.parts {
      fill(parts, slice(front, 0.4), Tones.of(look.color).parts)
    }
    cg.saveGState()
    cg.concatenate(slice(front, 1))
    let body = shapes.body
    cg.addPath(body)
    cg.setFillColor(Tones.of(look.color).body)
    cg.fillPath()
    // Gloss: a sheen from above, shade underneath, and a soft highlight.
    cg.addPath(body)
    cg.clip()
    cg.drawLinearGradient(
      Gloss.sheen, start: CGPoint(x: 50, y: 5), end: CGPoint(x: 50, y: 95),
      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    cg.saveGState()
    cg.addEllipse(in: CGRect(x: 18, y: 12, width: 44, height: 30))
    cg.clip()
    let spot = CGPoint(x: 38, y: 24)
    cg.drawRadialGradient(Gloss.highlight, startCenter: spot, startRadius: 0, endCenter: spot, endRadius: 24, options: [.drawsAfterEndLocation])
    cg.restoreGState()

    // The face shows until the bot has turned well past side-on: clipped to
    // the near face, its eyes going round the head as it turns and nods.
    if facing > -0.2 {
      cg.saveGState()
      cg.concatenate(unturned.concatenating(cg.ctm.inverted()))
      drawFace(look, pose: pose, in: cg)
      cg.restoreGState()
    }
    cg.restoreGState()
    drawWhirl(look, pose: pose, style: style, front: true, in: cg)
  }

  /// A robot colour's fills, worked out once: the body, the parts, and the
  /// slices of its depth from the far side (darker, a touch more saturated,
  /// blended in hue, saturation and lightness as the package blends them) to
  /// its own colour.
  private struct Tones {
    var body: CGColor
    var parts: CGColor
    var slices: [CGColor]

    private static let cache = OSAllocatedUnfairLock(initialState: [UInt32: Tones]())

    static func of(_ color: UInt32) -> Tones {
      if let tones = cache.withLock({ $0[color] }) { return tones }
      let far = HSL(color).adjusted(lightness: -0.105, saturation: 0.0175)
      let count = 8
      let slices = (0..<count).map { i -> CGColor in
        let f = Double(i) / Double(count)
        return cgColor(f >= 0.5 ? color : mix(far.rgb, color, f / 0.5))
      }
      let tones = Tones(body: cgColor(color), parts: cgColor(shaded(color, by: 0.75)), slices: slices)
      cache.withLock { $0[color] = tones }
      return tones
    }
  }

  private enum Gloss {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // Immutable once built.
    nonisolated(unsafe) static let sheen = CGGradient(
      colorsSpace: space,
      colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.32), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
        CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0), CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28),
      ] as CFArray,
      locations: [0, 0.42, 0.6, 1]
    )!
    nonisolated(unsafe) static let highlight = CGGradient(
      colorsSpace: space,
      colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
      locations: [0, 1]
    )!
  }

  static func cgColor(_ hex: UInt32, alpha: Double = 1) -> CGColor {
    CGColor(
      srgbRed: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255,
      alpha: alpha
    )
  }

  /// One half of the ring round a spin, about the body's middle, unturned.
  private static func drawWhirl(_ look: BotLook, pose: BotPose, style: BotPose.Style, front: Bool, in cg: CGContext) {
    guard let ring = WhirlRing(pose: pose, style: style, front: front) else { return }
    cg.saveGState()
    defer { cg.restoreGState() }
    cg.translateBy(x: 50, y: 50)
    cg.rotate(by: WhirlRing.lean)
    cg.translateBy(x: 0, y: WhirlRing.drop)
    cg.setLineCap(.butt)
    cg.setLineJoin(.round)
    for arc in ring.arcs where arc.opacity > 0 {
      let steps = 4
      for step in 0...steps {
        let angle = arc.start + (arc.end - arc.start) * Double(step) / Double(steps)
        let point = CGPoint(x: ring.radiusX * cos(angle), y: arc.dy + ring.radiusY * sin(angle))
        if step == 0 { cg.move(to: point) } else { cg.addLine(to: point) }
      }
      cg.setStrokeColor(cgColor(WhirlRing.color(arc.tone, for: look.color), alpha: min(1, arc.opacity)))
      cg.setLineWidth(arc.width)
      cg.strokePath()
    }
  }

  /// Between two colours in hue, saturation and lightness, as the package blends its slices.
  private static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
    var (from, to) = (HSL(a), HSL(b))
    from.h += (to.h - from.h) * t
    from.s += (to.s - from.s) * t
    from.l += (to.l - from.l) * t
    return from.rgb
  }

  /// The colour scaled toward black.
  private static func shaded(_ hex: UInt32, by factor: Double) -> UInt32 {
    let channel = { (shift: UInt32) in UInt32(Double(hex >> shift & 0xFF) * factor) << shift }
    return channel(16) | channel(8) | channel(0)
  }

  /// The package's eyes: tall pills that squeeze to a line, ^ when laughing,
  /// soft arcs asleep, each where the head's turn and nod carry it.
  private static func drawFace(_ look: BotLook, pose: BotPose, in cg: CGContext) {
    let ink = cgColor(look.ink)
    cg.translateBy(x: look.faceX, y: look.faceY)
    cg.scaleBy(x: look.faceScale, y: look.faceScale)
    cg.setStrokeColor(ink)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    for eye in BotEye.eyes(for: pose) {
      cg.saveGState()
      cg.setAlpha(eye.opacity)
      cg.translateBy(x: eye.x, y: eye.y)
      cg.scaleBy(x: eye.scaleX, y: eye.scaleY)
      if eye.halfWidth < 0.5 {
        // An open eye: the curve folds back on itself into a pill, and Core
        // Graphics strokes that fold with spikes, so draw the line it traces
        // (from its ends to the curve's tip, halfway to the control point).
        cg.move(to: CGPoint(x: 0, y: eye.ends))
        cg.addLine(to: CGPoint(x: 0, y: (eye.ends + eye.bend) / 2))
      } else {
        cg.move(to: CGPoint(x: -eye.halfWidth, y: eye.ends))
        cg.addQuadCurve(to: CGPoint(x: eye.halfWidth, y: eye.ends), control: CGPoint(x: 0, y: eye.bend))
      }
      cg.setLineWidth(eye.stroke)
      cg.strokePath()
      cg.restoreGState()
    }
  }
}

/// An agent's own mark (Claude's spark, the OpenAI blossom, Cursor's cube).
struct AgentMarkView: View {
  let agent: AgentKind
  var size: CGFloat = 11
  var color: Color = Palette.text

  var body: some View {
    Canvas { context, canvas in
      guard let mark = Shapes.marks[agent] else { return }
      var ctx = context
      ctx.scaleBy(x: canvas.width / mark.box, y: canvas.height / mark.box)
      ctx.fill(mark.path, with: .color(color))
    }
    .frame(width: size, height: size)
    .accessibilityLabel(agent.displayName)
  }
}


// MARK: - Crews

/// A robot drawn at a pose it's handed, for a crew that runs one clock for
/// all of its robots. Overhangs its box so a hop isn't clipped.
private struct PosedBot: View {
  let look: BotLook
  let pose: BotPose
  let style: BotPose.Style
  let size: CGFloat

  var body: some View {
    Color.clear
      .frame(width: size, height: size)
      .overlay {
        Canvas { context, canvas in
          BotRenderer.draw(look, pose: pose, style: style, in: &context, canvas: canvas, size: size)
        }
        .frame(width: size * 1.6, height: size * 1.6)
        .allowsHitTesting(false)
      }
  }
}

/// The right wing while agents work: a bot per working session, "+n" past
/// three, all on one clock. Not interactive (1.x's `interactive={false}`).
struct WorkCrewView: View {
  let active: [SessionSnapshot]
  let paused: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private static let style = BotPose.Style(jumpHeight: 9, jumpSquash: 0.6, jumpSpin: 0)

  var body: some View {
    let crew = WorkCrew(active)
    let still = paused || reduceMotion
    HStack(spacing: -3) {
      TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { timeline in
        let now = timeline.date.timeIntervalSinceReferenceDate
        HStack(spacing: -3) {
          ForEach(crew.shown) { session in
            PosedBot(
              look: .agent(session.agent),
              pose: still ? BotPose.rest(.working) : BotPose.at(now, state: .working, seed: session.seed, style: Self.style),
              style: still ? Self.style.still : Self.style, size: 14
            )
            // Each bot grows in as it joins; one that leaves just goes.
            .modifier(Entrance(kind: .workBotIn, reducible: false))
            .transition(.identity)
          }
        }
      }
      if crew.more > 0 {
        Text("+\(crew.more)")
          .font(.system(size: 9.5, weight: .bold))
          .foregroundStyle(Palette.textDim)
          .padding(.leading, 5)
      }
    }
    .accessibilityHidden(true)
  }
}

/// The island at rest: three bots in the right wing running a code review
/// (`CodeReview`). While the hello is up they dance on the spot instead. Not
/// interactive (1.x's `interactive={false}`).
///
/// This is what the island shows most of the day, so it skips SwiftUI's
/// per-frame update altogether: one layer-backed view draws the crew and its
/// props with Core Graphics, redrawn by its own 30 fps display link, which
/// stops while the crew is still.
struct IdleCrewView: View {
  let paused: Bool
  var awake = false

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Bot size, and how far apart their centres sit (13 pt, overlapping by 4).
  fileprivate static let size: CGFloat = 13
  fileprivate static let pitch: CGFloat = 9
  fileprivate static let width = size + 2 * pitch
  /// Room round the crew for hops, leans, the sway and the props overhead.
  fileprivate static let pad: CGFloat = 12
  fileprivate static let style = BotPose.Style(turn: 1.6, jumpEvery: 0)

  var body: some View {
    let still = paused || reduceMotion
    let playing = !awake && !still
    let swaying = awake && !still
    Color.clear
      .frame(width: Self.width, height: Self.size)
      .overlay {
        IdleCrewLayer(scene: IdleCrewScene(
          still: still, game: playing ? started.wrappedValue : nil, sway: swaying ? swayStarted.wrappedValue : nil
        ))
        .frame(width: Self.width + 2 * Self.pad, height: Self.size + 2 * Self.pad)
        .allowsHitTesting(false)
      }
      .onChange(of: playing) { _, now in if now { started.wrappedValue = .now } }
      .onChange(of: swaying) { _, now in if now { swayStarted.wrappedValue = .now } }
      .accessibilityHidden(true)
  }

  /// Each game starts from its first round when play begins, and so does the dance.
  private let started = State(initialValue: Date.now)
  private let swayStarted = State(initialValue: Date.now)
}

/// What the resting crew is doing: held still, playing the review since
/// `game`, or dancing the hello since `sway`.
private struct IdleCrewScene: Equatable {
  var still: Bool
  var game: Date?
  var sway: Date?
}

private struct IdleCrewLayer: NSViewRepresentable {
  let scene: IdleCrewScene

  func makeNSView(context: Context) -> IdleCrewNSView {
    let view = IdleCrewNSView()
    view.scene = scene
    return view
  }

  func updateNSView(_ view: IdleCrewNSView, context: Context) {
    view.scene = scene
  }
}

private final class IdleCrewNSView: NSView {
  var scene = IdleCrewScene(still: true) {
    didSet {
      guard scene != oldValue else { return }
      link?.isPaused = scene.still
      needsDisplay = true
    }
  }

  private var link: CADisplayLink?

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layerContentsRedrawPolicy = .onSetNeedsDisplay
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    link?.invalidate()
    link = nil
    guard window != nil else { return }
    let link = displayLink(target: self, selector: #selector(tick))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
    link.isPaused = scene.still
    link.add(to: .main, forMode: .common)
    self.link = link
    needsDisplay = true
  }

  @objc private func tick() { needsDisplay = true }

  override func draw(_ dirtyRect: NSRect) {
    guard let cg = NSGraphicsContext.current?.cgContext else { return }
    let now = Date.now
    cg.translateBy(x: IdleCrewView.pad, y: IdleCrewView.pad)
    IdleCrewPainter.draw(
      in: cg, now: now.timeIntervalSinceReferenceDate, still: scene.still,
      game: scene.game.map { now.timeIntervalSince($0) }, sway: scene.sway.map { now.timeIntervalSince($0) }
    )
  }
}

/// A frame of the resting crew, in its layout space (y down).
@MainActor private enum IdleCrewPainter {
  private static let size = IdleCrewView.size, pitch = IdleCrewView.pitch

  /// The crew, `game` seconds into the review (nil at rest), or `sway`
  /// seconds into the hello's dance; then the props over them.
  static func draw(in cg: CGContext, now: TimeInterval, still: Bool, game: Double?, sway: Double?) {
    let scene = game.map { CodeReview(at: $0) } ?? CodeReview()
    let style = still ? IdleCrewView.style.still : IdleCrewView.style
    for (index, member) in BotLook.crew.enumerated() {
      let box = CGRect(x: pitch * CGFloat(index), y: 0, width: size, height: size)
      cg.saveGState()
      // The hello's sway about the middle (the middle bot half a swing ahead,
      // `animation-delay: -0.6s`), the lean toward the change about the feet,
      // then the hop and the writer's typing bob.
      if let sway {
        let t = sway + (index == 1 ? 0.6 : 0)
        let swing = (t / 1.2).truncatingRemainder(dividingBy: 2)
        let u = CubicBezier.easeInOutCurve.y(at: swing < 1 ? swing : 2 - swing)
        turn(cg, by: -9 + 18 * u, about: CGPoint(x: box.midX, y: box.midY))
      }
      if let game {
        turn(cg, by: CodeReview.easedLean(index, at: game), about: CGPoint(x: box.midX, y: box.maxY))
      }
      let bob = index == 0 && scene.typing ? typingBob(now) : 0
      cg.translateBy(x: 0, y: -5 * scene.hops[index] + bob)
      let pose = still ? BotPose.rest(.idle) : BotPose.at(now, state: .idle, seed: member.seed, style: style)
      BotRenderer.draw(member.look, pose: pose, style: style, in: cg, box: box)
      cg.restoreGState()
    }
    if game != nil { drawProps(scene, in: cg) }
  }

  private static let accent: UInt32 = 0x74B7FF
  private static let done: UInt32 = 0x4ECB8D

  private static let code = NSAttributedString(string: "</>", attributes: [
    .font: NSFont.monospacedSystemFont(ofSize: 6, weight: .heavy),
    .foregroundColor: NSColor(cgColor: BotRenderer.cgColor(accent)) ?? .systemBlue,
  ])
  private static let tick: NSImage? = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
    .withSymbolConfiguration(
      NSImage.SymbolConfiguration(pointSize: 6, weight: .black)
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(cgColor: BotRenderer.cgColor(done)) ?? .systemGreen]))
    )

  /// The code, the commit in flight and the tick, drawn over the crew.
  private static func drawProps(_ scene: CodeReview, in cg: CGContext) {
    let centre = { (bot: Double) in size / 2 + pitch * bot }
    if scene.code > 0 {
      cg.saveGState()
      cg.setAlpha(scene.code)
      let extent = code.size()
      code.draw(at: CGPoint(x: centre(0) - extent.width / 2, y: -3 - 2 * scene.code - extent.height / 2))
      cg.restoreGState()
    }
    if let commit = scene.commit {
      cg.saveGState()
      cg.setShadow(offset: .zero, blur: 3, color: BotRenderer.cgColor(accent, alpha: 0.8))
      let at = CGPoint(x: centre(commit.at), y: -2 - 4 * commit.lift)
      cg.setFillColor(BotRenderer.cgColor(accent))
      cg.fillEllipse(in: CGRect(x: at.x - 1.5, y: at.y - 1.5, width: 3, height: 3))
      cg.restoreGState()
    }
    if scene.approved > 0, let tick {
      cg.saveGState()
      cg.setAlpha(scene.approved)
      cg.setShadow(offset: .zero, blur: 3, color: BotRenderer.cgColor(done, alpha: 0.7))
      cg.translateBy(x: centre(2), y: -4)
      let scale = 0.6 + 0.4 * scene.approved
      cg.scaleBy(x: scale, y: scale)
      let extent = tick.size
      tick.draw(
        in: CGRect(x: -extent.width / 2, y: -extent.height / 2, width: extent.width, height: extent.height),
        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
      )
      cg.restoreGState()
    }
  }

  /// `rotationEffect(_:anchor:)`: degrees clockwise about `pivot`.
  private static func turn(_ cg: CGContext, by degrees: Double, about pivot: CGPoint) {
    cg.translateBy(x: pivot.x, y: pivot.y)
    cg.rotate(by: degrees * .pi / 180)
    cg.translateBy(x: -pivot.x, y: -pivot.y)
  }

  /// A quick tap-tap bob while the writer types.
  private static func typingBob(_ now: TimeInterval) -> CGFloat {
    -1.2 * abs(sin(now * .pi * 5))
  }
}

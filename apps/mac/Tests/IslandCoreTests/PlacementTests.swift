import CoreGraphics
import Foundation
import IslandCore
import Testing

@Suite struct EdgeSnapTests {
  // A 1512 × 982 display at the origin, AppKit coordinates (y up).
  let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

  @Test func `lands on the nearest of top, left and right`() {
    #expect(EdgeSnap.placement(at: CGPoint(x: 40, y: 500), in: screen, current: .top) == .left)
    #expect(EdgeSnap.placement(at: CGPoint(x: 1480, y: 500), in: screen, current: .top) == .right)
    #expect(EdgeSnap.placement(at: CGPoint(x: 756, y: 960), in: screen, current: .right) == .top)
  }

  @Test func `never lands on the bottom, which is the Dock's`() {
    let bottom = CGPoint(x: 756, y: 5)
    #expect(EdgeSnap.placement(at: bottom, in: screen, current: .left) == .left)
    #expect(EdgeSnap.placement(at: bottom, in: screen, current: .top) == .left)
    #expect(IslandPlacement.allCases == [.top, .left, .right])
  }

  @Test func `stays put near a tie so the diagonal doesn't flicker`() {
    // 10% from the left, 11% from the top: closer to the left, but not by enough.
    let corner = CGPoint(x: 151.2, y: 982 - 108)
    #expect(EdgeSnap.placement(at: corner, in: screen, current: .top) == .top)
    #expect(EdgeSnap.placement(at: corner, in: screen, current: .left) == .left)
  }

  @Test func `works on a display that isn't at the origin`() {
    let external = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
    #expect(EdgeSnap.placement(at: CGPoint(x: -1900, y: 700), in: external, current: .top) == .left)
  }

  @Test func `anchors along the edge from the top, off the corners`() {
    #expect(abs(EdgeSnap.anchor(at: CGPoint(x: 0, y: 491), in: screen) - 0.5) < 0.001)
    #expect(EdgeSnap.anchor(at: CGPoint(x: 0, y: 980), in: screen) == EdgeMetrics.anchorRange.lowerBound)
    #expect(EdgeSnap.anchor(at: CGPoint(x: 0, y: -50), in: screen) == EdgeMetrics.anchorRange.upperBound)
  }

  @Test func `an empty screen changes nothing`() {
    #expect(EdgeSnap.placement(at: .zero, in: .zero, current: .right) == .right)
    #expect(EdgeSnap.anchor(at: .zero, in: .zero) == EdgeMetrics.defaultAnchor)
  }
}

@Suite struct EdgeOriginTests {
  let canvas = CGSize(width: 760, height: 982)

  @Test func `the resting notch sits flush with its edge, centred on the anchor`() {
    let box = EdgeMetrics.restingBox
    let right = EdgeMetrics.origin(box: box, canvas: canvas, placement: .right, anchor: 0.5, top: 37, bottom: 0)
    #expect(right == CGPoint(x: 760 - box.width, y: (491 - box.height / 2).rounded()))
    let left = EdgeMetrics.origin(box: box, canvas: canvas, placement: .left, anchor: 0.5, top: 37, bottom: 0)
    #expect(left == CGPoint(x: 0, y: right.y))
  }

  @Test func `an open panel grows down from the notch, so its top never moves`() {
    let resting = EdgeMetrics.origin(box: EdgeMetrics.restingBox, canvas: canvas, placement: .right, anchor: 0.3, top: 37, bottom: 0)
    let small = EdgeMetrics.origin(box: CGSize(width: 400, height: 200), canvas: canvas, placement: .right, anchor: 0.3, top: 37, bottom: 0)
    let large = EdgeMetrics.origin(box: CGSize(width: 400, height: 320), canvas: canvas, placement: .right, anchor: 0.3, top: 37, bottom: 0)
    #expect(small.y == resting.y && large.y == resting.y)
  }

  @Test func `keeps clear of the menu bar and a bottom Dock`() {
    let tall = CGSize(width: 400, height: 500)
    let high = EdgeMetrics.origin(box: tall, canvas: canvas, placement: .right, anchor: 0.01, top: 37, bottom: 70)
    #expect(high.y == 37 + EdgeMetrics.margin)
    let low = EdgeMetrics.origin(box: tall, canvas: canvas, placement: .right, anchor: 0.92, top: 37, bottom: 70)
    #expect(low.y == 982 - 70 - EdgeMetrics.margin - 500)
  }

  @Test func `a box taller than the room starts under the menu bar`() {
    let huge = CGSize(width: 400, height: 2000)
    let origin = EdgeMetrics.origin(box: huge, canvas: canvas, placement: .left, anchor: 0.5, top: 37, bottom: 0)
    #expect(origin.y == 37 + EdgeMetrics.margin)
  }
}

@Suite struct EdgeClockSettingTests {
  @Test func `the side clock is on by default, stays out of a default file, and turns off`() {
    var settings = IslandSettings()
    #expect(settings.edgeClock)
    #expect(!String(decoding: settings.json(), as: UTF8.self).contains("edgeClock"))
    settings.edgeClock = false
    #expect(IslandSettings(json: settings.json()).edgeClock == false)
  }
}

@Suite struct EdgeOrbsTests {
  func session(_ key: String, _ agent: AgentKind, _ state: SessionState, title: String = "", approval: Bool = false) -> SessionSnapshot {
    SessionSnapshot(
      key: key, agent: agent, sessionId: key, cwd: "/tmp/\(key)", state: state, title: title,
      startedAt: .now, updatedAt: .now,
      pendingApproval: approval ? PendingApproval(id: key, toolName: "Bash", createdAt: .now) : nil
    )
  }

  @Test func `one orb per working agent, in the wing's order`() {
    let orbs = EdgeMetrics.orbs([
      session("a", .cursor, .working, title: "Searching for useAuth"),
      session("b", .claudeCode, .working, title: "Running pnpm test"),
      session("c", .claudeCode, .working, title: "Editing index.ts"),
      session("d", .codex, .done),
    ])
    #expect(orbs.map(\.agent) == [.claudeCode, .cursor])
    #expect(orbs.map(\.state) == [.working, .searching])
    #expect(orbs.allSatisfy { !$0.waiting })
  }

  @Test func `an agent waiting on you comes first, in the waiting colour`() {
    let orbs = EdgeMetrics.orbs([
      session("a", .claudeCode, .working, title: "Running pnpm test"),
      session("b", .codex, .working, approval: true),
    ])
    #expect(orbs.map(\.agent) == [.codex, .claudeCode])
    #expect(orbs.map(\.waiting) == [true, false])
  }

  @Test func `nothing working or waiting, no orbs`() {
    #expect(EdgeMetrics.orbs([session("a", .claudeCode, .done), session("b", .codex, .idle)]).isEmpty)
  }

  @Test func `orbs shrink so three fit the resting length`() {
    #expect(EdgeMetrics.orbSize(1) == 16)
    #expect(EdgeMetrics.orbSize(3) * 3 + 2 * 3 <= EdgeMetrics.length)
  }
}

@Suite struct TurnedOutlineTests {
  @Test func `on top it's the notch outline exactly`() {
    let box = CGSize(width: 320, height: 37)
    let turned = IslandOutline.silhouette(box, on: .top, corner: 12, ear: 10)
    #expect(turned == IslandOutline(width: 300, height: 37, corner: 12).silhouette())
  }

  @Test(arguments: [IslandPlacement.left, .right])
  func `on a side it fills the box, bezel against the edge`(placement: IslandPlacement) {
    let box = EdgeMetrics.restingBox
    let path = IslandOutline.silhouette(box, on: placement, corner: EdgeMetrics.depth / 2, ear: EdgeMetrics.ear)
    let bounds = path.boundingBoxOfPath
    #expect(abs(bounds.width - box.width) < 0.01 && abs(bounds.height - box.height) < 0.01)
    #expect(abs(bounds.minX) < 0.01 && abs(bounds.minY) < 0.01)
    // The ears reach along the bezel only: next to the edge, at the very top
    // and bottom, it's island; a step inward there, it's screen.
    let bezelX = placement == .right ? box.width - 0.5 : 0.5
    let innerX = placement == .right ? 0.5 : box.width - 0.5
    #expect(path.contains(CGPoint(x: bezelX, y: 5)))
    #expect(!path.contains(CGPoint(x: innerX, y: 5)))
    #expect(path.contains(CGPoint(x: box.width / 2, y: box.height / 2)))
  }

  @Test func `the open edge never runs along the bezel`() {
    let box = CGSize(width: 300, height: 200)
    let edge = IslandOutline.edge(box, on: .right, corner: 16, ear: 6)
    // It starts and ends on the right edge, at the top and bottom.
    #expect(abs(edge.currentPoint.x - 300) < 0.01 && abs(edge.currentPoint.y - 200) < 0.01)
  }
}

@Suite struct PlacementSettingsTests {
  @Test func `defaults to the top and leaves the file untouched until changed`() {
    let settings = IslandSettings()
    #expect(settings.placement == .top)
    let text = String(decoding: settings.json(), as: UTF8.self)
    #expect(!text.contains("placement") && !text.contains("edgeAnchor"))
  }

  @Test func `round-trips a side edge and where along it`() {
    var settings = IslandSettings()
    settings.placement = .right
    settings.edgeAnchor = 0.618
    let back = IslandSettings(json: settings.json())
    #expect(back.placement == .right)
    #expect(abs(back.edgeAnchor - 0.618) < 0.0001)
    #expect(back == settings)
  }

  @Test func `ignores a bottom placement and clamps a wild anchor`() {
    let stored = Data(#"{"settingsVersion":3,"placement":"bottom","edgeAnchor":7}"#.utf8)
    let settings = IslandSettings(json: stored)
    #expect(settings.placement == .top)
    #expect(settings.edgeAnchor == Double(EdgeMetrics.anchorRange.upperBound))
  }
}

import CoreGraphics
import Foundation
import IslandCore
import Testing

@Suite struct IslandOutlineTests {
  let outline = IslandOutline(width: 300, height: 37, corner: 12)

  @Test func `runs ear to ear along the top of a box one ear wider each side`() {
    let edge = outline.edge()
    #expect(outline.boxWidth == 320)
    #expect(abs(edge.currentPoint.x - 320) < 0.001)
    #expect(abs(edge.currentPoint.y) < 0.001)
    #expect(edge.boundingBoxOfPath.minX >= -0.001)
    #expect(abs(edge.boundingBoxOfPath.maxY - 37) < 0.001)
  }

  @Test func `is as long as its ears, sides, corners and bottom`() {
    let quarter = CGFloat.pi / 2
    let expected = 2 * quarter * 10 + 2 * (37 - 12 - 10) + 2 * quarter * 12 + (300 - 24)
    #expect(abs(outline.length - expected) < 0.001)
  }

  @Test func `is symmetric, which lets one run be mirrored for the other side`() {
    for fraction in stride(from: 0.0, through: 0.5, by: 0.05) {
      let left = outline.sample(at: fraction).point
      let right = outline.sample(at: 1 - fraction).point
      #expect(abs(left.x + right.x - 320) < 0.01)
      #expect(abs(left.y - right.y) < 0.01)
    }
  }

  // A wide, short island: the sides are only ~4% of the edge each, near 6% and 94%.
  @Test(arguments: [(0.06, CGVector(dx: -1, dy: 0)), (0.5, CGVector(dx: 0, dy: 1)), (0.94, CGVector(dx: 1, dy: 0))])
  func `normals point out of the island`(fraction: CGFloat, outward: CGVector) {
    let normal = outline.sample(at: fraction).normal
    #expect(abs(normal.dx - outward.dx) < 0.001 && abs(normal.dy - outward.dy) < 0.001)
  }

  @Test func `clamps the corner so a short island stays a pill`() {
    let short = IslandOutline(width: 40, height: 16, corner: 16)
    #expect(short.edge().boundingBoxOfPath.maxY <= 16.001)
  }

  @Test func `crackles the same way for the same seed, differently for another, ends pinned`() {
    let a = outline.crackled(seed: 1, amplitude: 3)
    #expect(a == outline.crackled(seed: 1, amplitude: 3))
    #expect(a != outline.crackled(seed: 2, amplitude: 3))
    #expect(abs(a.currentPoint.x - 320) < 0.001 && abs(a.currentPoint.y) < 0.001)
  }
}

@Suite struct NotchMetricsTests {
  @Test func `measures the notch as the gap between the menu bar's two halves`() {
    let notch = NotchMetrics(screenWidth: 1512, leftArea: 654, rightArea: 654, topInset: 32, menuBarHeight: 37)
    #expect(notch == NotchMetrics(width: 204, height: 32, hasNotch: true))
  }

  @Test(arguments: [(nil, nil, 0.0), (700.0, 700.0, 24.0), (654.0, 654.0, 0.0)] as [(CGFloat?, CGFloat?, CGFloat)])
  func `falls back without a real notch`(left: CGFloat?, right: CGFloat?, inset: CGFloat) {
    let notch = NotchMetrics(screenWidth: 1512, leftArea: left, rightArea: right, topInset: inset, menuBarHeight: 24)
    #expect(notch == NotchMetrics(width: NotchMetrics.fallbackWidth, height: 24, hasNotch: false))
  }

  @Test func `sizes the island around it`() {
    let notch = NotchMetrics(width: 200, height: 32, hasNotch: true)
    #expect(IslandMetrics.bandHeight(notch) == 37)
    #expect(IslandMetrics.collapsedWidth(notch, showsWings: true) == 304)
    #expect(IslandMetrics.collapsedWidth(notch, showsWings: false) == 200)
    #expect(IslandMetrics.expandedWidth(notch) == 360)
    #expect(IslandMetrics.expandedWidth(NotchMetrics(width: 260, height: 32, hasNotch: true)) == 370)
  }

  @Test func `colours the battery red through amber to green, red when low`() {
    #expect(batteryHue(percent: 0, low: false) == 0)
    #expect(batteryHue(percent: 100, low: false) == 130)
    #expect(batteryHue(percent: 140, low: false) == 130)
    #expect(batteryHue(percent: 80, low: true) == 2)
  }
}

@Suite struct IslandSettingsTests {
  private func settings(_ json: String) -> IslandSettings {
    IslandSettings(json: Data(json.utf8))
  }

  @Test func `reads openWith and battery from a current file`() {
    #expect(settings(#"{"settingsVersion":3,"openWith":"hover","battery":false}"#)
      == IslandSettings(openWith: .hover, battery: false))
  }

  @Test func `reads the session view, compact unless it says detailed`() {
    #expect(settings(#"{"settingsVersion":3,"sessionView":"detailed"}"#).sessionView == .detailed)
    #expect(settings(#"{"settingsVersion":3,"sessionView":"grid"}"#).sessionView == .compact)
  }

  @Test func `turns off only the integrations the file switches off`() {
    #expect(settings(#"{"agents":{"codex":false,"cursor":true}}"#).agents == [.claudeCode, .cursor])
  }

  @Test func `ignores a v1 file's openWith, which was only ever the old default`() {
    #expect(settings(#"{"openWith":"hover"}"#).openWith == .swipe)
  }

  @Test(arguments: [nil, Data("not json".utf8), Data(#"{"settingsVersion":3,"openWith":"wave"}"#.utf8)])
  func `falls back to the defaults`(data: Data?) {
    #expect(IslandSettings(json: data) == IslandSettings())
  }
}

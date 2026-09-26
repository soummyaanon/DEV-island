import AppKit
import IslandCore

/// The app icon, drawn with the island's own renderer so the crew on it is
/// the crew on screen: a blue-to-orange tile, the notch across the top, and
/// the three bots gathered below it. `AgentIsland --render-icon out.png`
/// writes the 1024-point master; `scripts/icon.sh` turns it into the .icns.
nonisolated enum IconRenderer {
  static func render(to url: URL) throws {
    let side = 1024
    guard let cg = CGContext(
      data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw CocoaError(.fileWriteUnknown) }
    // Top-left origin, like the bot renderer expects.
    cg.translateBy(x: 0, y: CGFloat(side))
    cg.scaleBy(x: 1, y: -1)
    draw(in: cg)
    guard let image = cg.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: url)
  }

  static func draw(in cg: CGContext) {
    let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
    func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
      CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    // The tile: macOS's icon grid, 824 of 1024, with its soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: color(0x000000, 0.35))
    cg.addPath(shape)
    cg.setFillColor(color(0x1B2D6B))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(shape)
    cg.clip()
    // Blue at the top melting into a warm orange at the bottom.
    let sky = CGGradient(colorsSpace: rgb, colors: [color(0x2448D8), color(0x5B4FD0), color(0xC0587A), color(0xFF8A3D)] as CFArray, locations: [0, 0.38, 0.7, 1])!
    cg.drawLinearGradient(sky, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    // A soft light behind the crew.
    let glow = CGGradient(colorsSpace: rgb, colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    cg.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 600), startRadius: 0, endCenter: CGPoint(x: 512, y: 600), endRadius: 420, options: [])
    // A sheen across the top edge.
    let sheen = CGGradient(colorsSpace: rgb, colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 380), options: [])

    // The notch, hanging from the top edge, with the crew's three colours in it.
    let notch = CGRect(x: 322, y: 60, width: 380, height: 158)
    cg.addPath(CGPath(roundedRect: notch, cornerWidth: 46, cornerHeight: 46, transform: nil))
    cg.setFillColor(color(0x000000))
    cg.fillPath()
    for (i, member) in BotLook.crew.enumerated() {
      let x = 462 + CGFloat(i) * 50
      cg.addEllipse(in: CGRect(x: x - 12, y: 150 - 12, width: 24, height: 24))
      cg.setFillColor(color(member.look.color))
      cg.fillPath()
    }

    // The crew: the outer two turned in toward the star, which stands in front.
    let places: [(index: Int, x: CGFloat, y: CGFloat, size: CGFloat, look: Double, turn: Double)] = [
      (0, 318, 600, 320, 3.2, 8),
      (2, 706, 600, 320, -3.2, -8),
      (1, 512, 572, 370, 0, 0),
    ]
    for place in places {
      let member = BotLook.crew[place.index]
      var pose = BotPose.rest(.idle)
      pose.lookX = place.look
      pose.tilt = place.turn * 0.4
      // A shadow on the ground under each.
      cg.saveGState()
      cg.setFillColor(color(0x000000, 0.22))
      cg.addEllipse(in: CGRect(x: place.x - place.size * 0.34, y: place.y + place.size * 0.5, width: place.size * 0.68, height: place.size * 0.1))
      cg.fillPath()
      cg.restoreGState()
      let box = CGRect(x: place.x - place.size / 2, y: place.y - place.size / 2, width: place.size, height: place.size)
      BotRenderer.draw(member.look, pose: pose, style: BotPose.Style(), in: cg, box: box)
    }
    cg.restoreGState()

    // A hairline edge, lit from above.
    cg.addPath(CGPath(roundedRect: tile.insetBy(dx: 1, dy: 1), cornerWidth: 184, cornerHeight: 184, transform: nil))
    cg.setStrokeColor(color(0xFFFFFF, 0.18))
    cg.setLineWidth(2)
    cg.strokePath()
  }
}

// Renders the app icon (1024×1024 PNG). Regenerate everything with:
//
//   swiftc -O -o /tmp/render-icon scripts/icon/render-icon.swift
//   /tmp/render-icon packages/app/build/icon-source.png
//   mkdir /tmp/icon.iconset && for s in 16 32 128 256 512; do
//     sips -z $s $s packages/app/build/icon-source.png --out /tmp/icon.iconset/icon_${s}x${s}.png
//     sips -z $((s*2)) $((s*2)) packages/app/build/icon-source.png --out /tmp/icon.iconset/icon_${s}x${s}@2x.png
//   done
//   iconutil -c icns /tmp/icon.iconset -o packages/app/build/icon.icns
//   cp packages/app/build/icon-source.png docs/assets/icon.png
//
import AppKit
import CoreGraphics

// Agent Island icon: the notch island at the top of a dark squircle, and under
// it the app's orange mech bot — rounded head, two eyes, two antennae — with a
// soft glow, lit from the upper left like the in-app avatars.
let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1) // y down, like the design grid
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a) }
func grad(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient { CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)! }

// macOS icon grid: 824pt body, centred, continuous-ish corners.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 28, color: c(0, 0, 0, 0.45))
ctx.addPath(squircle); ctx.setFillColor(c(10, 11, 16)); ctx.fillPath()
ctx.restoreGState()

// Tile: deep midnight to black.
ctx.saveGState(); ctx.addPath(squircle); ctx.clip()
ctx.drawLinearGradient(grad([c(34, 37, 52), c(16, 17, 24), c(6, 6, 9)], [0, 0.55, 1]),
                       start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
// A faint warm bloom where the bot sits.
ctx.drawRadialGradient(grad([c(255, 140, 66, 0.28), c(255, 140, 66, 0)], [0, 1]),
                       startCenter: CGPoint(x: 512, y: 610), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 610), endRadius: 360, options: [])
// The island: a black pill hanging from the top edge, with the concave ears.
let island = CGRect(x: 322, y: 100, width: 380, height: 118)
let pill = CGMutablePath()
pill.move(to: CGPoint(x: island.minX - 26, y: 100))
pill.addQuadCurve(to: CGPoint(x: island.minX, y: 126), control: CGPoint(x: island.minX, y: 100))
pill.addLine(to: CGPoint(x: island.minX, y: island.maxY - 44))
pill.addQuadCurve(to: CGPoint(x: island.minX + 44, y: island.maxY), control: CGPoint(x: island.minX, y: island.maxY))
pill.addLine(to: CGPoint(x: island.maxX - 44, y: island.maxY))
pill.addQuadCurve(to: CGPoint(x: island.maxX, y: island.maxY - 44), control: CGPoint(x: island.maxX, y: island.maxY))
pill.addLine(to: CGPoint(x: island.maxX, y: 126))
pill.addQuadCurve(to: CGPoint(x: island.maxX + 26, y: 100), control: CGPoint(x: island.maxX, y: 100))
pill.closeSubpath()
ctx.addPath(pill); ctx.setFillColor(c(0, 0, 0)); ctx.fillPath()
// Its soft silver inner edge (the Mono glow).
ctx.saveGState(); ctx.addPath(pill); ctx.clip()
ctx.addPath(pill); ctx.setStrokeColor(c(220, 220, 230, 0.22)); ctx.setLineWidth(6); ctx.strokePath()
ctx.restoreGState()
// Three thinking-orb dots in the island.
for (i, x) in [470.0, 512.0, 554.0].enumerated() {
  let r: CGFloat = i == 1 ? 11 : 8
  ctx.setFillColor(c(255, 170, 110, i == 1 ? 1 : 0.7))
  ctx.fillEllipse(in: CGRect(x: x - r, y: 160 - r, width: r * 2, height: r * 2))
}
ctx.restoreGState()

// The mech bot.
let head = CGRect(x: 292, y: 430, width: 440, height: 330)
let headPath = CGPath(roundedRect: head, cornerWidth: 150, cornerHeight: 150, transform: nil)
// Antennae (behind the head).
ctx.setLineCap(.round)
for (x0, x1) in [(420.0, 392.0), (604.0, 632.0)] {
  ctx.setStrokeColor(c(214, 104, 44)); ctx.setLineWidth(22)
  ctx.move(to: CGPoint(x: x0, y: 450)); ctx.addLine(to: CGPoint(x: x1, y: 352)); ctx.strokePath()
  ctx.saveGState()
  ctx.setShadow(offset: .zero, blur: 24, color: c(255, 150, 80, 0.8))
  ctx.setFillColor(c(255, 150, 86)); ctx.fillEllipse(in: CGRect(x: x1 - 30, y: 322, width: 60, height: 60))
  ctx.restoreGState()
}
// Side "ears".
for x in [262.0, 712.0] {
  let ear = CGPath(roundedRect: CGRect(x: x, y: 540, width: 50, height: 110), cornerWidth: 22, cornerHeight: 22, transform: nil)
  ctx.addPath(ear); ctx.setFillColor(c(206, 98, 40)); ctx.fillPath()
}
// Head: glow, then a glossy orange body lit from the upper left.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 60, color: c(255, 130, 60, 0.55))
ctx.addPath(headPath); ctx.setFillColor(c(255, 140, 66)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState(); ctx.addPath(headPath); ctx.clip()
ctx.drawLinearGradient(grad([c(255, 186, 128), c(255, 140, 66), c(214, 92, 34)], [0, 0.5, 1]),
                       start: CGPoint(x: 330, y: 430), end: CGPoint(x: 700, y: 760), options: [])
// Sheen across the top.
ctx.drawRadialGradient(grad([c(255, 255, 255, 0.55), c(255, 255, 255, 0)], [0, 1]),
                       startCenter: CGPoint(x: 410, y: 480), startRadius: 0,
                       endCenter: CGPoint(x: 410, y: 480), endRadius: 190, options: [])
ctx.restoreGState()
// Face plate.
let plate = CGPath(roundedRect: CGRect(x: 352, y: 530, width: 320, height: 160), cornerWidth: 80, cornerHeight: 80, transform: nil)
ctx.addPath(plate); ctx.setFillColor(c(38, 22, 16, 0.92)); ctx.fillPath()
// Eyes: glowing, a little happy.
for x in [450.0, 574.0] {
  ctx.saveGState()
  ctx.setShadow(offset: .zero, blur: 26, color: c(255, 214, 160, 0.95))
  let eye = CGPath(roundedRect: CGRect(x: x - 26, y: 572, width: 52, height: 76), cornerWidth: 26, cornerHeight: 26, transform: nil)
  ctx.addPath(eye); ctx.setFillColor(c(255, 238, 214)); ctx.fillPath()
  ctx.restoreGState()
}

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

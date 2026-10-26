// Draws the DripWriter app icon (a typed page whose caret drips ink) at 1024px and writes AppIcon.icns.
// Usage: swift tools/make-icon.swift <out-dir>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"
let S: CGFloat = 1024

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

func drawIcon(_ ctx: CGContext) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    // macOS squircle tile with a little margin, as Apple's grid does
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x000000, 0.35))
    ctx.addPath(tilePath); ctx.setFillColor(color(0x1a2a7a)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [color(0x3b5cf0), color(0x1c2a86), color(0x10175a)] as CFArray, locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 820, y: 100), options: [])
    // soft glow behind the page
    let glow = CGGradient(colorsSpace: cs, colors: [color(0x8fa6ff, 0.45), color(0x8fa6ff, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 470, y: 620), startRadius: 0, endCenter: CGPoint(x: 470, y: 620), endRadius: 460, options: [])

    // the page, slightly tilted
    ctx.saveGState()
    ctx.translateBy(x: 470, y: 560); ctx.rotate(by: -0.07); ctx.translateBy(x: -470, y: -560)
    let page = CGRect(x: 240, y: 300, width: 460, height: 540)
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0x050a30, 0.55))
    ctx.addPath(CGPath(roundedRect: page, cornerWidth: 34, cornerHeight: 34, transform: nil))
    ctx.setFillColor(color(0xfbfcff)); ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // typed lines
    let lines: [(CGFloat, CGFloat)] = [(0.86, 1), (0.74, 0.9), (0.62, 1), (0.50, 0.55)]
    for (i, (y, w)) in lines.enumerated() {
        let ly = page.minY + page.height * y
        let full = page.width - 120
        ctx.addPath(CGPath(roundedRect: CGRect(x: page.minX + 60, y: ly, width: full * w, height: 30), cornerWidth: 15, cornerHeight: 15, transform: nil))
        ctx.setFillColor(color(i == 3 ? 0x2f4fd6 : 0xc9d2ea)); ctx.fillPath()
    }
    // caret at the end of the last line
    let caretX = page.minX + 60 + (page.width - 120) * 0.55 + 24
    let caretTop = page.minY + page.height * 0.50 + 62
    let caretBottom = page.minY + page.height * 0.50 - 34
    ctx.addPath(CGPath(roundedRect: CGRect(x: caretX, y: caretBottom, width: 26, height: caretTop - caretBottom), cornerWidth: 10, cornerHeight: 10, transform: nil))
    ctx.setFillColor(color(0xe8344a)); ctx.fillPath()
    ctx.restoreGState()

    // ink drop falling from the caret (drawn untilted so it falls straight down)
    let dropX: CGFloat = 526, dropTop: CGFloat = 548
    let drop = CGMutablePath()
    drop.move(to: CGPoint(x: dropX, y: dropTop))
    drop.addCurve(to: CGPoint(x: dropX + 62, y: dropTop - 150), control1: CGPoint(x: dropX + 14, y: dropTop - 50), control2: CGPoint(x: dropX + 62, y: dropTop - 90))
    drop.addArc(center: CGPoint(x: dropX, y: dropTop - 150), radius: 62, startAngle: 0, endAngle: .pi, clockwise: true)
    drop.addCurve(to: CGPoint(x: dropX, y: dropTop), control1: CGPoint(x: dropX - 62, y: dropTop - 90), control2: CGPoint(x: dropX - 14, y: dropTop - 50))
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x3a0010, 0.5))
    ctx.addPath(drop); ctx.clip()
    let ink = CGGradient(colorsSpace: cs, colors: [color(0xff6f80), color(0xe8344a), color(0xa3132a)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(ink, start: CGPoint(x: dropX - 40, y: dropTop), end: CGPoint(x: dropX + 50, y: dropTop - 220), options: [])
    ctx.restoreGState()
    // highlight on the drop
    ctx.addEllipse(in: CGRect(x: dropX - 36, y: dropTop - 170, width: 22, height: 44))
    ctx.setFillColor(color(0xffffff, 0.55)); ctx.fillPath()

    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = g.cgContext
    ctx.scaleBy(x: CGFloat(size) / S, y: CGFloat(size) / S)
    drawIcon(ctx)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = "\(out)/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! png(size: base).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base).png"))
    try! png(size: base * 2).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base)@2x.png"))
}
try! png(size: 1024).write(to: URL(fileURLWithPath: "\(out)/icon-1024.png"))
print("wrote \(iconset)")

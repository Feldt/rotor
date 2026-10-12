// Renders the app icon (1024 px) and the menu bar glyph from code.
// usage: swift scripts/render-icon.swift <icon.png> <glyph.png>
import AppKit
import CoreGraphics

func superellipse(in r: CGRect, n: CGFloat = 5) -> CGPath {
    let p = CGMutablePath()
    let a = r.width / 2, b = r.height / 2, cx = r.midX, cy = r.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
    }
    p.closeSubpath()
    return p
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func renderIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)
    // macOS icon grid: 824 pt body centred on a 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = superellipse(in: body)

    // Shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(shape); ctx.setFillColor(rgb(16, 21, 32)); ctx.fillPath()
    ctx.restoreGState()

    // Deep ink-blue body.
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let bg = CGGradient(colorsSpace: nil, colors: [rgb(38, 50, 74), rgb(14, 19, 31)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Two overlapping translucent discs: accounts.
    let r: CGFloat = 215
    let left = CGRect(x: 512 - 120 - r, y: 500 - r, width: 2 * r, height: 2 * r)
    let right = CGRect(x: 512 + 120 - r, y: 500 - r, width: 2 * r, height: 2 * r)
    func disc(_ rect: CGRect, top: CGColor, bottom: CGColor) {
        ctx.saveGState()
        ctx.addEllipse(in: rect); ctx.clip()
        let g = CGGradient(colorsSpace: nil, colors: [top, bottom] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        ctx.restoreGState()
    }
    disc(left, top: rgb(150, 178, 230, 0.55), bottom: rgb(90, 120, 190, 0.30))
    disc(right, top: rgb(170, 220, 225, 0.55), bottom: rgb(90, 160, 175, 0.30))
    // Brighter lens where they overlap.
    ctx.saveGState()
    ctx.addEllipse(in: left); ctx.clip()
    ctx.addEllipse(in: right); ctx.clip()
    ctx.setFillColor(rgb(235, 245, 255, 0.30)); ctx.fill(body)
    ctx.restoreGState()
    // Glass rims.
    for rect in [left, right] {
        ctx.addEllipse(in: rect.insetBy(dx: 2, dy: 2))
        ctx.setStrokeColor(rgb(255, 255, 255, 0.45)); ctx.setLineWidth(4); ctx.strokePath()
    }
    // Soft top highlight.
    let hl = CGGradient(colorsSpace: nil, colors: [rgb(255, 255, 255, 0.16), rgb(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(hl, startCenter: CGPoint(x: 512, y: 980), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 980), endRadius: 560, options: [])
    ctx.restoreGState()
    // Body edge highlight.
    ctx.addPath(shape)
    ctx.setStrokeColor(rgb(255, 255, 255, 0.14)); ctx.setLineWidth(3); ctx.strokePath()
    return ctx.makeImage()!
}

/// The menu bar glyph: the icon's two discs as outlines, in an 18 pt box.
func renderGlyph(scale: Int) -> CGImage {
    let size = 18 * scale
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    ctx.setStrokeColor(.black); ctx.setLineWidth(1.4)
    ctx.strokeEllipse(in: CGRect(x: 2.2, y: 4.2, width: 9.6, height: 9.6))
    ctx.strokeEllipse(in: CGRect(x: 6.2, y: 4.2, width: 9.6, height: 9.6))
    return ctx.makeImage()!
}

func write(_ img: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
write(renderIcon(size: 1024), args[1])
write(renderGlyph(scale: 4), args[2])

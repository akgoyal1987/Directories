// Generates Lantern's app icon as an .iconset, which build.sh feeds to iconutil.
//
// The icon is drawn in code rather than checked in as binary art, so it stays
// diffable, restyles in one place, and needs no design tool to rebuild.
//
//   swift tools/make-icon.swift <output.iconset directory> [variant]
//   swift tools/make-icon.swift --preview <out.png>     # all variants side by side
//
// Every mark has to answer "what does this app do?" before it answers "what is
// it called", so each one leads with a file or browsing signal and uses the
// warm light to explain the name.

import AppKit

enum Variant: Int, CaseIterable {
    case panes = 1       // the app's own layout: sidebar plus a list of rows
    case magnify = 2     // a folder under a magnifier
    case stack = 3       // folders receding into depth, the front one lit
    case lanternLit = 4  // an actual lantern throwing light onto a folder
    case drawer = 5      // a filing drawer pulled open, light spilling out
    case openFolder = 6  // an open folder with documents rising from it

    var name: String {
        switch self {
        case .panes:      return "panes"
        case .magnify:    return "magnify"
        case .stack:      return "stack"
        case .lanternLit: return "lantern-lit"
        case .drawer:     return "drawer"
        case .openFolder: return "open-folder"
        }
    }
}

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

// The night palette: a deep navy plate with a warm amber light.
let plateTop = rgb(40, 58, 86)
let plateBottom = rgb(11, 18, 32)
let amber = rgb(251, 191, 36)
let amberBright = rgb(254, 219, 143)
let amberDim = rgb(180, 130, 40)

func draw(size: CGFloat, variant: Variant) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 100.0                       // one unit of a 100x100 space

    // Art is authored top-left down; the context origin is bottom-left.
    func X(_ v: CGFloat) -> CGFloat { v * s }
    func Y(_ v: CGFloat) -> CGFloat { (100 - v) * s }
    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: X(x), y: Y(y)) }
    func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: X(x), y: Y(y + h), width: w * s, height: h * s)
    }
    func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: r, cornerWidth: radius * s, cornerHeight: radius * s, transform: nil)
    }
    func fill(_ r: CGRect, _ radius: CGFloat, _ color: NSColor) {
        ctx.setFillColor(color.cgColor); ctx.addPath(rounded(r, radius)); ctx.fillPath()
    }

    // ---- plate ----
    let inset: CGFloat = 10
    let plate = CGRect(x: inset * s, y: inset * s,
                       width: (100 - inset * 2) * s, height: (100 - inset * 2) * s)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: plate, cornerWidth: plate.width * 0.2237,
                       cornerHeight: plate.width * 0.2237, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(
        CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                   colors: [plateTop.cgColor, plateBottom.cgColor] as CFArray,
                   locations: [0, 1])!,
        start: CGPoint(x: plate.midX, y: plate.maxY),
        end: CGPoint(x: plate.midX, y: plate.minY), options: [])

    func glow(_ centre: CGPoint, _ radius: CGFloat, _ strength: CGFloat) {
        ctx.drawRadialGradient(
            CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [rgb(255, 201, 77, strength).cgColor,
                                rgb(255, 201, 77, 0).cgColor] as CFArray,
                       locations: [0, 1])!,
            startCenter: centre, startRadius: 0,
            endCenter: centre, endRadius: radius, options: [])
    }

    // A folder: body plus a tab on its top left.
    func folder(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                _ radius: CGFloat, _ color: NSColor) {
        let tabH = h * 0.22
        fill(R(x, y, w * 0.44, tabH * 2), radius * 0.7, color)
        fill(R(x, y + tabH, w, h - tabH), radius, color)
    }

    switch variant {

    case .panes:
        // A miniature of the app itself: sidebar on the left, rows on the right.
        glow(P(50, 50), plate.width * 0.50, 0.30)
        fill(R(22, 28, 56, 44), 5, rgb(255, 255, 255, 0.14))
        fill(R(22, 28, 17, 44), 5, amber)
        for y in [stride(from: CGFloat(36), to: 66, by: 10)].flatMap({ Array($0) }) {
            fill(R(44, y, 28, 5), 2.5, amberBright)
        }

    case .magnify:
        glow(P(44, 44), plate.width * 0.46, 0.40)
        folder(24, 28, 42, 32, 4, amber)
        // Ring drawn twice: a dark pass first so it separates from the folder.
        ctx.setLineWidth(7 * s)
        ctx.setStrokeColor(plateBottom.cgColor)
        ctx.strokeEllipse(in: R(46, 46, 26, 26))
        ctx.setLineWidth(4 * s)
        ctx.setStrokeColor(amberBright.cgColor)
        ctx.strokeEllipse(in: R(46, 46, 26, 26))
        ctx.setLineCap(.round)
        ctx.setLineWidth(6.5 * s)
        ctx.setStrokeColor(plateBottom.cgColor)
        ctx.move(to: P(69, 69)); ctx.addLine(to: P(77, 77)); ctx.strokePath()
        ctx.setLineWidth(4 * s)
        ctx.setStrokeColor(amberBright.cgColor)
        ctx.move(to: P(69, 69)); ctx.addLine(to: P(77, 77)); ctx.strokePath()

    case .stack:
        // Depth: the hierarchy expressed as folders receding behind one another.
        glow(P(50, 52), plate.width * 0.46, 0.35)
        folder(34, 22, 34, 26, 3, amberDim)
        folder(30, 32, 40, 28, 3.5, rgb(226, 160, 40))
        folder(25, 43, 48, 30, 4, amber)

    case .lanternLit:
        // The name, literally: a lantern above, a folder in its light.
        ctx.saveGState()
        let cone = CGMutablePath()
        cone.move(to: P(43, 40)); cone.addLine(to: P(20, 78))
        cone.addLine(to: P(80, 78)); cone.addLine(to: P(57, 40))
        cone.closeSubpath()
        ctx.addPath(cone); ctx.clip()
        ctx.drawLinearGradient(
            CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [rgb(255, 201, 77, 0.55).cgColor,
                                rgb(255, 201, 77, 0.0).cgColor] as CFArray,
                       locations: [0, 1])!,
            start: P(50, 40), end: P(50, 80), options: [])
        ctx.restoreGState()
        // Lantern: handle, cap, glowing body.
        ctx.setStrokeColor(amberBright.cgColor)
        ctx.setLineWidth(2.6 * s); ctx.setLineCap(.round)
        ctx.addArc(center: P(50, 22), radius: 6 * s, startAngle: .pi, endAngle: 0, clockwise: false)
        ctx.strokePath()
        fill(R(41, 22, 18, 4), 2, amberBright)
        fill(R(43, 26, 14, 14), 3, amber)
        glow(P(50, 33), plate.width * 0.22, 0.55)
        folder(33, 58, 34, 24, 3.5, amber)

    case .drawer:
        // A filing drawer pulled open, light coming out of the gap.
        glow(P(50, 56), plate.width * 0.42, 0.38)
        fill(R(26, 24, 48, 52), 5, rgb(255, 255, 255, 0.13))
        fill(R(30, 29, 40, 11), 2.5, amberDim)
        fill(R(30, 62, 40, 11), 2.5, amberDim)
        // The open drawer sits proud of the cabinet face.
        fill(R(22, 44, 56, 15), 3, amber)
        fill(R(42, 50, 16, 3), 1.5, plateBottom)      // handle

    case .openFolder:
        // Documents rising out of an open folder.
        glow(P(50, 48), plate.width * 0.46, 0.38)
        fill(R(26, 34, 48, 32), 4, amberDim)          // back panel
        fill(R(36, 26, 13, 18), 2, rgb(255, 255, 255, 0.92))
        fill(R(52, 30, 13, 16), 2, rgb(255, 255, 255, 0.72))
        fill(R(24, 46, 52, 26), 4, amber)             // front panel
    }

    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep) -> Data? { rep.representation(using: .png, properties: [:]) }

let args = CommandLine.arguments

if args.count > 2, args[1] == "--preview" {
    let tile: CGFloat = 220
    let all = Variant.allCases
    let sheet = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: Int(tile) * all.count, pixelsHigh: Int(tile),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
    for (i, v) in all.enumerated() {
        draw(size: tile, variant: v)
            .draw(in: NSRect(x: CGFloat(i) * tile, y: 0, width: tile, height: tile))
    }
    NSGraphicsContext.restoreGraphicsState()
    try? png(sheet)?.write(to: URL(fileURLWithPath: args[2]))
    print("Preview written to \(args[2]): " + all.map(\.name).joined(separator: ", "))
    exit(0)
}

let outDir = args.count > 1 ? args[1] : "./Lantern.iconset"
let variant = Variant(rawValue: args.count > 2 ? Int(args[2]) ?? 1 : 1) ?? .panes
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),     (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),     (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),  (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),  (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),  (1024, "icon_512x512@2x.png"),
]
for (size, name) in sizes {
    if let data = png(draw(size: CGFloat(size), variant: variant)) {
        try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
    }
}
print("Wrote \(sizes.count) sizes to \(outDir) using variant \(variant.name)")

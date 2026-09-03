// Generates Arbor's app icon as an .iconset, which build.sh feeds to iconutil.
//
// The icon is drawn in code rather than checked in as binary art, so it stays
// diffable, restyles in one place, and needs no design tool to rebuild.
//
//   swift tools/make-icon.swift <output.iconset directory>
//
// Motif: a folder branching into three child nodes - the tree view that is the
// point of the app. Emerald-to-teal, to sit apart from Finder's blue.

import AppKit

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "./Arbor.iconset"

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// Art is authored in a 100x100 space and scaled to each output size.
func draw(size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 100.0                      // one unit of the 100x100 space

    // macOS icons leave a margin: the art occupies roughly 80% of the canvas.
    let inset: CGFloat = 10
    let plate = CGRect(x: inset * s, y: inset * s,
                       width: (100 - inset * 2) * s, height: (100 - inset * 2) * s)
    let corner = plate.width * 0.2237         // the system's squircle proportion

    // Rounded plate with a vertical gradient.
    let platePath = CGPath(roundedRect: plate, cornerWidth: corner, cornerHeight: corner,
                           transform: nil)
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let colors = [
        NSColor(srgbRed: 0.204, green: 0.827, blue: 0.600, alpha: 1).cgColor,  // emerald
        NSColor(srgbRed: 0.020, green: 0.435, blue: 0.427, alpha: 1).cgColor,  // teal
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: plate.midX, y: plate.maxY),
                           end: CGPoint(x: plate.midX, y: plate.minY),
                           options: [])
    ctx.restoreGState()

    // A soft top highlight so the plate reads as a surface, not a flat swatch.
    // This has to fade out - a flat fill leaves a hard seam across the middle.
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let sheenColors = [
        NSColor(white: 1, alpha: 0.18).cgColor,
        NSColor(white: 1, alpha: 0.0).cgColor,
    ] as CFArray
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: sheenColors, locations: [0, 1])!
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: plate.midX, y: plate.maxY),
                           end: CGPoint(x: plate.midX, y: plate.midY),
                           options: [])
    ctx.restoreGState()

    // ---- the tree ----
    // Flip to a top-left origin, which is easier to reason about for layout.
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: (100 - y) * s) }

    let white = NSColor.white.cgColor
    let line = NSColor(white: 1, alpha: 0.92).cgColor

    // Parent folder, top left.
    let folder = CGRect(x: 24 * s, y: (100 - 36) * s, width: 22 * s, height: 16 * s)
    let tab = CGRect(x: 24 * s, y: (100 - 22) * s, width: 10 * s, height: 4 * s)
    ctx.setFillColor(white)
    ctx.addPath(CGPath(roundedRect: tab, cornerWidth: 1.6 * s, cornerHeight: 1.6 * s, transform: nil))
    ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: folder, cornerWidth: 3 * s, cornerHeight: 3 * s, transform: nil))
    ctx.fillPath()

    // Trunk and three branches into child nodes.
    let trunkX: CGFloat = 33
    let branchTo: CGFloat = 53
    let rows: [CGFloat] = [50, 65, 80]

    ctx.setStrokeColor(line)
    ctx.setLineWidth(3.4 * s)
    ctx.setLineCap(.round)

    ctx.move(to: p(trunkX, 38))
    ctx.addLine(to: p(trunkX, rows.last!))
    ctx.strokePath()

    for row in rows {
        ctx.move(to: p(trunkX, row))
        ctx.addLine(to: p(branchTo, row))
        ctx.strokePath()
    }

    // Child nodes as rounded tiles.
    ctx.setFillColor(white)
    for row in rows {
        let node = CGRect(x: 56 * s, y: (100 - row - 5.5) * s, width: 20 * s, height: 11 * s)
        ctx.addPath(CGPath(roundedRect: node, cornerWidth: 2.6 * s, cornerHeight: 2.6 * s,
                           transform: nil))
        ctx.fillPath()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, _ name: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}

// The set macOS expects in an .iconset.
let variants: [(Int, String)] = [
    (16, "icon_16x16.png"),     (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),     (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),  (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),  (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),  (1024, "icon_512x512@2x.png"),
]

for (size, name) in variants {
    write(draw(size: CGFloat(size)), name)
}

print("Wrote \(variants.count) icon sizes to \(outDir)")

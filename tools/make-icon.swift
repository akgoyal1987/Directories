// Generates Lantern's app icon as an .iconset, which build.sh feeds to iconutil.
//
// The icon is drawn in code rather than checked in as binary art, so it stays
// diffable, restyles in one place, and needs no design tool to rebuild.
//
//   swift tools/make-icon.swift <output.iconset directory> [variant]
//   swift tools/make-icon.swift --preview <out.png>     # all variants side by side
//
// The mark is an "L" monogram rather than a pictogram.

import AppKit

enum Variant: Int, CaseIterable {
    case warm = 1      // white L on a warm amber gradient
    case night = 2     // amber L glowing out of a deep navy ground
    case outline = 3   // hollow stroked L on amber
    case graphite = 4  // amber L on graphite, understated

    var name: String {
        switch self {
        case .warm: return "warm"
        case .night: return "night"
        case .outline: return "outline"
        case .graphite: return "graphite"
        }
    }
}

func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
}

func plateColors(_ v: Variant) -> (NSColor, NSColor) {
    switch v {
    case .warm:     return (rgb(255, 196, 107), rgb(217, 119, 6))
    case .night:    return (rgb(40, 58, 86),    rgb(11, 18, 32))
    case .outline:  return (rgb(251, 176, 59),  rgb(180, 83, 9))
    case .graphite: return (rgb(90, 90, 100),   rgb(24, 24, 27))
    }
}

func letterColor(_ v: Variant) -> NSColor {
    switch v {
    case .warm:     return .white
    case .night:    return rgb(251, 191, 36)
    case .outline:  return .white
    case .graphite: return rgb(252, 211, 77)
    }
}

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
    let s = size / 100.0                      // one unit of a 100x100 space

    // macOS icons leave a margin: the art occupies roughly 80% of the canvas.
    let inset: CGFloat = 10
    let plate = CGRect(x: inset * s, y: inset * s,
                       width: (100 - inset * 2) * s, height: (100 - inset * 2) * s)
    let corner = plate.width * 0.2237         // the system's squircle proportion
    let platePath = CGPath(roundedRect: plate, cornerWidth: corner, cornerHeight: corner,
                           transform: nil)

    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()

    let (top, bottom) = plateColors(variant)
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [top.cgColor, bottom.cgColor] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: plate.midX, y: plate.maxY),
                           end: CGPoint(x: plate.midX, y: plate.minY),
                           options: [])

    // A soft top sheen, faded out so it leaves no seam across the middle.
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor(white: 1, alpha: 0.16).cgColor,
                                    NSColor(white: 1, alpha: 0.0).cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: plate.midX, y: plate.maxY),
                           end: CGPoint(x: plate.midX, y: plate.midY),
                           options: [])

    // The name earns a glow: a warm pool of light behind the letter.
    if variant == .night {
        let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [NSColor(srgbRed: 1, green: 0.79, blue: 0.30, alpha: 0.40).cgColor,
                                       NSColor(srgbRed: 1, green: 0.79, blue: 0.30, alpha: 0.0).cgColor] as CFArray,
                              locations: [0, 1])!
        ctx.drawRadialGradient(glow,
                               startCenter: CGPoint(x: plate.midX, y: plate.midY), startRadius: 0,
                               endCenter: CGPoint(x: plate.midX, y: plate.midY),
                               endRadius: plate.width * 0.52,
                               options: [])
    }
    ctx.restoreGState()

    // ---- the monogram ----
    // Centre on the glyph outline, not the text line box: a line box carries
    // ascender and descender space the "L" does not use, which pushes it high
    // enough to clip the plate.
    let uiFont = NSFont.systemFont(ofSize: 100, weight: .black)
    let ctFont = uiFont as CTFont
    var chars: [UniChar] = Array("L".utf16)
    var glyphs = [CGGlyph](repeating: 0, count: chars.count)
    if CTFontGetGlyphsForCharacters(ctFont, &chars, &glyphs, chars.count),
       let glyph = CTFontCreatePathForGlyph(ctFont, glyphs[0], nil) {
        let box = glyph.boundingBox
        let targetHeight = 44 * s
        let scale = targetHeight / box.height
        var transform = CGAffineTransform.identity
            .translatedBy(x: plate.midX - box.midX * scale,
                          y: plate.midY - box.midY * scale)
            .scaledBy(x: scale, y: scale)
        if let placed = glyph.copy(using: &transform) {
            ctx.addPath(placed)
            if variant == .outline {
                ctx.setStrokeColor(letterColor(variant).cgColor)
                ctx.setLineWidth(4.5 * s)
                ctx.setLineJoin(.round)
                ctx.strokePath()
            } else {
                ctx.setFillColor(letterColor(variant).cgColor)
                ctx.fillPath()
            }
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep) -> Data? { rep.representation(using: .png, properties: [:]) }

let args = CommandLine.arguments

// ---- preview mode: every variant on one strip, for choosing ----
if args.count > 2, args[1] == "--preview" {
    let tile: CGFloat = 256
    let all = Variant.allCases
    let sheet = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: Int(tile) * all.count, pixelsHigh: Int(tile),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
    for (i, v) in all.enumerated() {
        let rep = draw(size: tile, variant: v)
        rep.draw(in: NSRect(x: CGFloat(i) * tile, y: 0, width: tile, height: tile))
    }
    NSGraphicsContext.restoreGraphicsState()
    try? png(sheet)?.write(to: URL(fileURLWithPath: args[2]))
    print("Preview written to \(args[2]): " + all.map(\.name).joined(separator: ", "))
    exit(0)
}

// ---- normal mode: one variant, full iconset ----
let outDir = args.count > 1 ? args[1] : "./Lantern.iconset"
let variant = Variant(rawValue: args.count > 2 ? Int(args[2]) ?? 1 : 1) ?? .warm
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

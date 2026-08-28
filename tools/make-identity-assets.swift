import AppKit

// The identity sheet's geometry (7a/7c), in its 56×44 design space.
let blue = NSColor(srgbRed: 10/255, green: 108/255, blue: 255/255, alpha: 1)

func drawMark(in rect: NSRect, canvas: CGFloat) {
    // Below 32 px the cursor is dropped and strokes thicken (7c).
    struct R { let x, y, w, h: CGFloat }
    let full: [R] = [R(x: 8, y: 32, w: 40, h: 3.5), R(x: 12, y: 20, w: 4.5, h: 12),
                     R(x: 20, y: 10, w: 4.5, h: 22), R(x: 28, y: 17, w: 4.5, h: 15),
                     R(x: 44, y: 14, w: 3.5, h: 18)]
    let mid: [R] = [R(x: 8, y: 31, w: 40, h: 4.5), R(x: 13, y: 20, w: 5, h: 11),
                    R(x: 21, y: 10, w: 5, h: 21), R(x: 29, y: 17, w: 5, h: 14),
                    R(x: 43, y: 14, w: 4.5, h: 17)]
    let tiny: [R] = [R(x: 6, y: 30, w: 44, h: 5.5), R(x: 13, y: 18, w: 6, h: 12),
                     R(x: 22, y: 9, w: 6, h: 21), R(x: 31, y: 16, w: 6, h: 14)]
    let rects = canvas >= 64 ? full : (canvas >= 32 ? mid : tiny)
    let sx = rect.width / 56, sy = rect.height / 44
    blue.setFill()
    for r in rects {
        // Flip y: design space grows down.
        let drawn = NSRect(x: rect.minX + r.x * sx,
                           y: rect.minY + rect.height - (r.y + r.h) * sy,
                           width: r.w * sx, height: r.h * sy)
        let rad = min(drawn.width, drawn.height) / 2
        NSBezierPath(roundedRect: drawn, xRadius: rad, yRadius: rad).fill()
    }
}

func iconPNG(_ px: Int, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // Tile: the light gradient squircle (7c), radius 28/124 of the tile.
    let inset = s * 0.03
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.226,
                            yRadius: tile.width * 0.226)
    NSGradient(colors: [NSColor(srgbRed: 0.984, green: 0.988, blue: 1, alpha: 1),
                        NSColor(srgbRed: 0.910, green: 0.933, blue: 0.984, alpha: 1)])!
        .draw(in: path, angle: -90)
    // Mark: 60% of the tile width, centred (74/124 ≈ 0.6 in the sheet).
    let markW = tile.width * 0.6
    let markH = markW * 44 / 56
    drawMark(in: NSRect(x: tile.midX - markW / 2, y: tile.midY - markH / 2,
                        width: markW, height: markH), canvas: s)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let iconset = URL(fileURLWithPath: "tools/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32),
                   ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                   ("icon_256x256", 256), ("icon_256x256@2x", 512),
                   ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    iconPNG(px, to: iconset.appendingPathComponent("\(name).png"))
}

// DMG background: the soft gradient, no instruction text (7h — the app
// catches the run-from-DMG case itself). 600×400 at 1x/2x.
func dmgPNG(scale: Int, to url: URL) {
    let w = 600 * scale, h = 400 * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGradient(colors: [NSColor(srgbRed: 0.933, green: 0.953, blue: 0.992, alpha: 1),
                        NSColor(srgbRed: 0.973, green: 0.980, blue: 0.996, alpha: 1)])!
        .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)
    // The connecting arrow between the two icon wells (150,185)→(450,185) in
    // create-dmg's top-left coordinates → y = 400-185 = 215 bottom-left.
    let y = CGFloat(215 * scale)
    let arrow = NSBezierPath()
    arrow.lineWidth = CGFloat(2 * scale)
    arrow.lineCapStyle = .round
    arrow.move(to: NSPoint(x: CGFloat(240 * scale), y: y))
    arrow.line(to: NSPoint(x: CGFloat(360 * scale), y: y))
    arrow.move(to: NSPoint(x: CGFloat(342 * scale), y: y + CGFloat(14 * scale)))
    arrow.line(to: NSPoint(x: CGFloat(360 * scale), y: y))
    arrow.line(to: NSPoint(x: CGFloat(342 * scale), y: y - CGFloat(14 * scale)))
    blue.withAlphaComponent(0.55).setStroke()
    arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}
dmgPNG(scale: 1, to: URL(fileURLWithPath: "tools/dmg-bg.png"))
dmgPNG(scale: 2, to: URL(fileURLWithPath: "tools/dmg-bg@2x.png"))
print("assets drawn")

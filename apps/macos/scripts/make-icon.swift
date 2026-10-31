#!/usr/bin/env swift
// Draws the app icon (a light paper tile with a graphite Markdown "#" and an accent-blue text cursor) at every iconset
// size and builds Resources/AppIcon.icns with iconutil. Run from apps/macos: `swift scripts/make-icon.swift`; pass
// `--preview <folder>` to also keep the PNGs there. The result is committed; bundle.sh only copies it.
import AppKit

func grey(_ value: CGFloat, _ alpha: CGFloat = 1) -> CGColor { CGColor(gray: value, alpha: alpha) }

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

/// The macOS app-icon shape: the 824/1024 grid tile with a 185/824 corner radius.
func iconShape(in rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)
}

/// A bar with round ends from `start` to `end`.
func bar(from start: CGPoint, to end: CGPoint, width: CGFloat) -> CGPath {
    let line = CGMutablePath()
    line.move(to: start)
    line.addLine(to: end)
    return line.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)
}

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.clear(CGRect(x: 0, y: 0, width: s, height: s))
    // Small sizes get heavier strokes and no hairlines so the glyph stays legible at 16 and 32 px.
    let small = size <= 32

    // Tile: the macOS icon grid leaves a 100/1024 margin; the shadow sits inside it.
    let tile = CGRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)
    let tilePath = iconShape(in: tile)
    let t = tile.width
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.028, color: grey(0, 0.28))
    context.addPath(tilePath)
    context.setFillColor(grey(0.94))
    context.fillPath()
    context.restoreGState()

    // Paper: a soft top-to-bottom gradient with a faint top highlight and an edge line, the Big Sur depth.
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    context.drawLinearGradient(gradient([grey(1), grey(0.955), grey(0.885)], [0, 0.55, 1]),
                               start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    context.drawRadialGradient(gradient([grey(1, 0.7), grey(1, 0)], [0, 1]),
                               startCenter: CGPoint(x: tile.midX, y: tile.maxY), startRadius: 0,
                               endCenter: CGPoint(x: tile.midX, y: tile.maxY), endRadius: t * 0.75, options: [])
    context.restoreGState()
    if !small {
        context.saveGState()
        context.addPath(tilePath)
        context.setStrokeColor(grey(0, 0.09))
        context.setLineWidth(max(1, s * 0.002))
        context.strokePath()
        context.restoreGState()
    }

    // The "#": two slanted uprights and two crossbars, shifted left to leave room for the cursor. At 16 px it is drawn
    // upright on whole pixels (1 px strokes, 1 px gaps), since anything finer blurs into a blot.
    let center = CGPoint(x: tile.midX - t * 0.075, y: tile.midY)
    let half = t * 0.215, gap = t * 0.1, slant = t * 0.045
    let glyph = CGMutablePath()
    if size == 16 {
        for x in [5, 8] { glyph.addRect(CGRect(x: x, y: 4, width: 1, height: 8)) }
        for y in [6, 9] { glyph.addRect(CGRect(x: 3, y: y, width: 8, height: 1)) }
    } else {
        let stroke = t * (small ? 0.095 : 0.072)
        for dx in [-gap, gap] {
            glyph.addPath(bar(from: CGPoint(x: center.x + dx - slant, y: center.y - half),
                              to: CGPoint(x: center.x + dx + slant, y: center.y + half), width: stroke))
        }
        for dy in [-gap * 0.95, gap * 0.95] {
            glyph.addPath(bar(from: CGPoint(x: center.x - half, y: center.y + dy),
                              to: CGPoint(x: center.x + half, y: center.y + dy), width: stroke))
        }
    }
    let glyphBox = glyph.boundingBoxOfPath
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -s * 0.006), blur: s * 0.014, color: grey(0, 0.22))
    context.addPath(glyph)
    context.setFillColor(grey(0.3))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(glyph)
    context.clip(using: .winding)
    context.drawLinearGradient(gradient([grey(0.36), grey(0.2)], [0, 1]),
                               start: CGPoint(x: 0, y: glyphBox.maxY), end: CGPoint(x: 0, y: glyphBox.minY), options: [])
    context.restoreGState()

    // Text cursor in the default system accent (blue), muted slightly.
    let cursorX = center.x + half + t * (small ? 0.14 : 0.125)
    let cursor = size == 16
        ? CGPath(rect: CGRect(x: 12, y: 4, width: 1, height: 8), transform: nil)
        : bar(from: CGPoint(x: cursorX, y: center.y - half * 1.02), to: CGPoint(x: cursorX, y: center.y + half * 1.02),
              width: t * (small ? 0.07 : 0.042))
    let cursorBox = cursor.boundingBoxOfPath
    context.saveGState()
    context.addPath(cursor)
    context.clip()
    context.drawLinearGradient(gradient([CGColor(srgbRed: 0.2, green: 0.56, blue: 1, alpha: 1),
                                         CGColor(srgbRed: 0.04, green: 0.42, blue: 0.9, alpha: 1)], [0, 1]),
                               start: CGPoint(x: 0, y: cursorBox.maxY), end: CGPoint(x: 0, y: cursorBox.minY), options: [])
    context.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let iconset = fileManager.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconset) }

for base in [16, 32, 128, 256, 512] {
    try draw(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

if let flag = CommandLine.arguments.firstIndex(of: "--preview"), flag + 1 < CommandLine.arguments.count {
    let preview = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    try fileManager.createDirectory(at: preview, withIntermediateDirectories: true)
    for name in try fileManager.contentsOfDirectory(atPath: iconset.path) {
        let target = preview.appendingPathComponent(name)
        try? fileManager.removeItem(at: target)
        try fileManager.copyItem(at: iconset.appendingPathComponent(name), to: target)
    }
}

let resources = root.appendingPathComponent("Resources")
try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
let output = resources.appendingPathComponent("AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")

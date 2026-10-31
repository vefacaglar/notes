#!/usr/bin/env swift
// Draws the app icon (a neutral grey tile with a white page and a few text lines) at every iconset size and builds
// Resources/AppIcon.icns with iconutil. Run from apps/macos: `swift scripts/make-icon.swift`. The result is committed;
// bundle.sh only copies it.
import AppKit

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.clear(CGRect(x: 0, y: 0, width: s, height: s))

    func grey(_ value: CGFloat, _ alpha: CGFloat = 1) -> NSColor { NSColor(deviceWhite: value, alpha: alpha) }

    // Tile: the standard macOS icon grid leaves a 100/1024 margin.
    let tile = CGRect(x: s * 0.098, y: s * 0.098, width: s * 0.804, height: s * 0.804)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: grey(0, 0.35).cgColor)
    grey(0.5).setFill()
    tilePath.fill()
    context.restoreGState()
    NSGradient(starting: grey(0.36), ending: grey(0.22))!.draw(in: tilePath, angle: -90)

    // Page with a folded top-right corner.
    let width = tile.width * 0.5, height = tile.height * 0.62
    let page = CGRect(x: tile.midX - width / 2, y: tile.midY - height / 2, width: width, height: height)
    let fold = width * 0.28
    let pagePath = NSBezierPath()
    pagePath.move(to: CGPoint(x: page.minX, y: page.minY))
    pagePath.line(to: CGPoint(x: page.maxX, y: page.minY))
    pagePath.line(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    pagePath.line(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    pagePath.line(to: CGPoint(x: page.minX, y: page.maxY))
    pagePath.close()
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -s * 0.008), blur: s * 0.02, color: grey(0, 0.3).cgColor)
    grey(0.97).setFill()
    pagePath.fill()
    context.restoreGState()

    let foldPath = NSBezierPath()
    foldPath.move(to: CGPoint(x: page.maxX - fold, y: page.maxY))
    foldPath.line(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold))
    foldPath.line(to: CGPoint(x: page.maxX, y: page.maxY - fold))
    foldPath.close()
    grey(0.8).setFill()
    foldPath.fill()

    // Text lines; the first one is a heading.
    let left = page.minX + width * 0.14
    let lineHeight = height * 0.045
    let rows: [(CGFloat, CGFloat, CGFloat)] = [(0.76, 0.42, 0.34), (0.60, 0.72, 0.62), (0.50, 0.72, 0.62),
                                               (0.40, 0.72, 0.62), (0.30, 0.46, 0.62), (0.20, 0.58, 0.62)]
    for (index, row) in rows.enumerated() {
        let rect = CGRect(x: left, y: page.minY + height * row.0, width: width * row.1, height: index == 0 ? lineHeight * 1.5 : lineHeight)
        grey(index == 0 ? 0.28 : 0.62).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
    }

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

import AppKit
import ImageIO
import NotesCore

/// Decoded, size-limited copies of the image files shown under `![](…)` lines. Images decode off the main thread;
/// a file that changed on disk (checked at most every 2 s per lookup, and whenever a window becomes key) is decoded again.
@MainActor
final class InlineImageCache {
    static let shared = InlineImageCache()

    private struct Entry {
        var image: NSImage?
        var stamp: NoteFile.Stamp?
        var checked: Date
        var loading = false
    }

    private var entries: [URL: Entry] = [:]
    private var order: [URL] = []
    private var waiting: [URL: [@MainActor () -> Void]] = [:]
    private static let capacity = 48
    private nonisolated static let maxFileSize = 64 * 1_048_576
    private static let recheckInterval: TimeInterval = 2

    /// The cached image for `url`, nil while it is loading or when the file is missing or not an image.
    /// `onUpdate` runs once when a (re)load of this file finishes.
    func image(for url: URL, onUpdate: @escaping @MainActor () -> Void) -> NSImage? {
        let now = Date()
        guard var entry = entries[url] else {
            entries[url] = Entry(image: nil, stamp: nil, checked: now)
            order.append(url)
            if order.count > Self.capacity { entries[order.removeFirst()] = nil }
            load(url, onUpdate)
            return nil
        }
        if !entry.loading, now.timeIntervalSince(entry.checked) > Self.recheckInterval {
            entry.checked = now
            entries[url] = entry
            if NoteFile.stamp(url) != entry.stamp { load(url, onUpdate) }
        } else if entry.loading {
            waiting[url, default: []].append(onUpdate)
        }
        return entry.image
    }

    /// The image already in the cache, without starting a load.
    func cachedImage(for url: URL) -> NSImage? { entries[url]?.image }

    /// Makes the next lookup of every file compare its modification stamp.
    func expireChecks() {
        for url in entries.keys { entries[url]?.checked = .distantPast }
    }

    private func load(_ url: URL, _ onUpdate: @escaping @MainActor () -> Void) {
        entries[url]?.loading = true
        waiting[url, default: []].append(onUpdate)
        let stamp = NoteFile.stamp(url)
        Task.detached(priority: .utility) {
            let decoded = Self.decode(url)
            await MainActor.run {
                InlineImageCache.shared.finish(url, stamp: stamp, decoded: decoded)
            }
        }
    }

    private func finish(_ url: URL, stamp: NoteFile.Stamp?, decoded: Decoded?) {
        guard entries[url] != nil else { waiting[url] = nil; return }
        entries[url]?.loading = false
        entries[url]?.stamp = stamp
        entries[url]?.checked = Date()
        if let decoded {
            entries[url]?.image = NSImage(cgImage: decoded.image, size: decoded.pointSize)
        } else {
            entries[url]?.image = nil
        }
        let callbacks = waiting.removeValue(forKey: url) ?? []
        callbacks.forEach { $0() }
    }

    private struct Decoded: @unchecked Sendable {
        let image: CGImage
        let pointSize: NSSize
    }

    /// A thumbnail of at most 2400 px on its longest side (EXIF orientation applied), sized in points from the file's DPI.
    private nonisolated static func decode(_ url: URL) -> Decoded? {
        guard let size = NoteFile.size(url), size <= maxFileSize,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 2400,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0, image.height > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth = (properties?[kCGImagePropertyPixelWidth] as? Double) ?? Double(image.width)
        let pixelHeight = (properties?[kCGImagePropertyPixelHeight] as? Double) ?? Double(image.height)
        // The thumbnail may be smaller than the file: scale its point size back up to the original's.
        let shrink = max(pixelWidth, pixelHeight) / Double(max(image.width, image.height))
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        let density = dpi >= 72 ? min(dpi / 72, 4) : 1
        let scale = max(shrink, 1) / density
        return Decoded(image: image, pointSize: NSSize(width: Double(image.width) * scale, height: Double(image.height) * scale))
    }
}

/// The `![](…)` images of one source line: shown stacked under it.
struct InlineImageSlot: Equatable {
    /// The line through its line break (UTF-16).
    var paragraph: NSRange
    /// Index of the last character of the line's text, which locates its last line fragment.
    var anchor: Int
    var destinations: [String]
    var urls: [URL?] = []
}

enum InlineImageLayout {
    static let maxHeight: CGFloat = 420
    static let gap: CGFloat = 6

    /// Displayed size: natural size, shrunk to fit `width` and `maxHeight`, aspect kept.
    static func size(of natural: NSSize, fitting width: CGFloat) -> NSSize {
        guard natural.width > 0, natural.height > 0, width > 0 else { return .zero }
        let scale = min(1, width / natural.width, maxHeight / natural.height)
        return NSSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
    }

    /// Extra space to reserve below the line for images of these `sizes` (0 when there is none).
    static func reservedHeight(_ sizes: [NSSize]) -> CGFloat {
        let shown = sizes.filter { $0.height > 0 }
        return shown.isEmpty ? 0 : shown.reduce(gap) { $0 + $1.height + gap }
    }
}

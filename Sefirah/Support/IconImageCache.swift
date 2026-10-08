import AppKit

/// Decodes small PNG payloads (app icons, notification artwork, media art) once and caches the
/// images by content, so SwiftUI re-renders and list scrolling never re-decode the same data.
@MainActor
enum IconImageCache {
    private static let images = NSCache<NSString, NSImage>()

    static func image(for data: Data?, key: String) -> NSImage? {
        guard let data else { return nil }
        let cacheKey = "\(key)#\(data.count)#\(data.hashValue)" as NSString
        if let cached = images.object(forKey: cacheKey) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        images.setObject(image, forKey: cacheKey)
        return image
    }
}

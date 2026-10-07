import AppKit
import Foundation

/// Sefirah's phone mark: the menu bar panel's header tile — a black rounded square with the
/// iPhone glyph. Shared by the external-scrcpy wrapper, its `SCRCPY_ICON_DIR` icons and the
/// macOS notification attachments.
enum SefirahIcon {
    /// Renders the mark at `pixels`×`pixels`.
    static func bitmap(pixels: Int) -> NSBitmapImageRep? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = NSSize(width: pixels, height: pixels)
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.shouldAntialias = true

        let side = CGFloat(pixels)
        let margin = side * 0.085
        let tile = NSRect(x: margin, y: margin, width: side - 2 * margin, height: side - 2 * margin)
        let radius = tile.width * 0.2237

        NSColor.black.setFill()
        NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius).fill()

        NSColor.white.withAlphaComponent(0.14).setStroke()
        let border = NSBezierPath(roundedRect: tile.insetBy(dx: side * 0.004, dy: side * 0.004), xRadius: radius, yRadius: radius)
        border.lineWidth = max(1, side * 0.008)
        border.stroke()

        let configuration = NSImage.SymbolConfiguration(hierarchicalColor: .white)
        if let symbol = NSImage(systemSymbolName: "iphone.gen3", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        {
            let symbolSize = symbol.size
            let scale = min((tile.width * 0.72) / symbolSize.width, (tile.height * 0.72) / symbolSize.height)
            let drawSize = NSSize(width: symbolSize.width * scale, height: symbolSize.height * scale)
            let origin = NSPoint(x: tile.midX - drawSize.width / 2, y: tile.midY - drawSize.height / 2)
            symbol.draw(in: NSRect(origin: origin, size: drawSize), from: .zero, operation: .sourceOver, fraction: 1)
        }

        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
}

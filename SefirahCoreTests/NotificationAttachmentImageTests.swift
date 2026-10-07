import AppKit
import SefirahCore
import XCTest

final class NotificationAttachmentImageTests: XCTestCase {
    private func samplePNG() throws -> Data {
        try imagePNG(size: 2) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
        }
    }

    private func imagePNG(size: Int, draw: (NSRect) -> Void) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testDecodesBase64PNG() throws {
        let png = try samplePNG()
        let decoded = NotificationAttachmentImage.decode(png.base64EncodedString())
        XCTAssertEqual(decoded?.fileExtension, "png")
        XCTAssertEqual(decoded?.data, png)
    }

    func testAcceptsDataURLPrefix() throws {
        let png = try samplePNG()
        let decoded = NotificationAttachmentImage.decode("data:image/png;base64,\(png.base64EncodedString())")
        XCTAssertEqual(decoded?.data, png)
    }

    func testRejectsNonImageData() {
        XCTAssertNil(NotificationAttachmentImage.decode(""))
        XCTAssertNil(NotificationAttachmentImage.decode("not an image"))
        XCTAssertNil(NotificationAttachmentImage.decode(Data("hello world".utf8).base64EncodedString()))
        XCTAssertNil(NotificationAttachmentImage.decodeAsAppIcon("not an image"))
    }

    /// Full-bleed artwork: the square is masked into the iOS squircle (corners become transparent)
    /// while the edges stay covered.
    func testAppIconRenderMasksToSquircle() throws {
        let source = try imagePNG(size: 128) { rect in
            NSColor.systemRed.setFill()
            rect.fill()
        }
        let rendered = try XCTUnwrap(NotificationAttachmentImage.decodeAsAppIcon(source.base64EncodedString(), size: 256))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: rendered))
        XCTAssertEqual(rep.pixelsWide, 256)
        XCTAssertEqual(rep.pixelsHigh, 256)

        let corner = try XCTUnwrap(rep.colorAt(x: 2, y: 2))
        XCTAssertLessThan(corner.alphaComponent, 0.05)

        let center = try XCTUnwrap(rep.colorAt(x: 128, y: 128))
        XCTAssertGreaterThan(center.alphaComponent, 0.95)

        let edge = try XCTUnwrap(rep.colorAt(x: 4, y: 128))
        XCTAssertGreaterThan(edge.alphaComponent, 0.95)
    }

    /// A launcher-style circular icon gets upscaled so its artwork fills the squircle's corners
    /// instead of leaving the phone's circle shape visible.
    func testAppIconRenderFillsCornersFromCircularSource() throws {
        let source = try imagePNG(size: 128) { rect in
            NSColor.systemTeal.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
        let rendered = try XCTUnwrap(NotificationAttachmentImage.decodeAsAppIcon(source.base64EncodedString(), size: 256))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: rendered))

        // Inside the squircle (per-axis extent ~0.435 of the side) but outside the source circle
        // (radius 0.5 of the side): only corner-filling makes this pixel opaque.
        let filledCorner = try XCTUnwrap(rep.colorAt(x: 228, y: 228))
        XCTAssertGreaterThan(filledCorner.alphaComponent, 0.5)

        let outside = try XCTUnwrap(rep.colorAt(x: 2, y: 2))
        XCTAssertLessThan(outside.alphaComponent, 0.05)
    }
}

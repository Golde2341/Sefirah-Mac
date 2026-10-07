import AppKit
import SefirahCore
import XCTest

final class NotificationAttachmentImageTests: XCTestCase {
    private func samplePNG() throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
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
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
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
    }
}

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decodes the base64 images carried in Android notification payloads (`largeIcon`, `appIcon`)
/// and, for display, re-renders them as iOS-style app icons: the content is centred, cropped to a
/// square, scaled so it covers the squircle's corners whatever launcher shape the phone baked in
/// (circle, rounded square, …), then masked with the iOS icon shape.
public enum NotificationAttachmentImage {
    public struct Decoded: Equatable, Sendable {
        public var data: Data
        public var fileExtension: String

        public init(data: Data, fileExtension: String) {
            self.data = data
            self.fileExtension = fileExtension
        }
    }

    /// Decodes a base64 image, tolerating whitespace and an optional `data:` URL prefix.
    public static func decode(_ string: String) -> Decoded? {
        var base64 = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if base64.hasPrefix("data:"), let comma = base64.firstIndex(of: ",") {
            base64 = String(base64[base64.index(after: comma)...])
        }
        guard !base64.isEmpty,
              let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]),
              !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let typeIdentifier = CGImageSourceGetType(source),
              let fileExtension = UTType(typeIdentifier as String)?.preferredFilenameExtension
        else { return nil }
        return Decoded(data: data, fileExtension: fileExtension)
    }

    /// Decodes a base64 image and renders it as an iOS-style (squircle) app icon, returning PNG
    /// data. Used for the notification attachment so icons look consistent across phones.
    public static func decodeAsAppIcon(_ string: String, size: Int = 512) -> Data? {
        guard let decoded = decode(string),
              let source = CGImageSourceCreateWithData(decoded.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return renderAppIcon(image, size: size)
    }

    static func renderAppIcon(_ image: CGImage, size: Int = 512) -> Data? {
        let side = CGFloat(size)
        let square = squareCropped(image)
        let scale = cornerFillScale(for: square)
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.addPath(squirclePath(in: CGRect(x: 0, y: 0, width: side, height: side)))
        context.clip()
        let drawn = side * scale
        let origin = (side - drawn) / 2
        context.draw(square, in: CGRect(x: origin, y: origin, width: drawn, height: drawn))
        guard let output = context.makeImage() else { return nil }
        return pngData(from: output)
    }

    private static func squareCropped(_ image: CGImage) -> CGImage {
        let side = min(image.width, image.height)
        let crop = CGRect(
            x: (image.width - side) / 2,
            y: (image.height - side) / 2,
            width: side,
            height: side
        )
        return image.cropping(to: crop) ?? image
    }

    /// Scale needed so the artwork's opaque content reaches the squircle's corners. A circular
    /// launcher icon measures ~0.5 (gets upscaled ~1.23×, cropping its background ring so the
    /// squircle is filled); squares and squircles already reach the corners and stay unchanged.
    private static func cornerFillScale(for image: CGImage) -> CGFloat {
        let sample = 64
        guard let context = CGContext(
            data: nil,
            width: sample,
            height: sample,
            bitsPerComponent: 8,
            bytesPerRow: sample * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 1 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: sample, height: sample))
        guard let data = context.data else { return 1 }
        let pixels = data.bindMemory(to: UInt8.self, capacity: sample * sample * 4)
        let center = sample / 2

        var extents: [CGFloat] = []
        for (dx, dy) in [(1, 1), (1, -1), (-1, 1), (-1, -1)] {
            var lastOpaque = 0
            var step = 0
            while true {
                let x = center + dx * step
                let y = center + dy * step
                guard x >= 0, y >= 0, x < sample, y < sample else { break }
                if pixels[(y * sample + x) * 4 + 3] > 120 {
                    lastOpaque = step
                }
                step += 1
            }
            // Diagonal distance from the centre, in units where the side is 1.
            extents.append(CGFloat(lastOpaque) * sqrt(2) / CGFloat(sample))
        }

        let measured = extents.reduce(0, +) / CGFloat(extents.count)
        guard measured > 0.01 else { return 1 }
        // Squircle (superellipse n=5) corner tip is ~0.616 of the side from the centre.
        let squircleCorner: CGFloat = 0.6156
        return min(max(squircleCorner / measured, 1), 1.35)
    }

    /// iOS-style icon shape: a superellipse (squircle) close to Apple's continuous-corner mask.
    private static func squirclePath(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
        let path = CGMutablePath()
        let a = rect.width / 2
        let b = rect.height / 2
        let steps = 360
        for index in 0...steps {
            let t = CGFloat(index) / CGFloat(steps) * 2 * .pi
            let cosT = cos(t)
            let sinT = sin(t)
            let x = rect.midX + a * copysign(pow(abs(cosT), 2 / exponent), cosT)
            let y = rect.midY + b * copysign(pow(abs(sinT), 2 / exponent), sinT)
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        path.closeSubpath()
        return path
    }

    private static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

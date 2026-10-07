import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decodes the base64 images carried in Android notification payloads (`largeIcon`, `appIcon`)
/// into raw image data ready to be written to disk for use as a notification attachment.
/// Returns `nil` for missing or unsupported data so callers can drop the image without
/// affecting the notification itself.
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
}

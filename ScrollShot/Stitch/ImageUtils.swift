import AppKit
import CoreGraphics

enum ImageUtilsError: LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "无法编码为 PNG。"
        }
    }
}

/// Image conversion / export helpers. (Stitching itself arrives with scroll mode.)
enum ImageUtils {
    static func nsImage(from cgImage: CGImage) -> NSImage {
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Writes the image to the user-configured save directory (default: ~/Desktop)
    /// with a timestamped name and returns the URL.
    @discardableResult
    static func saveToDesktop(_ cgImage: CGImage, date: Date = Date()) throws -> URL {
        let url = AppConfig.saveDirectory.appendingPathComponent(AppConfig.defaultFileName(date: date))
        try savePNG(cgImage, to: url)
        return url
    }

    static func pngData(from cgImage: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }

    static func savePNG(_ cgImage: CGImage, to url: URL) throws {
        guard let data = pngData(from: cgImage) else { throw ImageUtilsError.encodingFailed }
        try data.write(to: url, options: .atomic)
    }

    @discardableResult
    static func copyToPasteboard(_ cgImage: CGImage) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([nsImage(from: cgImage)])
    }

    /// Produces a blocky, pixelated copy of `image` (downscale + nearest-neighbour
    /// upscale) for mosaic / redaction.
    static func pixelated(_ image: CGImage, blockSize: Int = 12) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        let smallWidth = max(1, width / max(1, blockSize))
        let smallHeight = max(1, height / max(1, blockSize))
        guard let small = scale(image, width: smallWidth, height: smallHeight, interpolation: .medium) else {
            return nil
        }
        return scale(small, width: width, height: height, interpolation: .none)
    }

    static func scale(
        _ image: CGImage,
        width: Int,
        height: Int,
        interpolation: CGInterpolationQuality
    ) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = interpolation
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

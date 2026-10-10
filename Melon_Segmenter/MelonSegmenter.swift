import UIKit
import SAMKit

enum MelonSegmenterError: Error {
    case cgImageUnavailable
    case noMask
    case renderFailed
}

/// Wraps SamKit's MobileSAM session to turn a tap point on a photo into a
/// cropped, transparent-background cutout of the tapped object.
/// Not thread-safe for concurrent calls; the caller is expected to run one
/// segmentation at a time (e.g. from a single background Task).
final class MelonSegmenter {
    private var session: SamSession?

    func segment(image: UIImage, tapPoint: CGPoint) throws -> UIImage {
        guard let cgImage = image.cgImage else { throw MelonSegmenterError.cgImageUnavailable }

        let session = try loadedSession()
        try session.setImage(cgImage)

        let point = SamPoint(x: tapPoint.x, y: tapPoint.y, label: .positive)
        let result = try session.predict(points: [point])

        guard let mask = result.masks.first else {
            throw MelonSegmenterError.noMask
        }

        let cutout = try Self.applyMask(mask.cgImage, to: cgImage)
        return Self.cropToOpaqueBounds(cutout) ?? UIImage(cgImage: cutout)
    }

    private func loadedSession() throws -> SamSession {
        if let session { return session }
        // MobileSAM's ImageEncoder/MaskDecoder .mlpackage files must be added
        // to the app target (see SamKit release assets) for `.bundled(.mobileSam)`
        // to resolve.
        let newSession = try SamSession(model: .bundled(.mobileSam), config: .bestAvailable)
        session = newSession
        return newSession
    }

    /// Draws `cgImage` clipped to `maskCGImage`, producing an image with
    /// transparent pixels anywhere the mask is zero.
    private static func applyMask(_ maskCGImage: CGImage, to cgImage: CGImage) throws -> CGImage {
        let width = cgImage.width
        let height = cgImage.height
        let rect = CGRect(x: 0, y: 0, width: width, height: height)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw MelonSegmenterError.renderFailed }

        context.clip(to: rect, mask: maskCGImage)
        context.draw(cgImage, in: rect)

        guard let result = context.makeImage() else { throw MelonSegmenterError.renderFailed }
        return result
    }

    /// Crops to the bounding box of non-transparent pixels so the uploaded
    /// image is just the melon, not the full photo frame.
    private static func cropToOpaqueBounds(_ cgImage: CGImage) -> UIImage? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }

        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow
        // Alpha is the last component for premultipliedLast layout.
        let alphaOffset = bytesPerPixel - 1

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width {
                let alpha = bytes[rowStart + x * bytesPerPixel + alphaOffset]
                if alpha > 10 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }

        guard maxX >= minX, maxY >= minY else { return nil }

        let cropRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
        return UIImage(cgImage: cropped)
    }
}

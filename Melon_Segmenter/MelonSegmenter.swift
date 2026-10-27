import UIKit
import SAMKit

enum MelonSegmenterError: Error {
    case cgImageUnavailable
    case noMask
    case renderFailed
}

/// Wraps SamKit's MobileSAM session to turn a tap point on a photo into a
/// cropped, transparent-background cutout of the tapped object.
///
/// An `actor` rather than a plain class: this serializes access
/// automatically (satisfying the original "not thread-safe for concurrent
/// calls" requirement) *and* moves execution off the main actor by default.
/// As a plain class called from a non-detached `Task { }` inside a
/// MainActor-isolated SwiftUI view, SAM's synchronous CoreML inference ran
/// on the main thread and blocked the UI; an actor's isolated methods run on
/// its own executor instead.
actor MelonSegmenter {
    private var session: SamSession?

    /// Identity + downscaled-CGImage cache, keyed on the caller's original
    /// `UIImage` reference. Retrying a tap on the *same* photo (e.g. the
    /// SegmentationView "Try Again" button) previously re-ran `setImage`
    /// every time, needlessly re-encoding with the heavy ViT encoder.
    private var cachedImage: UIImage?
    private var cachedCGImage: CGImage?
    private var cachedScale: CGFloat = 1.0

    /// Longest-side cap applied before handing a photo to SAM. Cuts encoder
    /// latency substantially on A15; verify on-device that the resulting
    /// mask is visually unchanged before relying on this.
    private static let maxLongSide: CGFloat = 2048

    func segment(image: UIImage, tapPoint: CGPoint) throws -> UIImage {
        let session = try loadedSession()

        let cgImage: CGImage
        let scale: CGFloat
        if cachedImage === image, let existingCGImage = cachedCGImage {
            cgImage = existingCGImage
            scale = cachedScale
        } else {
            let (scaledImage, computedScale) = Self.downscaledIfNeeded(image)
            guard let scaledCGImage = scaledImage.cgImage else { throw MelonSegmenterError.cgImageUnavailable }
            try session.setImage(scaledCGImage)
            cachedImage = image
            cachedCGImage = scaledCGImage
            cachedScale = computedScale
            cgImage = scaledCGImage
            scale = computedScale
        }

        let scaledTapPoint = CGPoint(x: tapPoint.x * scale, y: tapPoint.y * scale)
        let point = SamPoint(x: scaledTapPoint.x, y: scaledTapPoint.y, label: .positive)
        let result = try session.predict(points: [point])

        guard let mask = result.masks.first else {
            throw MelonSegmenterError.noMask
        }

        let cutout = try Self.applyMask(mask, to: cgImage)
        let cropped = Self.cropToOpaqueBounds(cutout)
        return cropped ?? UIImage(cgImage: cutout)
    }

    private func loadedSession() throws -> SamSession {
        if let session { return session }
        // MobileSAM's ImageEncoder/MaskDecoder .mlpackage files must be added
        // to the app target (see SamKit release assets) for `.bundled(.mobileSam)`
        // to resolve.
        let newSession = try SamSession(model: .bundled(.mobileSam), config: RuntimeConfig(computeUnits: .gpuPreferred, enableFP16: true))
        session = newSession
        return newSession
    }

    /// Returns `image` unchanged (scale 1.0) if its longest side is already
    /// within `maxLongSide`, otherwise a downscaled copy and the scale
    /// factor applied (so callers can map prompt coordinates accordingly).
    private static func downscaledIfNeeded(_ image: UIImage) -> (UIImage, CGFloat) {
        let longSide = max(image.size.width, image.size.height)
        guard longSide > maxLongSide else { return (image, 1.0) }

        let scale = maxLongSide / longSide
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        let scaledImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
        return (scaledImage, scale)
    }

    /// Draws `cgImage` clipped to `maskCGImage`, producing an image with
    /// transparent pixels anywhere the mask is zero.
    private static func applyMask(_ mask: SamMask, to cgImage: CGImage) throws -> CGImage {
        // `mask.cgImage` is a colored RGBA overlay, which CGContext.clip(to:mask:)
        // can't use (it needs grayscale) and silently clips everything away.
        // Build a proper DeviceGray mask from the raw alpha bytes instead.
        guard mask.alpha.count >= mask.width * mask.height,
              let provider = CGDataProvider(data: mask.alpha as CFData),
              let maskCGImage = CGImage(
                width: mask.width,
                height: mask.height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: mask.width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { throw MelonSegmenterError.renderFailed }

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

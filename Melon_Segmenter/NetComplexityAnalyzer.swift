import UIKit
import CoreGraphics

struct NetComplexityMetrics {
    let nodeCount: Int
    let edgeCount: Int
    let netComplexityIndex: Double
}

enum NetComplexityAnalyzerError: LocalizedError {
    case invalidImage
    case notEnoughTexture

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "Gambar hasil segmentasi tidak valid."
        case .notEnoughTexture:
            return "Tidak cukup tekstur net yang terdeteksi untuk dianalisis."
        }
    }
}

/// Samples points from the net/netting texture inside a segmented melon
/// cutout (weighted by edge density, not the plain silhouette), trains a
/// `GrowingNeuralGas` graph over them, and renders a visualization overlay.
enum NetComplexityAnalyzer {
    private static let erosionIterations = 10
    private static let sampleCount = 4000

    static func analyze(segmentedImage: UIImage, maxNodes: Int = 3000) async throws -> (metrics: NetComplexityMetrics, visualization: UIImage) {
        try await Task.detached(priority: .userInitiated) {
            try performAnalysis(segmentedImage: segmentedImage, maxNodes: maxNodes)
        }.value
    }

    private static func performAnalysis(segmentedImage: UIImage, maxNodes: Int) throws -> (metrics: NetComplexityMetrics, visualization: UIImage) {
        guard let cgImage = segmentedImage.cgImage,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            throw NetComplexityAnalyzerError.invalidImage
        }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 2, height > 2 else { throw NetComplexityAnalyzerError.invalidImage }

        // MelonSegmenter always produces premultiplied-last RGBA8 output, so
        // byte order is guaranteed: R, G, B, A.
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow

        var alphaMask = [Bool](repeating: false, count: width * height)
        var luminance = [Double](repeating: 0, count: width * height)

        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width {
                let o = rowStart + x * bytesPerPixel
                let idx = y * width + x
                alphaMask[idx] = bytes[o + 3] > 10
                luminance[idx] = 0.299 * Double(bytes[o]) + 0.587 * Double(bytes[o + 1]) + 0.114 * Double(bytes[o + 2])
            }
        }

        let erodedMask = erode(alphaMask, width: width, height: height, iterations: erosionIterations)

        var magnitude = [Double](repeating: 0, count: width * height)
        var total: Double = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let idx = y * width + x
                guard erodedMask[idx] else { continue }

                let gx =
                    -luminance[idx - width - 1] + luminance[idx - width + 1]
                    - 2 * luminance[idx - 1] + 2 * luminance[idx + 1]
                    - luminance[idx + width - 1] + luminance[idx + width + 1]
                let gy =
                    -luminance[idx - width - 1] - 2 * luminance[idx - width] - luminance[idx - width + 1]
                    + luminance[idx + width - 1] + 2 * luminance[idx + width] + luminance[idx + width + 1]

                let m = (gx * gx + gy * gy).squareRoot()
                magnitude[idx] = m
                total += m
            }
        }

        guard total > 0 else { throw NetComplexityAnalyzerError.notEnoughTexture }

        var prefixSum = [Double](repeating: 0, count: magnitude.count)
        var running: Double = 0
        for i in magnitude.indices {
            running += magnitude[i]
            prefixSum[i] = running
        }

        var sampledPoints: [CGPoint] = []
        sampledPoints.reserveCapacity(sampleCount)
        for _ in 0..<sampleCount {
            let target = Double.random(in: 0..<total)
            let idx = binarySearch(prefixSum, target: target)
            sampledPoints.append(CGPoint(x: Double(idx % width), y: Double(idx / width)))
        }

        guard sampledPoints.count >= 2 else { throw NetComplexityAnalyzerError.notEnoughTexture }

        var config = GNGConfig()
        config.maxNodes = maxNodes
        let gng = GrowingNeuralGas(config: config)
        gng.train(points: sampledPoints)

        let netComplexityIndex = (Double(gng.nodeCount) / Double(maxNodes) * 1000).rounded() / 10

        let metrics = NetComplexityMetrics(
            nodeCount: gng.nodeCount,
            edgeCount: gng.edgeCount,
            netComplexityIndex: netComplexityIndex
        )

        let edgeMapImage = edgeMagnitudeImage(magnitude: magnitude, width: width, height: height)

        let visualization = renderVisualization(
            baseImage: segmentedImage,
            edgeMapImage: edgeMapImage,
            pixelSize: CGSize(width: width, height: height),
            positions: gng.positions,
            edges: gng.edgeList
        )

        return (metrics, visualization)
    }

    /// Converts the raw Sobel magnitude map into a viewable grayscale image,
    /// so the GNG overlay can sit on top of "where the net was actually
    /// detected" instead of the color photo.
    private static func edgeMagnitudeImage(magnitude: [Double], width: Int, height: Int) -> UIImage {
        let maxMagnitude = magnitude.max() ?? 0
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        if maxMagnitude > 0 {
            for i in magnitude.indices {
                let value = UInt8(max(0, min(255, (magnitude[i] / maxMagnitude) * 255)))
                let o = i * 4
                rgba[o] = value
                rgba[o + 1] = value
                rgba[o + 2] = value
                rgba[o + 3] = 255
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = context.makeImage() else {
            return UIImage()
        }
        return UIImage(cgImage: cgImage)
    }

    private static func erode(_ mask: [Bool], width: Int, height: Int, iterations: Int) -> [Bool] {
        var current = mask
        for _ in 0..<iterations {
            var next = current
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let idx = y * width + x
                    guard current[idx] else { continue }
                    if !current[idx - 1] || !current[idx + 1] || !current[idx - width] || !current[idx + width] {
                        next[idx] = false
                    }
                }
            }
            current = next
        }
        return current
    }

    private static func binarySearch(_ prefixSum: [Double], target: Double) -> Int {
        var low = 0
        var high = prefixSum.count - 1
        while low < high {
            let mid = (low + high) / 2
            if prefixSum[mid] < target {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// Renders the melon image and the GNG topology as two side-by-side
    /// panels (not overlaid). The right panel sits on the Sobel edge-magnitude
    /// map (grayscale) rather than the color photo, so the graph stays
    /// legible and shows exactly where the net texture was detected before
    /// GNG ran, instead of competing with melon skin color.
    private static func renderVisualization(
        baseImage: UIImage,
        edgeMapImage: UIImage,
        pixelSize: CGSize,
        positions: [CGPoint],
        edges: [(Int, Int)]
    ) -> UIImage {
        let gap: CGFloat = pixelSize.width * 0.04
        let canvasSize = CGSize(width: pixelSize.width * 2 + gap, height: pixelSize.height)
        let graphOrigin = CGPoint(x: pixelSize.width + gap, y: 0)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)

        return renderer.image { rendererContext in
            let cgContext = rendererContext.cgContext
            let backgroundColor = UIColor(red: 0.03, green: 0.08, blue: 0.13, alpha: 1)
            backgroundColor.setFill()
            cgContext.fill(CGRect(origin: .zero, size: canvasSize))

            baseImage.draw(in: CGRect(origin: .zero, size: pixelSize))
            edgeMapImage.draw(in: CGRect(origin: graphOrigin, size: pixelSize))

            let yellow = UIColor(red: 1.0, green: 0.84, blue: 0.0, alpha: 1.0)
            cgContext.saveGState()
            cgContext.translateBy(x: graphOrigin.x, y: graphOrigin.y)

            cgContext.setStrokeColor(yellow.cgColor)
            cgContext.setLineWidth(2.5)
            for (a, b) in edges where a < positions.count && b < positions.count {
                cgContext.move(to: positions[a])
                cgContext.addLine(to: positions[b])
            }
            cgContext.strokePath()

            cgContext.setFillColor(yellow.cgColor)
            let radius: CGFloat = 3.0
            for p in positions {
                cgContext.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
            }
            cgContext.restoreGState()
        }
    }
}

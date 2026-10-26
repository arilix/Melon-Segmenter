import UIKit
import CoreGraphics
import Foundation

/// Area-normalized net/skin metrics for one segmented melon cutout.
/// Replaces the old pixel-distance-based `NetComplexityMetrics`, which
/// wasn't comparable across photos taken at different distances/resolutions.
struct NetDensityMetrics {
    /// Total GNG node count (unaffected by triangle pruning, which only
    /// removes edges).
    let nodeCount: Int
    /// Edge count after triangle pruning.
    let prunedEdgeCount: Int
    /// Pixel area of the (eroded) ROI used to normalize the two density
    /// metrics below — this is what makes them comparable across photos.
    let roiAreaPx: Int
    /// Nodes with degree ≥ 3 in the triangle-pruned graph, per 1e4 px² of ROI.
    let branchDensity: Double
    /// Total pruned-edge length (px), per 1e3 px² of ROI.
    let lengthDensity: Double
    /// Fraction of the ROI classified as net/texture ("data") pixels.
    let dataFractionOfROI: Double
    /// Estimated average net stroke width in px: data pixel area divided by
    /// the pruned graph's total edge length, i.e. treating the GNG graph as
    /// an approximate skeleton/centerline of the net and the data mask as a
    /// constant-width band around it (area ≈ width × length).
    let strokeWidthPx: Double
    /// Equivalent diameter (px) the cutout was normalized to before analysis.
    let dEq: Double
    /// Mean CIE Lab over the ROI.
    let meanL: Double
    let meanA: Double
    let meanB: Double
    /// Which threshold polarity produced this result (dark-net-on-light-skin
    /// vs light-net-on-dark-skin).
    let invertPolarity: Bool
}

/// The per-stage debug images shown in the analysis UI, mirroring the
/// reference desktop tool's 6-panel breakdown (the 6th panel is the
/// `NetDensityMetrics` text summary, rendered natively rather than baked
/// into an image).
struct NetDensityVisualization {
    /// Panel 1: the scale-normalized cutout, unmodified.
    let segmentation: UIImage
    /// Panel 2: the grayscale buffer.
    let grayscale: UIImage
    /// Panel 3: the small (σ=1px) masked Gaussian blur.
    let blur: UIImage
    /// Panel 4: the binary "data" mask (net pixels) inside the ROI.
    let binary: UIImage
    /// Panel 5: the triangle-pruned GNG graph overlaid on the cutout.
    let gngOverlay: UIImage
}

enum NetDensityAnalyzerError: LocalizedError {
    case invalidImage
    case notEnoughTexture

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "The segmented image is invalid."
        case .notEnoughTexture:
            return "Not enough net texture was detected to analyze."
        }
    }
}

/// Normalizes a segmented melon cutout to a fixed equivalent diameter, then
/// measures net/skin density in a way that's comparable across photos taken
/// at different distances or resolutions:
///
/// 1. Crop to the mask's bounding box, resize so the mask's equivalent
///    circular diameter is ~700px (capped at 4× upscale).
/// 2. Erode the mask by 4% of that diameter via a two-pass chamfer distance
///    transform (O(n), not iterative copy-the-whole-array erosion) to get
///    the ROI used for every area-normalized metric below.
/// 3. Masked (normalized-convolution) Gaussian blur, σ=1px, to denoise
///    without bleeding in the transparent background.
/// 4. Adaptive threshold against a much-larger masked blur (σ=2% of the
///    diameter, computed via a box-blur Gaussian approximation over an
///    integral image so the cost is independent of the (large) radius) to
///    find net/texture pixels, with a togglable polarity.
/// 5. Uniformly (not weighted) subsample those pixels with a seeded RNG,
///    train the existing `GrowingNeuralGas` (DBL-GNG) over them, prune
///    "triangle" edges, and report branch/length density per ROI area plus
///    mean Lab color.
enum NetDensityAnalyzer {
    struct Config {
        var targetDiameter: Double = 700
        var maxUpscale: Double = 4.0
        var roiErosionFraction: Double = 0.04
        var smallBlurSigma: Float = 1.0
        var localBlurFraction: Float = 0.02
        var thresholdOffset: Float = 8
        var maxPoints: Int = 6000
        var seed: UInt64 = 0
        var gngConfig = GNGConfig()
    }

    static func analyze(
        segmentedImage: UIImage,
        invertPolarity: Bool,
        config: Config = Config()
    ) async throws -> (metrics: NetDensityMetrics, visualization: NetDensityVisualization) {
        try await Task.detached(priority: .userInitiated) {
            try performAnalysis(segmentedImage: segmentedImage, invertPolarity: invertPolarity, config: config)
        }.value
    }

    private static func performAnalysis(
        segmentedImage: UIImage,
        invertPolarity: Bool,
        config: Config
    ) throws -> (metrics: NetDensityMetrics, visualization: NetDensityVisualization) {
        let clock = ContinuousClock()
        var lastInstant = clock.now
        func lap(_ label: String) {
            let now = clock.now
            print("[NetDensityAnalyzer] \(label): \(now - lastInstant)")
            lastInstant = now
        }

        guard let originalCGImage = segmentedImage.cgImage else {
            throw NetDensityAnalyzerError.invalidImage
        }

        // --- 1. Scale normalization: crop to mask bbox, resize to d_eq ---
        guard let (cropRect, maskAreaPx) = maskBounds(of: originalCGImage) else {
            throw NetDensityAnalyzerError.invalidImage
        }
        guard maskAreaPx > 0, let croppedCGImage = originalCGImage.cropping(to: cropRect) else {
            throw NetDensityAnalyzerError.invalidImage
        }

        let dOrig = 2 * (Double(maskAreaPx) / .pi).squareRoot()
        let scale = min(config.targetDiameter / dOrig, config.maxUpscale)
        let newSize = CGSize(width: Double(croppedCGImage.width) * scale, height: Double(croppedCGImage.height) * scale)
        guard let resizedCGImage = resize(croppedCGImage, to: newSize) else {
            throw NetDensityAnalyzerError.invalidImage
        }
        let dEq = dOrig * scale
        lap("scale normalize (d_orig=\(dOrig), scale=\(scale), d_eq=\(dEq))")

        let width = resizedCGImage.width
        let height = resizedCGImage.height
        guard width > 2, height > 2,
              let data = resizedCGImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            throw NetDensityAnalyzerError.invalidImage
        }
        let bytesPerPixel = resizedCGImage.bitsPerPixel / 8
        let bytesPerRow = resizedCGImage.bytesPerRow

        var mask = [Bool](repeating: false, count: width * height)
        var gray = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width {
                let o = rowStart + x * bytesPerPixel
                let idx = y * width + x
                mask[idx] = bytes[o + 3] > 10
                gray[idx] = 0.299 * Float(bytes[o]) + 0.587 * Float(bytes[o + 1]) + 0.114 * Float(bytes[o + 2])
            }
        }

        // --- 2. ROI via two-pass chamfer distance transform ---
        let distance = chamferDistanceTransform(mask: mask, width: width, height: height)
        let erosionPx = Float(config.roiErosionFraction * dEq)
        var roi = [Bool](repeating: false, count: width * height)
        var roiAreaPx = 0
        for i in roi.indices where mask[i] && distance[i] >= erosionPx {
            roi[i] = true
            roiAreaPx += 1
        }
        guard roiAreaPx > 0 else { throw NetDensityAnalyzerError.notEnoughTexture }
        lap("roi erosion (erosionPx=\(erosionPx), roiAreaPx=\(roiAreaPx))")

        // --- 3 & 4. Masked blur + adaptive threshold ---
        let maskF: [Float] = mask.map { $0 ? 1 : 0 }
        let smallBlur = maskedBlur(gray, maskF: maskF, width: width, height: height) { v, w, h in
            gaussianBlur(v, width: w, height: h, sigma: config.smallBlurSigma)
        }
        let localSigma = config.localBlurFraction * Float(dEq)
        let local = maskedBlur(smallBlur, maskF: maskF, width: width, height: height) { v, w, h in
            approximateGaussianBlur(v, width: w, height: h, sigma: localSigma)
        }

        var data_ = [Bool](repeating: false, count: width * height)
        for i in data_.indices where roi[i] {
            data_[i] = invertPolarity
                ? smallBlur[i] > local[i] + config.thresholdOffset
                : smallBlur[i] < local[i] - config.thresholdOffset
        }
        lap("blur + threshold (localSigma=\(localSigma))")

        // --- 5. Sample, train GNG, prune, measure ---
        var dataIndices: [Int] = []
        for i in data_.indices where data_[i] { dataIndices.append(i) }
        guard !dataIndices.isEmpty else { throw NetDensityAnalyzerError.notEnoughTexture }

        var rng = SeededRandomNumberGenerator(seed: config.seed)
        let sampled = dataIndices.shuffled(using: &rng).prefix(config.maxPoints)
        let points = sampled.map { CGPoint(x: Double($0 % width), y: Double($0 / width)) }
        guard points.count >= 2 else { throw NetDensityAnalyzerError.notEnoughTexture }
        lap("sampling (\(points.count) of \(dataIndices.count) candidate points)")

        let gng = GrowingNeuralGas(config: config.gngConfig)
        gng.train(points: points, rng: &rng)
        let hitNodeBudget = gng.nodeCount >= config.gngConfig.maxNodes
        lap("gng train (nodes=\(gng.nodeCount), edges=\(gng.edgeCount), stoppedGrowing=\(gng.stoppedGrowing), hitNodeBudget=\(hitNodeBudget))")

        let prunedEdgeList = prunedEdges(positions: gng.positions, edges: gng.edgeList)
        lap("triangle pruning (\(gng.edgeCount) -> \(prunedEdgeList.count) edges)")

        var degree = [Int](repeating: 0, count: gng.nodeCount)
        var totalLength: Double = 0
        for (a, b) in prunedEdgeList {
            degree[a] += 1
            degree[b] += 1
            let dx = gng.positions[a].x - gng.positions[b].x
            let dy = gng.positions[a].y - gng.positions[b].y
            totalLength += (dx * dx + dy * dy).squareRoot()
        }
        let branchNodeCount = degree.filter { $0 >= 3 }.count
        let branchDensity = Double(branchNodeCount) / Double(roiAreaPx) * 1e4
        let lengthDensity = totalLength / Double(roiAreaPx) * 1e3
        let dataFractionOfROI = Double(dataIndices.count) / Double(roiAreaPx)
        let strokeWidthPx = totalLength > 0 ? Double(dataIndices.count) / totalLength : 0

        let lab = averageLab(bytes: bytes, bytesPerPixel: bytesPerPixel, bytesPerRow: bytesPerRow, width: width, height: height, mask: roi)
        lap("metrics + color")

        let metrics = NetDensityMetrics(
            nodeCount: gng.nodeCount,
            prunedEdgeCount: prunedEdgeList.count,
            roiAreaPx: roiAreaPx,
            branchDensity: branchDensity,
            lengthDensity: lengthDensity,
            dataFractionOfROI: dataFractionOfROI,
            strokeWidthPx: strokeWidthPx,
            dEq: dEq,
            meanL: lab.L,
            meanA: lab.a,
            meanB: lab.b,
            invertPolarity: invertPolarity
        )

        let pixelSize = CGSize(width: width, height: height)
        let baseImage = UIImage(cgImage: resizedCGImage)
        let visualization = NetDensityVisualization(
            segmentation: baseImage,
            grayscale: renderGrayscaleImage(gray, mask: mask, width: width, height: height),
            blur: renderGrayscaleImage(smallBlur, mask: mask, width: width, height: height),
            binary: renderBinaryImage(data: data_, roi: roi, mask: mask, width: width, height: height),
            gngOverlay: renderVisualization(
                baseImage: baseImage,
                pixelSize: pixelSize,
                positions: gng.positions,
                edges: prunedEdgeList
            )
        )
        lap("visualization")

        return (metrics, visualization)
    }

    // MARK: - Scale normalization

    private static func maskBounds(of cgImage: CGImage) -> (rect: CGRect, maskAreaPx: Int)? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }

        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow
        let alphaOffset = bytesPerPixel - 1

        var minX = width, minY = height, maxX = -1, maxY = -1
        var area = 0
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width {
                if bytes[rowStart + x * bytesPerPixel + alphaOffset] > 10 {
                    area += 1
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return (CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1), area)
    }

    private static func resize(_ cgImage: CGImage, to newSize: CGSize) -> CGImage? {
        let width = max(1, Int(newSize.width.rounded()))
        let height = max(1, Int(newSize.height.rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: - ROI: two-pass chamfer distance transform

    /// Approximate Euclidean distance (in px) from each foreground pixel to
    /// the nearest background pixel, via the classic two-pass chamfer
    /// algorithm (O(n), two raster passes) — replaces the old `erode()`,
    /// which copied the entire mask array on every one of up to 10 iterations.
    private static func chamferDistanceTransform(mask: [Bool], width: Int, height: Int) -> [Float] {
        let big: Float = 1e6
        let diag: Float = 1.4142135
        var dist = [Float](repeating: 0, count: width * height)
        for i in dist.indices { dist[i] = mask[i] ? big : 0 }

        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let idx = row + x
                guard mask[idx] else { continue }
                var best = dist[idx]
                if x > 0 { best = min(best, dist[idx - 1] + 1) }
                if y > 0 { best = min(best, dist[idx - width] + 1) }
                if x > 0, y > 0 { best = min(best, dist[idx - width - 1] + diag) }
                if x < width - 1, y > 0 { best = min(best, dist[idx - width + 1] + diag) }
                dist[idx] = best
            }
        }

        for y in stride(from: height - 1, through: 0, by: -1) {
            let row = y * width
            for x in stride(from: width - 1, through: 0, by: -1) {
                let idx = row + x
                guard mask[idx] else { continue }
                var best = dist[idx]
                if x < width - 1 { best = min(best, dist[idx + 1] + 1) }
                if y < height - 1 { best = min(best, dist[idx + width] + 1) }
                if x < width - 1, y < height - 1 { best = min(best, dist[idx + width + 1] + diag) }
                if x > 0, y < height - 1 { best = min(best, dist[idx + width - 1] + diag) }
                dist[idx] = best
            }
        }
        return dist
    }

    // MARK: - Blur

    /// Normalized convolution: `blur(values·mask) / blur(mask)`, so the
    /// transparent background never bleeds into pixels near the mask edge.
    private static func maskedBlur(
        _ values: [Float], maskF: [Float], width: Int, height: Int,
        blur: ([Float], Int, Int) -> [Float]
    ) -> [Float] {
        var weighted = [Float](repeating: 0, count: values.count)
        for i in weighted.indices { weighted[i] = values[i] * maskF[i] }
        let numerator = blur(weighted, width, height)
        let denominator = blur(maskF, width, height)
        var out = [Float](repeating: 0, count: values.count)
        for i in out.indices { out[i] = denominator[i] > 1e-4 ? numerator[i] / denominator[i] : 0 }
        return out
    }

    /// Small, exact separable Gaussian — cheap enough at σ≈1px without
    /// needing the box-blur approximation below.
    private static func gaussianBlur(_ src: [Float], width: Int, height: Int, sigma: Float) -> [Float] {
        let radius = max(1, Int((sigma * 3).rounded()))
        var kernel = [Float](repeating: 0, count: 2 * radius + 1)
        var sum: Float = 0
        for i in -radius...radius {
            let v = exp(-Float(i * i) / (2 * sigma * sigma))
            kernel[i + radius] = v
            sum += v
        }
        for i in kernel.indices { kernel[i] /= sum }

        let h = convolve1D(src, width: width, height: height, kernel: kernel, horizontal: true)
        return convolve1D(h, width: width, height: height, kernel: kernel, horizontal: false)
    }

    private static func convolve1D(_ src: [Float], width: Int, height: Int, kernel: [Float], horizontal: Bool) -> [Float] {
        let radius = kernel.count / 2
        var out = [Float](repeating: 0, count: src.count)
        for y in 0..<height {
            for x in 0..<width {
                var sum: Float = 0
                for k in -radius...radius {
                    let sampleX = horizontal ? min(max(x + k, 0), width - 1) : x
                    let sampleY = horizontal ? y : min(max(y + k, 0), height - 1)
                    sum += src[sampleY * width + sampleX] * kernel[k + radius]
                }
                out[y * width + x] = sum
            }
        }
        return out
    }

    /// Gaussian approximation via 3 passes of box blur, each computed with
    /// an integral image so the cost is independent of the (large) radius —
    /// σ=2% of a ~700px diameter is a ~14px σ, i.e. a kernel ~85px wide,
    /// far too expensive as a direct separable Gaussian.
    private static func approximateGaussianBlur(_ src: [Float], width: Int, height: Int, sigma: Float, passes: Int = 3) -> [Float] {
        let radius = max(1, Int((sigma * 1.7320508).rounded()))
        var result = src
        for _ in 0..<passes {
            result = boxBlurOnce(result, width: width, height: height, radius: radius)
        }
        return result
    }

    private static func boxBlurOnce(_ src: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        let satWidth = width + 1
        var sat = [Double](repeating: 0, count: satWidth * (height + 1))
        for y in 0..<height {
            var rowSum: Double = 0
            for x in 0..<width {
                rowSum += Double(src[y * width + x])
                sat[(y + 1) * satWidth + (x + 1)] = sat[y * satWidth + (x + 1)] + rowSum
            }
        }

        var out = [Float](repeating: 0, count: src.count)
        for y in 0..<height {
            let y0 = max(0, y - radius)
            let y1 = min(height - 1, y + radius)
            for x in 0..<width {
                let x0 = max(0, x - radius)
                let x1 = min(width - 1, x + radius)
                let area = Double((x1 - x0 + 1) * (y1 - y0 + 1))
                let sum = sat[(y1 + 1) * satWidth + (x1 + 1)] - sat[y0 * satWidth + (x1 + 1)]
                    - sat[(y1 + 1) * satWidth + x0] + sat[y0 * satWidth + x0]
                out[y * width + x] = Float(sum / area)
            }
        }
        return out
    }

    // MARK: - Triangle pruning

    /// Removes edge (a,b) whenever a and b share a neighbor c with
    /// max(|ac|,|bc|) < |ab| — c already connects them more tightly than
    /// the direct edge does.
    private static func prunedEdges(positions: [CGPoint], edges: [(Int, Int)]) -> [(Int, Int)] {
        var adjacency: [Int: Set<Int>] = [:]
        for (a, b) in edges {
            adjacency[a, default: []].insert(b)
            adjacency[b, default: []].insert(a)
        }

        func distance(_ i: Int, _ j: Int) -> Double {
            let dx = positions[i].x - positions[j].x
            let dy = positions[i].y - positions[j].y
            return (dx * dx + dy * dy).squareRoot()
        }

        var kept: [(Int, Int)] = []
        for (a, b) in edges {
            let ab = distance(a, b)
            let commonNeighbors = (adjacency[a] ?? []).intersection(adjacency[b] ?? [])
            let shouldPrune = commonNeighbors.contains { c in
                max(distance(a, c), distance(b, c)) < ab
            }
            if !shouldPrune { kept.append((a, b)) }
        }
        return kept
    }

    // MARK: - Color

    private static func averageLab(
        bytes: UnsafePointer<UInt8>, bytesPerPixel: Int, bytesPerRow: Int, width: Int, height: Int, mask: [Bool]
    ) -> (L: Double, a: Double, b: Double) {
        var sumL: Double = 0, sumA: Double = 0, sumB: Double = 0
        var count = 0
        for y in 0..<height {
            let rowStart = y * bytesPerRow
            for x in 0..<width {
                let idx = y * width + x
                guard mask[idx] else { continue }
                let o = rowStart + x * bytesPerPixel
                let lab = rgbToLab(r: Double(bytes[o]), g: Double(bytes[o + 1]), b: Double(bytes[o + 2]))
                sumL += lab.L
                sumA += lab.a
                sumB += lab.b
                count += 1
            }
        }
        guard count > 0 else { return (0, 0, 0) }
        let n = Double(count)
        return (sumL / n, sumA / n, sumB / n)
    }

    /// Standard sRGB (D65) → CIE Lab conversion.
    private static func rgbToLab(r: Double, g: Double, b: Double) -> (L: Double, a: Double, b: Double) {
        func toLinear(_ c: Double) -> Double {
            let c = c / 255.0
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let rl = toLinear(r), gl = toLinear(g), bl = toLinear(b)

        let x = 0.4124564 * rl + 0.3575761 * gl + 0.1804375 * bl
        let y = 0.2126729 * rl + 0.7151522 * gl + 0.0721750 * bl
        let z = 0.0193339 * rl + 0.1191920 * gl + 0.9503041 * bl

        let xn = 0.95047, yn = 1.0, zn = 1.08883
        func f(_ t: Double) -> Double {
            let delta = 6.0 / 29.0
            return t > delta * delta * delta ? pow(t, 1.0 / 3.0) : (t / (3 * delta * delta) + 4.0 / 29.0)
        }

        let fx = f(x / xn), fy = f(y / yn), fz = f(z / zn)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    // MARK: - Visualization

    /// Builds a `CGImage` from flat RGBA bytes, alpha-premultiplied, 8
    /// bits/channel — the shared backing for the grayscale/binary debug
    /// panels below.
    private static func imageFromRGBA(_ pixels: [UInt8], width: Int, height: Int) -> UIImage {
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return UIImage()
        }
        return UIImage(cgImage: cgImage)
    }

    /// Renders a single-channel buffer (gray or blur, both roughly 0...255)
    /// as a grayscale image, transparent outside the mask.
    private static func renderGrayscaleImage(_ values: [Float], mask: [Bool], width: Int, height: Int) -> UIImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let v = UInt8(max(0, min(255, values[i])).rounded())
            let o = i * 4
            pixels[o] = v
            pixels[o + 1] = v
            pixels[o + 2] = v
            pixels[o + 3] = mask[i] ? 255 : 0
        }
        return imageFromRGBA(pixels, width: width, height: height)
    }

    /// Renders the binary "data" mask: near-black where a net pixel was
    /// detected, white elsewhere in the ROI, a pale ring for the part of the
    /// mask eroded away, transparent outside the cutout entirely.
    private static func renderBinaryImage(data: [Bool], roi: [Bool], mask: [Bool], width: Int, height: Int) -> UIImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let o = i * 4
            let (r, g, b, a): (UInt8, UInt8, UInt8, UInt8)
            if roi[i], data[i] {
                (r, g, b, a) = (20, 20, 20, 255)
            } else if roi[i] {
                (r, g, b, a) = (255, 255, 255, 255)
            } else if mask[i] {
                (r, g, b, a) = (200, 215, 230, 255)
            } else {
                (r, g, b, a) = (0, 0, 0, 0)
            }
            pixels[o] = r
            pixels[o + 1] = g
            pixels[o + 2] = b
            pixels[o + 3] = a
        }
        return imageFromRGBA(pixels, width: width, height: height)
    }

    /// Single panel, scale 1: the normalized cutout with the triangle-pruned
    /// graph (red) overlaid. Replaces the old two-panel 2×-wide layout.
    private static func renderVisualization(
        baseImage: UIImage, pixelSize: CGSize, positions: [CGPoint], edges: [(Int, Int)]
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)

        return renderer.image { rendererContext in
            baseImage.draw(in: CGRect(origin: .zero, size: pixelSize))

            let cgContext = rendererContext.cgContext
            let graphColor = UIColor(red: 1.0, green: 0.15, blue: 0.15, alpha: 1.0)

            // Dots first, edges on top (short edges between close nodes
            // would otherwise be fully covered by the larger dot markers).
            cgContext.setFillColor(graphColor.cgColor)
            let radius: CGFloat = 2.0
            for p in positions {
                cgContext.fillEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
            }

            cgContext.setStrokeColor(graphColor.cgColor)
            cgContext.setLineWidth(1.5)
            for (a, b) in edges where a < positions.count && b < positions.count {
                cgContext.move(to: positions[a])
                cgContext.addLine(to: positions[b])
            }
            cgContext.strokePath()
        }
    }
}

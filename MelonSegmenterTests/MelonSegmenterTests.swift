import Testing
import UIKit
@testable import Melon_Segmenter

/// Synthetic "melon" test fixtures + ground-truth geometry computed
/// independently of `NetDensityAnalyzer`'s own pipeline, used to sanity
/// check its output rather than just asserting it runs.
enum SyntheticMelon {
    // Deliberately smaller than NetDensityAnalyzer's own 700px target
    // diameter: this is a correctness sanity check, not a performance
    // benchmark, and a smaller fixture keeps the blur passes + GNG training
    // fast enough to run reliably under the test runner's timeout.
    static let diameter: CGFloat = 350

    /// A disk of `diameter` with a `cells`×`cells` grid of `lineWidth`-thick
    /// lines drawn across it (clipped to the disk), simulating melon net
    /// texture, on a transparent background — the same RGBA-premultiplied
    /// shape `MelonSegmenter` produces.
    static func netDisk(cells: Int, lineWidth: CGFloat = 3) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter), format: format)

        return renderer.image { ctx in
            let cg = ctx.cgContext
            let circleRect = CGRect(x: 0, y: 0, width: diameter, height: diameter)

            cg.setFillColor(UIColor(red: 0.78, green: 0.85, blue: 0.45, alpha: 1).cgColor)
            cg.fillEllipse(in: circleRect)

            cg.saveGState()
            cg.addEllipse(in: circleRect)
            cg.clip()

            cg.setStrokeColor(UIColor(red: 0.35, green: 0.38, blue: 0.18, alpha: 1).cgColor)
            cg.setLineWidth(lineWidth)
            let step = diameter / CGFloat(cells)
            for i in 0...cells {
                let position = CGFloat(i) * step
                cg.move(to: CGPoint(x: position, y: 0))
                cg.addLine(to: CGPoint(x: position, y: diameter))
                cg.move(to: CGPoint(x: 0, y: position))
                cg.addLine(to: CGPoint(x: diameter, y: position))
            }
            cg.strokePath()
            cg.restoreGState()
        }
    }

    /// Plain disk, no net texture at all.
    static func plainDisk() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter), format: format)
        return renderer.image { ctx in
            ctx.cgContext.setFillColor(UIColor(red: 0.78, green: 0.85, blue: 0.45, alpha: 1).cgColor)
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        }
    }

    /// Ground truth for `netDisk(cells:)` — interior grid-line intersections
    /// and total in-circle line length — computed purely from the grid
    /// spacing and circle equation, restricted to the same eroded ROI
    /// radius the analyzer actually measures against, so this is an
    /// apples-to-apples comparison rather than comparing against the
    /// full, un-eroded disk.
    static func expectedGeometry(cells: Int, erosionFraction: Double) -> (interiorIntersections: Int, totalLength: Double) {
        let radius = Double(diameter) / 2
        let erodedRadius = radius - erosionFraction * Double(diameter)
        let center = Double(diameter) / 2
        let step = Double(diameter) / Double(cells)

        var intersections = 0
        for i in 1..<cells {
            for j in 1..<cells {
                let x = Double(i) * step
                let y = Double(j) * step
                let d = ((x - center) * (x - center) + (y - center) * (y - center)).squareRoot()
                if d < erodedRadius { intersections += 1 }
            }
        }

        func chordLength(at offset: Double) -> Double {
            let d = abs(offset - center)
            guard d < erodedRadius else { return 0 }
            return 2 * (erodedRadius * erodedRadius - d * d).squareRoot()
        }

        var totalLength: Double = 0
        for i in 0...cells {
            let position = Double(i) * step
            totalLength += chordLength(at: position) // vertical line at x = position
            totalLength += chordLength(at: position) // horizontal line at y = position
        }

        return (intersections, totalLength)
    }
}

@Suite("NetDensityAnalyzer")
@MainActor
struct NetDensityAnalyzerTests {
    private static let erosionFraction = NetDensityAnalyzer.Config().roiErosionFraction

    // Smaller maxPoints than production's default (6000) — this test's
    // synthetic fixture is already small, and a lighter point budget keeps
    // GNG training fast without changing what's being verified.
    private static var fastConfig: NetDensityAnalyzer.Config {
        var config = NetDensityAnalyzer.Config()
        config.maxPoints = 1500
        return config
    }

    @Test("Grid net: detected branch/length roughly match independent geometric ground truth")
    func gridNetMatchesGroundTruth() async throws {
        let cells = 10
        let image = SyntheticMelon.netDisk(cells: cells)
        let expected = SyntheticMelon.expectedGeometry(cells: cells, erosionFraction: Self.erosionFraction)

        let (metrics, _) = try await NetDensityAnalyzer.analyze(segmentedImage: image, invertPolarity: false, config: Self.fastConfig)

        let detectedBranchCount = metrics.branchDensity * Double(metrics.roiAreaPx) / 1e4
        let detectedLength = metrics.lengthDensity * Double(metrics.roiAreaPx) / 1e3

        let branchRelativeError = expected.interiorIntersections > 0
            ? abs(detectedBranchCount - Double(expected.interiorIntersections)) / Double(expected.interiorIntersections)
            : detectedBranchCount
        let lengthRelativeError = expected.totalLength > 0
            ? abs(detectedLength - expected.totalLength) / expected.totalLength
            : detectedLength

        print("[Test] expected intersections=\(expected.interiorIntersections) detected≈\(detectedBranchCount) (relErr=\(branchRelativeError))")
        print("[Test] expected length=\(expected.totalLength) detected≈\(detectedLength) (relErr=\(lengthRelativeError))")

        // GNG is an approximate graph fit over sampled pixels, not an exact
        // corner detector — this is a sanity bound to catch gross
        // regressions, not a pixel-perfect accuracy claim. The actual
        // achieved error is printed above; report that number back.
        #expect(branchRelativeError < 0.6)
        #expect(lengthRelativeError < 0.6)
    }

    @Test("Plain disk: no net texture detected")
    func plainDiskHasNoBranching() async throws {
        let image = SyntheticMelon.plainDisk()
        do {
            let (metrics, _) = try await NetDensityAnalyzer.analyze(segmentedImage: image, invertPolarity: false, config: Self.fastConfig)
            #expect(metrics.branchDensity < 0.1)
        } catch is NetDensityAnalyzerError {
            // "Not enough texture" is also a correct outcome for a flat disk.
        }
    }

    @Test("Reproducibility: 5 runs on the same image produce identical metrics")
    func reproducibleAcrossRuns() async throws {
        let image = SyntheticMelon.netDisk(cells: 10)

        var nodeCounts: [Int] = []
        var branchDensities: [Double] = []
        var lengthDensities: [Double] = []

        for _ in 0..<5 {
            let (metrics, _) = try await NetDensityAnalyzer.analyze(segmentedImage: image, invertPolarity: false, config: Self.fastConfig)
            nodeCounts.append(metrics.nodeCount)
            branchDensities.append(metrics.branchDensity)
            lengthDensities.append(metrics.lengthDensity)
        }

        let nodeCountSpread = (nodeCounts.max() ?? 0) - (nodeCounts.min() ?? 0)
        let branchSpread = (branchDensities.max() ?? 0) - (branchDensities.min() ?? 0)
        let lengthSpread = (lengthDensities.max() ?? 0) - (lengthDensities.min() ?? 0)

        print("[Test] 5-run spread: nodeCount max-min=\(nodeCountSpread), branchDensity max-min=\(branchSpread), lengthDensity max-min=\(lengthSpread)")

        #expect(nodeCountSpread == 0)
        #expect(branchSpread == 0)
        #expect(lengthSpread == 0)
    }
}

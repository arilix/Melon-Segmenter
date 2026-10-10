import SwiftUI

/// Runs the Growing Neural Gas net-texture analysis on a segmented melon
/// cutout, then shows the visualization + complexity metrics with an upload
/// action. Mirrors `SegmentationView`'s self-contained async-stage pattern.
struct GNGResultView: View {
    let originalImage: UIImage
    let segmentedImage: UIImage
    var onUpload: (NetComplexityMetrics, UIImage) -> Void
    var onRetake: () -> Void

    @State private var isAnalyzing = true
    @State private var errorMessage: String?
    @State private var metrics: NetComplexityMetrics?
    @State private var visualization: UIImage?

    var body: some View {
        VStack(spacing: 16) {
            if isAnalyzing {
                Spacer()
                ProgressView()
                    .tint(MelonTheme.accentTeal)
                    .scaleEffect(1.6)
                Text("Menganalisis net melon dengan GNG…")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                Spacer()
            } else if let errorMessage {
                Spacer()
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.orange)
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                Spacer()
                Button {
                    onRetake()
                } label: {
                    Label("Ambil Ulang", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(MelonSecondaryButtonStyle())
            } else if let metrics, let visualization {
                Image(uiImage: visualization)
                    .resizable()
                    .scaledToFit()
                    .melonCard(padding: 8)
                    .layoutPriority(1)

                VStack(spacing: 6) {
                    Text("Net Complexity Index")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                    Text(String(format: "%.1f", metrics.netComplexityIndex))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(MelonTheme.accentTeal)

                    HStack(spacing: 20) {
                        metricColumn(label: "Node", value: "\(metrics.nodeCount)")
                        metricColumn(label: "Edge", value: "\(metrics.edgeCount)")
                    }
                }
                .melonCard(padding: 12)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button {
                        onRetake()
                    } label: {
                        Label("Ambil Ulang", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(MelonSecondaryButtonStyle())

                    Button {
                        onUpload(metrics, visualization)
                    } label: {
                        Label("Upload Semua", systemImage: "icloud.and.arrow.up.fill")
                    }
                    .buttonStyle(MelonPrimaryButtonStyle())
                }
            }
        }
        .padding(.bottom, 12)
        .task {
            await runAnalysis()
        }
    }

    private func metricColumn(label: String, value: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
    }

    private func runAnalysis() async {
        do {
            let result = try await NetComplexityAnalyzer.analyze(segmentedImage: segmentedImage)
            metrics = result.metrics
            visualization = result.visualization
        } catch {
            errorMessage = "Gagal menganalisis: \(error.localizedDescription)"
        }
        isAnalyzing = false
    }
}

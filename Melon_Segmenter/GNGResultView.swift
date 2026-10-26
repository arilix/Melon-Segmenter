import SwiftUI

/// Runs the area-normalized net-density analysis on a segmented melon
/// cutout, then shows the 6-panel debug breakdown (segmentation, grayscale,
/// blur, binary data mask, pruned GNG graph, metrics summary) with an
/// upload action. Mirrors `SegmentationView`'s self-contained async-stage
/// pattern.
struct GNGResultView: View {
    let originalImage: UIImage
    let segmentedImage: UIImage
    var onUpload: (NetDensityMetrics, UIImage) -> Void
    var onRetake: () -> Void

    @AppStorage("melon.invertPolarity") private var invertPolarity = false

    @State private var isAnalyzing = true
    @State private var errorMessage: String?
    @State private var metrics: NetDensityMetrics?
    @State private var visualization: NetDensityVisualization?

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        VStack(spacing: 12) {
            if isAnalyzing {
                Spacer()
                ProgressView()
                    .tint(MelonTheme.accentTeal)
                    .scaleEffect(1.6)
                Text("Analyzing net density…")
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
                    Label("Retake", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(MelonSecondaryButtonStyle())
            } else if let metrics, let visualization {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        imagePanel(number: 1, title: "Segmentation", image: visualization.segmentation)
                        imagePanel(number: 2, title: "Grayscale", image: visualization.grayscale)
                        imagePanel(number: 3, title: "Gaussian blur", image: visualization.blur)
                        imagePanel(number: 4, title: "Binary = graph data", image: visualization.binary)
                        imagePanel(number: 5, title: "GNG (pruned)", image: visualization.gngOverlay)
                        metricsPanel(metrics)
                    }
                    .padding(.vertical, 4)

                    Toggle("Net is lighter than skin", isOn: $invertPolarity)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .tint(MelonTheme.accentTeal)
                        .onChange(of: invertPolarity) { _, _ in rerun() }
                        .padding(.top, 8)
                }
                .layoutPriority(1)

                HStack(spacing: 12) {
                    Button {
                        onRetake()
                    } label: {
                        Label("Retake", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(MelonSecondaryButtonStyle())

                    Button {
                        onUpload(metrics, visualization.gngOverlay)
                    } label: {
                        Label("Upload All", systemImage: "icloud.and.arrow.up.fill")
                    }
                    .buttonStyle(MelonPrimaryButtonStyle())
                }
            }
        }
        .padding(.bottom, 8)
        .task {
            await runAnalysis()
        }
    }

    private func imagePanel(number: Int, title: String, image: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(number) \(title)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(Color.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func metricsPanel(_ metrics: NetDensityMetrics) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("6 Metrics")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))

            VStack(alignment: .leading, spacing: 4) {
                densityRow(label: "Branch density", value: metrics.branchDensity)
                densityRow(label: "Length density", value: metrics.lengthDensity)

                Divider().background(Color.white.opacity(0.15))

                Text("Data: \(polarityLabel(metrics)) (\(String(format: "%.1f", metrics.dataFractionOfROI * 100))% of ROI)")
                Text("Stroke width \(String(format: "%.1f", metrics.strokeWidthPx))px, diameter \(Int(metrics.dEq))px")
                Text("Color Lab: \(String(format: "%.1f", metrics.meanL)) / \(String(format: "%.1f", metrics.meanA)) / \(String(format: "%.1f", metrics.meanB))")
                Text("GNG: \(metrics.nodeCount) nodes, \(metrics.prunedEdgeCount) pruned edges")
            }
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.75))
        }
        .frame(maxWidth: .infinity, minHeight: 0, alignment: .topLeading)
        .padding(8)
        .aspectRatio(1, contentMode: .fit)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func densityRow(label: String, value: Double) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
            Text(String(format: "%.2f", value))
                .bold()
                .foregroundStyle(MelonTheme.accentTeal)
        }
        .font(.system(size: 11))
    }

    private func polarityLabel(_ metrics: NetDensityMetrics) -> String {
        metrics.invertPolarity ? "net lighter than skin" : "net darker than skin"
    }

    private func runAnalysis() async {
        isAnalyzing = true
        errorMessage = nil
        do {
            let result = try await NetDensityAnalyzer.analyze(segmentedImage: segmentedImage, invertPolarity: invertPolarity)
            metrics = result.metrics
            visualization = result.visualization
        } catch {
            errorMessage = "Analysis failed: \(error.localizedDescription)"
        }
        isAnalyzing = false
    }

    private func rerun() {
        Task { await runAnalysis() }
    }
}

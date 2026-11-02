import SwiftUI
import UIKit

/// Segments one kept photo with SAM, analyzes its net, and uploads the
/// result. Opened per photo from the melon's detail screen; the Google
/// session already exists because sign-in happens at launch.
struct ProcessingFlowView: View {
    private enum Stage {
        case segmenting(original: UIImage)
        case analyzingNet(original: UIImage, segmented: UIImage)
        case uploading
        case success
        case failure(String)
    }

    let captureIndex: String
    let hst: Int
    let capturedAt: Date
    /// "2 of 5" when running through a queue.
    var progress: String?
    /// Label of the button shown after a successful upload.
    var doneTitle = "Done"
    /// Called when the user leaves; `true` if the upload finished.
    var onClose: (_ uploaded: Bool) -> Void

    @State private var stage: Stage
    private let uploader = GoogleDriveUploader()

    init(
        original: UIImage,
        captureIndex: String,
        hst: Int,
        capturedAt: Date,
        progress: String? = nil,
        doneTitle: String = "Done",
        onClose: @escaping (Bool) -> Void
    ) {
        self.captureIndex = captureIndex
        self.hst = hst
        self.capturedAt = capturedAt
        self.progress = progress
        self.doneTitle = doneTitle
        self.onClose = onClose
        _stage = State(initialValue: .segmenting(original: original))
    }

    var body: some View {
        ZStack {
            MelonTheme.backgroundGradient.ignoresSafeArea()

            VStack(spacing: 20) {
                header

                Text(subtitle)
                    .font(.footnote.bold())
                    .foregroundStyle(MelonTheme.accentTeal)

                Group {
                    switch stage {
                    case .segmenting(let original):
                        SegmentationView(
                            originalImage: original,
                            onConfirm: { segmented in
                                stage = .analyzingNet(original: original, segmented: segmented)
                            },
                            onRetake: { onClose(false) }
                        )
                    case .analyzingNet(let original, let segmented):
                        GNGResultView(
                            originalImage: original,
                            segmentedImage: segmented,
                            onUpload: { metrics, visualization in
                                upload(original: original, segmented: segmented, visualization: visualization, metrics: metrics)
                            },
                            onRetake: { onClose(false) }
                        )
                    case .uploading:
                        uploadingView
                    case .success:
                        successView
                    case .failure(let message):
                        failureView(message)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
        .preferredColorScheme(.dark)
    }

    private var subtitle: String {
        let base = "Melon \(captureIndex) · HST \(hst)"
        return progress.map { "\(base) · photo \($0)" } ?? base
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image("MelonLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 0) {
                Text("Melon")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                +
                Text(" Segmenter")
                    .font(.title2.bold())
                    .foregroundStyle(MelonTheme.meadowGreen)

                Text("Cut your melon with AI")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer()
        }
        .padding(.bottom, 4)
    }

    private var uploadingView: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .tint(MelonTheme.accentTeal)
                .scaleEffect(1.6)
            Text("Uploading to Google Drive…")
                .font(.headline)
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
        }
    }

    private var successView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(MelonTheme.meadowGreen)
            Text("Upload successful! 🎉")
                .font(.title3.bold())
                .foregroundStyle(.white)
            Text("The original photo, segmentation result, GNG visualization, and density data have been saved to the \"Melon Segmenter\" folder, including a new row in density_log.csv.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            Spacer()
            Button {
                onClose(true)
            } label: {
                Label(doneTitle, systemImage: "checkmark")
            }
            .buttonStyle(MelonPrimaryButtonStyle())
        }
        .padding(.bottom, 24)
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.orange)
            Text("Oops, something went wrong")
                .font(.title3.bold())
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            Spacer()
            Button {
                onClose(false)
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(MelonPrimaryButtonStyle())
        }
        .padding(.bottom, 24)
    }

    private func upload(original: UIImage, segmented: UIImage, visualization: UIImage, metrics: NetDensityMetrics) {
        guard let presentingVC = UIApplication.shared.keyWindowRootViewController else {
            stage = .failure("Couldn't find a view to present Google sign-in.")
            return
        }
        guard let originalData = original.pngData(),
              let segmentedData = segmented.pngData(),
              let visualizationData = visualization.pngData() else {
            stage = .failure("Failed to create PNG data from the result.")
            return
        }

        stage = .uploading
        let index = captureIndex
        Task {
            do {
                try await uploader.uploadCaptureBundle(
                    captureIndex: index,
                    hst: hst,
                    capturedAt: capturedAt,
                    originalPNGData: originalData,
                    segmentedPNGData: segmentedData,
                    visualizationPNGData: visualizationData,
                    metrics: metrics,
                    presentingViewController: presentingVC
                )
                stage = .success
            } catch {
                stage = .failure("Upload failed: \(error.localizedDescription)")
            }
        }
    }
}

#Preview {
    ProcessingFlowView(original: UIImage(), captureIndex: "001", hst: 20, capturedAt: Date(), onClose: { _ in })
}

import SwiftUI
import UIKit
import PhotosUI

struct ContentView: View {
    private enum Stage {
        case idle
        case segmenting(original: UIImage)
        case analyzingNet(original: UIImage, segmented: UIImage)
        case uploading
        case success
        case failure(String)
    }

    @State private var isShowingCamera = false
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var stage: Stage = .idle
    @AppStorage("melon.captureIndex") private var captureIndex: String = ""
    private let uploader = GoogleDriveUploader()

    var body: some View {
        ZStack {
            MelonTheme.backgroundGradient.ignoresSafeArea()

            VStack(spacing: 20) {
                header

                Group {
                    switch stage {
                    case .idle:
                        idleView
                    case .segmenting(let original):
                        SegmentationView(
                            originalImage: original,
                            onConfirm: { segmented in
                                stage = .analyzingNet(original: original, segmented: segmented)
                            },
                            onRetake: { stage = .idle }
                        )
                    case .analyzingNet(let original, let segmented):
                        GNGResultView(
                            originalImage: original,
                            segmentedImage: segmented,
                            onUpload: { metrics, visualization in
                                upload(original: original, segmented: segmented, visualization: visualization, metrics: metrics)
                            },
                            onRetake: { stage = .idle }
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
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraCaptureView(
                onCapture: { image in
                    isShowingCamera = false
                    stage = .segmenting(original: image)
                },
                onCancel: { isShowingCamera = false }
            )
            .ignoresSafeArea()
        }
        .onChange(of: photoPickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await loadPickedPhoto(newItem)
                photoPickerItem = nil
            }
        }
    }

    private func loadPickedPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                stage = .failure("Failed to open the photo from your library.")
                return
            }
            stage = .segmenting(original: image.normalizedOrientation())
        } catch {
            stage = .failure("Failed to open photo: \(error.localizedDescription)")
        }
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

    private var idleView: some View {
        VStack(spacing: 24) {
            Spacer()

            Image("MelonLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                .shadow(color: MelonTheme.accentTeal.opacity(0.35), radius: 24, y: 8)

            VStack(spacing: 8) {
                Text("Ready to segment your melon? 🍈")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("Take a photo of your melon, tap on it, then see how complex its net pattern is before sending it to Google Drive.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Capture Index")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                TextField("e.g. 001", text: $captureIndex)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.white)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 8)

            Spacer()

            Button {
                isShowingCamera = true
            } label: {
                Label("Take Photo", systemImage: "camera.fill")
            }
            .buttonStyle(MelonPrimaryButtonStyle())

            PhotosPicker(selection: $photoPickerItem, matching: .images) {
                Label("Choose from Library", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(MelonSecondaryButtonStyle())
        }
        .padding(.bottom, 24)
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
            Text("The original photo, segmentation result, GNG visualization, and complexity data have been saved to the \"Melon Segmenter\" folder — including a new row in complexity_log.csv.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            Spacer()
            Button {
                stage = .idle
            } label: {
                Label("Take Another Photo", systemImage: "camera.fill")
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
                stage = .idle
            } label: {
                Label("Try Again", systemImage: "arrow.counterclockwise")
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

private extension UIApplication {
    var keyWindowRootViewController: UIViewController? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?.rootViewController
    }
}

#Preview {
    ContentView()
}

import SwiftUI
import UIKit

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

                Text("Potong melon-mu dengan AI")
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
                Text("Siap menyegmentasi melon? 🍈")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("Ambil foto melon, tap bagian melonnya, lalu lihat seberapa kompleks net kulitnya sebelum dikirim ke Google Drive.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Index Capture")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                TextField("Contoh: 001", text: $captureIndex)
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
                Label("Ambil Foto", systemImage: "camera.fill")
            }
            .buttonStyle(MelonPrimaryButtonStyle())
        }
        .padding(.bottom, 24)
    }

    private var uploadingView: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .tint(MelonTheme.accentTeal)
                .scaleEffect(1.6)
            Text("Mengunggah ke Google Drive…")
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
            Text("Berhasil diunggah! 🎉")
                .font(.title3.bold())
                .foregroundStyle(.white)
            Text("Foto asli, hasil segmentasi, visualisasi GNG, dan data kompleksitas sudah tersimpan di folder \"Melon Segmenter\" — termasuk baris baru di complexity_log.csv.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            Spacer()
            Button {
                stage = .idle
            } label: {
                Label("Ambil Foto Lagi", systemImage: "camera.fill")
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
            Text("Oops, ada masalah")
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
                Label("Coba Lagi", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(MelonPrimaryButtonStyle())
        }
        .padding(.bottom, 24)
    }

    private func upload(original: UIImage, segmented: UIImage, visualization: UIImage, metrics: NetComplexityMetrics) {
        guard let presentingVC = UIApplication.shared.keyWindowRootViewController else {
            stage = .failure("Tidak dapat menemukan tampilan untuk sign-in Google.")
            return
        }
        guard let originalData = original.pngData(),
              let segmentedData = segmented.pngData(),
              let visualizationData = visualization.pngData() else {
            stage = .failure("Gagal membuat file PNG dari hasil.")
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
                stage = .failure("Gagal mengunggah: \(error.localizedDescription)")
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

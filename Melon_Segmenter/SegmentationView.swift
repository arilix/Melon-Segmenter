import SwiftUI

/// Shows a captured photo, lets the user tap the melon to segment it with
/// MobileSAM, then offers Retake / Retry / Upload actions.
struct SegmentationView: View {
    let originalImage: UIImage
    var onConfirm: (UIImage) -> Void
    var onRetake: () -> Void

    @State private var segmenter = MelonSegmenter()
    @State private var segmentedImage: UIImage?
    @State private var isSegmenting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            GeometryReader { geometry in
                ZStack {
                    Image(uiImage: segmentedImage ?? originalImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            if segmentedImage == nil {
                                handleTap(at: location, in: geometry.size)
                            }
                        }

                    if isSegmenting {
                        VStack(spacing: 10) {
                            ProgressView()
                                .tint(MelonTheme.accentTeal)
                            Text("Segmenting…")
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                        }
                        .padding(20)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .melonCard(padding: 8)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else if segmentedImage == nil {
                Label("Tap the melon in the photo to segment it", systemImage: "hand.point.up.left.fill")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.65))
            }

            HStack(spacing: 12) {
                Button {
                    onRetake()
                } label: {
                    Label("Retake", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(MelonSecondaryButtonStyle())

                if let segmentedImage {
                    Button {
                        self.segmentedImage = nil
                        errorMessage = nil
                    } label: {
                        Label("Try Again", systemImage: "hand.tap.fill")
                    }
                    .buttonStyle(MelonSecondaryButtonStyle())
                }
            }

            if let segmentedImage {
                Button {
                    onConfirm(segmentedImage)
                } label: {
                    Label("Analyze Net", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                }
                .buttonStyle(MelonPrimaryButtonStyle())
            }
        }
        .padding(.bottom, 12)
    }

    private func handleTap(at location: CGPoint, in viewSize: CGSize) {
        guard !isSegmenting else { return }
        guard let imagePoint = Self.imagePoint(
            forViewPoint: location,
            viewSize: viewSize,
            imageSize: originalImage.size
        ) else { return }

        errorMessage = nil
        isSegmenting = true

        Task {
            do {
                // `segmenter` is now an actor, so this call hops off the
                // main actor for the actual CoreML inference instead of
                // blocking it.
                segmentedImage = try await segmenter.segment(image: originalImage, tapPoint: imagePoint)
            } catch {
                errorMessage = "Segmentation failed: \(error.localizedDescription)"
            }
            isSegmenting = false
        }
    }

    /// Converts a tap location in an aspect-fit `Image` view into pixel
    /// coordinates in the original image.
    private static func imagePoint(forViewPoint viewPoint: CGPoint, viewSize: CGSize, imageSize: CGSize) -> CGPoint? {
        guard viewSize.width > 0, viewSize.height > 0, imageSize.width > 0, imageSize.height > 0 else { return nil }

        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let displayedWidth = imageSize.width * scale
        let displayedHeight = imageSize.height * scale
        let originX = (viewSize.width - displayedWidth) / 2
        let originY = (viewSize.height - displayedHeight) / 2

        let x = (viewPoint.x - originX) / scale
        let y = (viewPoint.y - originY) / scale

        guard x >= 0, x <= imageSize.width, y >= 0, y <= imageSize.height else { return nil }
        return CGPoint(x: x, y: y)
    }
}

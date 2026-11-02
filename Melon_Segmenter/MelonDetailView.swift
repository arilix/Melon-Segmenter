import SwiftUI
import PhotosUI

/// One melon: add photos (kept as-is, not processed yet) and process or
/// delete the kept ones.
struct MelonDetailView: View {
    let melonID: UUID

    @EnvironmentObject private var store: MelonStore
    @Environment(\.dismiss) private var dismiss

    @State private var isConfirmingDelete = false
    @State private var isShowingCamera = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var processingQueue: ProcessingQueue?
    @State private var errorMessage: String?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        ZStack {
            MelonTheme.backgroundGradient.ignoresSafeArea()

            if let melon = store.melon(id: melonID) {
                content(for: melon)
            } else {
                Text("This melon was deleted.")
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraCaptureView(
                onCapture: { image in
                    isShowingCamera = false
                    keep(image)
                },
                onCancel: { isShowingCamera = false }
            )
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $processingQueue) { queue in
            ProcessingQueueView(queue: queue) { processingQueue = nil }
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await keepPicked(newItem)
                pickerItem = nil
            }
        }
    }

    private func content(for melon: Melon) -> some View {
        let captures = store.captures(for: melon.id)
        return List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(melon.captureIndex)
                        .font(.title.bold())
                        .foregroundStyle(.white)
                    Text("HST \(melon.hst())")
                        .font(.headline)
                        .foregroundStyle(MelonTheme.accentTeal)
                    Text("Planted \(melon.plantingDate.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .listRowBackground(Color.clear)

                Button { isShowingCamera = true } label: {
                    Label("Take Photo", systemImage: "camera.fill")
                }
                .buttonStyle(MelonPrimaryButtonStyle())
                .listRowBackground(Color.clear)

                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("Choose from Library", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(MelonSecondaryButtonStyle())
                .listRowBackground(Color.clear)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .listRowBackground(Color.clear)
                }
            }

            Section("Kept photos") {
                let waiting = captures.filter { $0.status == .pending }
                if waiting.count > 1 {
                    Button {
                        // Oldest first, so uploads follow the order the photos were taken.
                        processingQueue = ProcessingQueue(captureIDs: waiting.reversed().map(\.id))
                    } label: {
                        Label("Process all waiting (\(waiting.count))", systemImage: "play.fill")
                    }
                    .buttonStyle(MelonSecondaryButtonStyle())
                    .listRowBackground(Color.clear)
                }
                if captures.isEmpty {
                    Text("No photos yet. Photos you take are kept here and can be processed later.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .listRowBackground(Color.clear)
                }
                ForEach(captures) { capture in
                    captureRow(capture)
                        .listRowBackground(MelonTheme.cardBackground)
                        .swipeActions {
                            Button(role: .destructive) { store.deleteCapture(capture) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) { isConfirmingDelete = true } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .confirmationDialog(
            "Delete melon \(melon.captureIndex)?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete melon and its photos", role: .destructive) {
                store.deleteMelon(melon)
                dismiss()
            }
        } message: {
            Text("This also removes its \(captures.count) kept photo(s) from this device. Files already uploaded to Google Drive are not touched.")
        }
    }

    private func captureRow(_ capture: CaptureRecord) -> some View {
        HStack(spacing: 12) {
            ThumbnailView(capture: capture)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("HST \(capture.hstAtCapture)")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(Self.dateFormatter.string(from: capture.takenAt))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer()

            switch capture.status {
            case .pending:
                Button("Process") { processingQueue = ProcessingQueue(captureIDs: [capture.id]) }
                    .buttonStyle(.borderedProminent)
                    .tint(MelonTheme.accentTeal)
                    .foregroundStyle(MelonTheme.navyDeep)
            case .uploaded:
                Label("Uploaded", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(MelonTheme.meadowGreen)
            }
        }
    }

    private func keep(_ image: UIImage) {
        guard let melon = store.melon(id: melonID) else { return }
        do {
            try store.addCapture(for: melon, image: image)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func keepPicked(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            errorMessage = "Failed to open the photo from your library."
            return
        }
        keep(image.normalizedOrientation())
    }
}

private struct ThumbnailView: View {
    let capture: CaptureRecord

    @EnvironmentObject private var store: MelonStore
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white.opacity(0.08)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .task(id: capture.id) {
            image = await store.thumbnail(for: capture)
        }
    }
}

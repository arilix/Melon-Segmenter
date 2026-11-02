import SwiftUI

/// A batch of kept photos to process one after another.
struct ProcessingQueue: Identifiable {
    let id = UUID()
    let captureIDs: [UUID]
}

/// Runs `ProcessingFlowView` for each queued photo in turn. After a photo is
/// uploaded it moves on to the next; leaving with Back stops the queue.
struct ProcessingQueueView: View {
    let queue: ProcessingQueue
    var onFinish: () -> Void

    @EnvironmentObject private var store: MelonStore
    @State private var position = 0

    private var count: Int { queue.captureIDs.count }

    var body: some View {
        if position < count,
           let capture = store.captures.first(where: { $0.id == queue.captureIDs[position] }),
           let melon = store.melon(id: capture.melonID),
           let image = store.image(for: capture) {
            ProcessingFlowView(
                original: image,
                captureIndex: melon.captureIndex,
                hst: capture.hstAtCapture,
                capturedAt: capture.takenAt,
                progress: count > 1 ? "\(position + 1) of \(count)" : nil,
                doneTitle: position + 1 < count ? "Next photo" : "Done"
            ) { uploaded in
                if uploaded { store.markUploaded(capture.id) }
                if uploaded { advance() } else { onFinish() }
            }
            // A fresh flow (and fresh state) for every photo.
            .id(capture.id)
        } else {
            // The photo is gone (deleted meanwhile): skip it.
            Color.clear.task { advance() }
        }
    }

    private func advance() {
        if position + 1 < count {
            position += 1
        } else {
            onFinish()
        }
    }
}

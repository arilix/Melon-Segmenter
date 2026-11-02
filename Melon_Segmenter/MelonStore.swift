import Combine
import UIKit
import ImageIO

enum MelonStoreError: LocalizedError {
    case emptyIndex
    case duplicateIndex(String)
    case imageEncodingFailed

    var errorDescription: String? {
        switch self {
        case .emptyIndex:
            return "Enter an ID for the melon."
        case .duplicateIndex(let index):
            return "A melon with ID \"\(index)\" already exists."
        case .imageEncodingFailed:
            return "Couldn't save the photo."
        }
    }
}

/// Local library of melons and their kept (not yet processed) photos.
///
/// Metadata lives in one JSON file and photos in a "Captures" folder, both
/// under Application Support and written with complete file protection, so
/// iOS encrypts them whenever the device is locked.
@MainActor
final class MelonStore: ObservableObject {
    @Published private(set) var melons: [Melon] = []
    @Published private(set) var captures: [CaptureRecord] = []

    private struct Library: Codable {
        var melons: [Melon]
        var captures: [CaptureRecord]
    }

    private let rootURL: URL
    private var libraryURL: URL { rootURL.appendingPathComponent("library.json") }
    private var capturesURL: URL { rootURL.appendingPathComponent("Captures", isDirectory: true) }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        rootURL = base.appendingPathComponent("MelonSegmenter", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: capturesURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        load()
    }

    // MARK: - Melons

    @discardableResult
    func addMelon(captureIndex: String, hst: Int) throws -> Melon {
        let index = captureIndex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !index.isEmpty else { throw MelonStoreError.emptyIndex }
        guard !melons.contains(where: { $0.captureIndex.caseInsensitiveCompare(index) == .orderedSame }) else {
            throw MelonStoreError.duplicateIndex(index)
        }
        let melon = Melon(captureIndex: index, plantingDate: Melon.plantingDate(hst: hst))
        melons.append(melon)
        save()
        return melon
    }

    func melon(id: UUID) -> Melon? {
        melons.first { $0.id == id }
    }

    func deleteMelon(_ melon: Melon) {
        for capture in captures(for: melon.id) { removeFile(of: capture) }
        captures.removeAll { $0.melonID == melon.id }
        melons.removeAll { $0.id == melon.id }
        save()
    }

    // MARK: - Captures

    func captures(for melonID: UUID) -> [CaptureRecord] {
        captures.filter { $0.melonID == melonID }.sorted { $0.takenAt > $1.takenAt }
    }

    func pendingCount(for melonID: UUID) -> Int {
        captures.filter { $0.melonID == melonID && $0.status == .pending }.count
    }

    @discardableResult
    func addCapture(for melon: Melon, image: UIImage) throws -> CaptureRecord {
        guard let data = image.jpegData(compressionQuality: 0.95) else {
            throw MelonStoreError.imageEncodingFailed
        }
        let now = Date()
        let record = CaptureRecord(
            melonID: melon.id,
            takenAt: now,
            hstAtCapture: melon.hst(on: now),
            fileName: "\(UUID().uuidString).jpg"
        )
        try data.write(to: fileURL(of: record), options: [.atomic, .completeFileProtection])
        captures.append(record)
        save()
        return record
    }

    func markUploaded(_ captureID: UUID) {
        guard let i = captures.firstIndex(where: { $0.id == captureID }) else { return }
        captures[i].status = .uploaded
        save()
    }

    func deleteCapture(_ capture: CaptureRecord) {
        removeFile(of: capture)
        captures.removeAll { $0.id == capture.id }
        save()
    }

    func image(for capture: CaptureRecord) -> UIImage? {
        UIImage(contentsOfFile: fileURL(of: capture).path)
    }

    /// Downsampled thumbnail — decoding full photos for list rows is slow.
    nonisolated func thumbnail(for capture: CaptureRecord, maxPixel: Int = 240) async -> UIImage? {
        let url = await fileURL(of: capture)
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
    }

    // MARK: - Persistence

    private func fileURL(of capture: CaptureRecord) -> URL {
        capturesURL.appendingPathComponent(capture.fileName)
    }

    private func removeFile(of capture: CaptureRecord) {
        try? FileManager.default.removeItem(at: fileURL(of: capture))
    }

    private func load() {
        guard let data = try? Data(contentsOf: libraryURL),
              let library = try? JSONDecoder().decode(Library.self, from: data) else { return }
        melons = library.melons
        captures = library.captures
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Library(melons: melons, captures: captures)) else { return }
        try? data.write(to: libraryURL, options: [.atomic, .completeFileProtection])
    }
}

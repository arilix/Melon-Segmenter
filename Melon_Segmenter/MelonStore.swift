import Combine
import UIKit
import ImageIO

enum MelonStoreError: LocalizedError {
    case emptyIndex
    case duplicateIndex(String)
    case imageEncodingFailed
    case folderNotAccessible
    case moveFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyIndex:
            return "Enter an ID for the melon."
        case .duplicateIndex(let index):
            return "A melon with ID \"\(index)\" already exists."
        case .imageEncodingFailed:
            return "Couldn't save the photo."
        case .folderNotAccessible:
            return "iOS didn't allow access to that folder. Pick another one."
        case .moveFailed(let reason):
            return "Couldn't move your data: \(reason)"
        }
    }
}

/// Local library of melons and their kept (not yet processed) photos.
///
/// Metadata lives in one JSON file and photos in a "Captures" folder. By
/// default both sit under Application Support, written with complete file
/// protection so iOS encrypts them whenever the device is locked. The user
/// can instead pick a folder in Files (Settings); that folder is remembered
/// through a security-scoped bookmark and is not covered by that protection.
@MainActor
final class MelonStore: ObservableObject {
    @Published private(set) var melons: [Melon] = []
    @Published private(set) var captures: [CaptureRecord] = []

    private struct Library: Codable {
        var melons: [Melon]
        var captures: [CaptureRecord]
    }

    /// Set when a previously chosen folder couldn't be opened at launch.
    @Published private(set) var storageWarning: String?
    @Published private(set) var isUsingExternalStorage = false

    private static let bookmarkKey = "melon.storageBookmark"
    private static let folderName = "MelonSegmenter"

    private var rootURL: URL
    /// The user-chosen folder we're holding security-scoped access to, if any.
    private var accessedFolder: URL?

    private var libraryURL: URL { rootURL.appendingPathComponent("library.json") }
    private var capturesURL: URL { rootURL.appendingPathComponent("Captures", isDirectory: true) }
    private var writeOptions: Data.WritingOptions {
        isUsingExternalStorage ? [.atomic] : [.atomic, .completeFileProtection]
    }

    private static var internalRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName, isDirectory: true)
    }

    init() {
        rootURL = Self.internalRoot
        if let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            if let folder = Self.openBookmarkedFolder(data) {
                accessedFolder = folder
                rootURL = folder.appendingPathComponent(Self.folderName, isDirectory: true)
                isUsingExternalStorage = true
            } else {
                storageWarning = "The folder you chose in Settings isn't available, so internal storage is shown instead."
            }
        }
        prepareFolders()
        load()
    }

    private static func openBookmarkedFolder(_ data: Data) -> URL? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale),
              url.startAccessingSecurityScopedResource() else { return nil }
        if isStale, let fresh = try? url.bookmarkData() {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        return url
    }

    private func prepareFolders() {
        let attributes: [FileAttributeKey: Any]? = isUsingExternalStorage ? nil : [.protectionKey: FileProtectionType.complete]
        try? FileManager.default.createDirectory(at: capturesURL, withIntermediateDirectories: true, attributes: attributes)
    }

    // MARK: - Storage location

    var storageLocationDescription: String {
        isUsingExternalStorage ? "Files: \(accessedFolder?.lastPathComponent ?? "chosen folder")/\(Self.folderName)" : "Inside the app (encrypted by iOS)"
    }

    /// Total size of the kept photos, in bytes.
    func usedBytes() async -> Int64 {
        let folder = capturesURL
        return await Task.detached(priority: .utility) {
            let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return urls.reduce(Int64(0)) { total, url in
                total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }.value
    }

    /// Moves the library and photos into a folder picked in Files.
    func moveStorage(toFolder picked: URL) async throws {
        guard picked.startAccessingSecurityScopedResource() else { throw MelonStoreError.folderNotAccessible }
        let target = picked.appendingPathComponent(Self.folderName, isDirectory: true)
        do {
            let bookmark = try picked.bookmarkData()
            try await switchRoot(to: target, external: true, accessing: picked)
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        } catch {
            picked.stopAccessingSecurityScopedResource()
            throw error
        }
    }

    /// Moves everything back into the app's own (encrypted) storage.
    func useInternalStorage() async throws {
        try await switchRoot(to: Self.internalRoot, external: false, accessing: nil)
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
    }

    private func switchRoot(to target: URL, external: Bool, accessing folder: URL?) async throws {
        let source = rootURL
        guard source.standardizedFileURL != target.standardizedFileURL else { return }

        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.copyLibrary(from: source, to: target, protect: !external)
            }.value
        } catch {
            throw MelonStoreError.moveFailed(error.localizedDescription)
        }

        // Only remove the old copy once the new one is in place.
        let previousFolder = accessedFolder
        rootURL = target
        accessedFolder = folder
        isUsingExternalStorage = external
        storageWarning = nil
        load()
        try? FileManager.default.removeItem(at: source)
        previousFolder?.stopAccessingSecurityScopedResource()
    }

    nonisolated private static func copyLibrary(from source: URL, to target: URL, protect: Bool) throws {
        let fileManager = FileManager.default
        let attributes: [FileAttributeKey: Any]? = protect ? [.protectionKey: FileProtectionType.complete] : nil
        let targetCaptures = target.appendingPathComponent("Captures", isDirectory: true)
        try fileManager.createDirectory(at: targetCaptures, withIntermediateDirectories: true, attributes: attributes)

        let sourceCaptures = source.appendingPathComponent("Captures", isDirectory: true)
        for file in (try? fileManager.contentsOfDirectory(at: sourceCaptures, includingPropertiesForKeys: nil)) ?? [] {
            let destination = targetCaptures.appendingPathComponent(file.lastPathComponent)
            if !fileManager.fileExists(atPath: destination.path) {
                try fileManager.copyItem(at: file, to: destination)
            }
        }

        let sourceLibrary = source.appendingPathComponent("library.json")
        let targetLibrary = target.appendingPathComponent("library.json")
        if fileManager.fileExists(atPath: sourceLibrary.path) {
            if fileManager.fileExists(atPath: targetLibrary.path) { try fileManager.removeItem(at: targetLibrary) }
            try fileManager.copyItem(at: sourceLibrary, to: targetLibrary)
        }
        guard fileManager.fileExists(atPath: targetLibrary.path) || !fileManager.fileExists(atPath: sourceLibrary.path) else {
            throw MelonStoreError.moveFailed("the library file wasn't copied")
        }
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
        try data.write(to: fileURL(of: record), options: writeOptions)
        captures.append(record)
        save()
        return record
    }

    /// Marks a photo as uploaded and deletes its file: once it's safely in
    /// Drive there's no need to keep it on the device. The record stays so
    /// the melon's history (date, HST) is still listed.
    func markUploaded(_ captureID: UUID) {
        guard let i = captures.firstIndex(where: { $0.id == captureID }) else { return }
        captures[i].status = .uploaded
        removeFile(of: captures[i])
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
        // Photos uploaded before files were auto-deleted: clean them up.
        for capture in captures where capture.status == .uploaded {
            removeFile(of: capture)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Library(melons: melons, captures: captures)) else { return }
        try? data.write(to: libraryURL, options: writeOptions)
    }
}

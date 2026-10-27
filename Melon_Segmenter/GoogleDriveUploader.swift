import UIKit
import GoogleSignIn

enum GoogleDriveUploaderError: LocalizedError {
    case invalidServerResponse
    case uploadFailed(statusCode: Int, message: String)
    case driveScopeNotGranted

    var errorDescription: String? {
        switch self {
        case .invalidServerResponse:
            return "Invalid response from the Google Drive server."
        case .uploadFailed(let statusCode, let message):
            return "Upload failed (HTTP \(statusCode)): \(message)"
        case .driveScopeNotGranted:
            return "Google didn't grant Drive access for this account. In Google Cloud Console, check that the Drive API is enabled and that this Google account is added as a test user on the OAuth consent screen, then try again."
        }
    }
}

/// Signs the user in to Google (if needed) and uploads a capture's artifacts
/// (original photo, segmented cutout, GNG visualization, metrics) to Drive
/// via the Drive v3 REST API, plus appends a row to a cumulative CSV log.
@MainActor
final class GoogleDriveUploader {
    static let driveFileScope = "https://www.googleapis.com/auth/drive.file"
    private static let rootFolderName = "Melon Segmenter"
    private static let densityLogFileName = "density_log.csv"

    /// Signs in (or reuses the current session), requesting the Drive scope
    /// if it isn't already granted. Explicitly re-checks `grantedScopes`
    /// afterwards rather than trusting the sign-in call to have succeeded —
    /// if the Google account isn't added as a test user on the OAuth
    /// consent screen (or the Drive API isn't enabled), Google silently
    /// completes sign-in without the scope instead of failing here, and the
    /// first sign of trouble would otherwise be an opaque 403 from the
    /// upload request itself.
    private func ensureSignedIn(presentingViewController: UIViewController) async throws -> GIDGoogleUser {
        let user: GIDGoogleUser
        if let currentUser = GIDSignIn.sharedInstance.currentUser,
           currentUser.grantedScopes?.contains(Self.driveFileScope) == true {
            user = currentUser
        } else if let currentUser = GIDSignIn.sharedInstance.currentUser {
            let result = try await currentUser.addScopes(
                [Self.driveFileScope],
                presenting: presentingViewController
            )
            user = result.user
        } else {
            let result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: presentingViewController,
                hint: nil,
                additionalScopes: [Self.driveFileScope]
            )
            user = result.user
        }

        guard user.grantedScopes?.contains(Self.driveFileScope) == true else {
            throw GoogleDriveUploaderError.driveScopeNotGranted
        }
        return user
    }

    /// Uploads one capture's full artifact set into "Melon Segmenter/<dd_MM_yyyy>/"
    /// and appends a row to the cumulative "density_log.csv" at the root.
    func uploadCaptureBundle(
        captureIndex: String,
        originalPNGData: Data,
        segmentedPNGData: Data,
        visualizationPNGData: Data,
        metrics: NetDensityMetrics,
        presentingViewController: UIViewController
    ) async throws {
        let user = try await ensureSignedIn(presentingViewController: presentingViewController)
        let token = user.accessToken.tokenString

        let now = Date()
        let rootFolderId = try await findOrCreateFolder(named: Self.rootFolderName, parentId: nil, token: token)
        let folderDateString = Self.dateFolderName(from: now)
        let dateFolderId = try await findOrCreateFolder(named: folderDateString, parentId: rootFolderId, token: token)
        let timestampString = Self.timestampString(from: now)
        let fileStamp = Self.localFileStamp(from: now)

        let safeIndex = captureIndex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "unindexed-\(Int(Date().timeIntervalSince1970))"
            : captureIndex.trimmingCharacters(in: .whitespacesAndNewlines)

        _ = try await uploadFile(
            data: originalPNGData,
            fileName: "melon-\(safeIndex)-\(fileStamp)-original.png",
            mimeType: "image/png",
            parentId: dateFolderId,
            token: token
        )
        _ = try await uploadFile(
            data: segmentedPNGData,
            fileName: "melon-\(safeIndex)-\(fileStamp)-segmented.png",
            mimeType: "image/png",
            parentId: dateFolderId,
            token: token
        )
        _ = try await uploadFile(
            data: visualizationPNGData,
            fileName: "melon-\(safeIndex)-\(fileStamp)-gng.png",
            mimeType: "image/png",
            parentId: dateFolderId,
            token: token
        )

        let metricsJSON: [String: Any] = [
            "captureIndex": safeIndex,
            "date": timestampString,
            "polarity": metrics.invertPolarity ? "light" : "dark",
            "nodeCount": metrics.nodeCount,
            "prunedEdgeCount": metrics.prunedEdgeCount,
            "roiAreaPx": metrics.roiAreaPx,
            "branchDensity": metrics.branchDensity,
            "lengthDensity": metrics.lengthDensity,
            "dataFractionOfROI": metrics.dataFractionOfROI,
            "strokeWidthPx": metrics.strokeWidthPx,
            "dEq": metrics.dEq,
            "meanL": metrics.meanL,
            "meanA": metrics.meanA,
            "meanB": metrics.meanB,
        ]
        let metricsData = try JSONSerialization.data(withJSONObject: metricsJSON, options: [.prettyPrinted])
        _ = try await uploadFile(
            data: metricsData,
            fileName: "melon-\(safeIndex)-\(fileStamp)-metrics.json",
            mimeType: "application/json",
            parentId: dateFolderId,
            token: token
        )

        try await appendDensityLogRow(
            captureIndex: safeIndex,
            dateString: timestampString,
            metrics: metrics,
            rootFolderId: rootFolderId,
            token: token
        )
    }

    /// Returns the id of the folder named `name` under `parentId` (or Drive root), creating it if missing.
    private func findOrCreateFolder(named name: String, parentId: String?, token: String) async throws -> String {
        let parentClause = "'\(parentId ?? "root")' in parents"
        let query = "name = '\(escaped(name))' and mimeType = 'application/vnd.google-apps.folder' and trashed = false and \(parentClause)"

        if let existingId = try await findFile(query: query, token: token) {
            return existingId
        }

        var metadata: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder",
        ]
        if let parentId {
            metadata["parents"] = [parentId]
        }

        var createRequest = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!)
        createRequest.httpMethod = "POST"
        createRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        createRequest.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        createRequest.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let (createData, createResponse) = try await URLSession.shared.data(for: createRequest)
        guard let createHTTPResponse = createResponse as? HTTPURLResponse, (200..<300).contains(createHTTPResponse.statusCode) else {
            let message = String(data: createData, encoding: .utf8) ?? "unknown error"
            throw GoogleDriveUploaderError.uploadFailed(statusCode: (createResponse as? HTTPURLResponse)?.statusCode ?? -1, message: message)
        }

        struct CreateResponse: Decodable { let id: String }
        return try JSONDecoder().decode(CreateResponse.self, from: createData).id
    }

    /// Finds-or-creates "density_log.csv" under `rootFolderId` and appends
    /// one row. Deliberately a different file from the old
    /// "complexity_log.csv" — the schema is unrelated, so appending would
    /// have shifted every column.
    private func appendDensityLogRow(
        captureIndex: String,
        dateString: String,
        metrics: NetDensityMetrics,
        rootFolderId: String,
        token: String
    ) async throws {
        let header = "capture_index,date,polarity,node_count,pruned_edge_count,roi_area_px,branch_density,length_density,data_fraction_of_roi,stroke_width_px,d_eq,mean_l,mean_a,mean_b\n"
        let polarity = metrics.invertPolarity ? "light" : "dark"
        let newRow = "\(csvEscape(captureIndex)),\(dateString),\(polarity),\(metrics.nodeCount),\(metrics.prunedEdgeCount),\(metrics.roiAreaPx),\(metrics.branchDensity),\(metrics.lengthDensity),\(metrics.dataFractionOfROI),\(metrics.strokeWidthPx),\(metrics.dEq),\(metrics.meanL),\(metrics.meanA),\(metrics.meanB)\n"

        let query = "name = '\(escaped(Self.densityLogFileName))' and trashed = false and '\(rootFolderId)' in parents"
        if let existingId = try await findFile(query: query, token: token) {
            let currentContent = try await downloadTextFile(fileId: existingId, token: token)
            try await updateFileContent(fileId: existingId, content: currentContent + newRow, mimeType: "text/csv", token: token)
        } else {
            _ = try await uploadFile(
                data: Data((header + newRow).utf8),
                fileName: Self.densityLogFileName,
                mimeType: "text/csv",
                parentId: rootFolderId,
                token: token
            )
        }
    }

    /// Returns the id of the first file matching `query`, or nil if none exists.
    private func findFile(query: String, token: String) async throws -> String? {
        var listURLComponents = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        listURLComponents.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id,name)"),
        ]

        var listRequest = URLRequest(url: listURLComponents.url!)
        listRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (listData, listResponse) = try await URLSession.shared.data(for: listRequest)
        guard let listHTTPResponse = listResponse as? HTTPURLResponse, (200..<300).contains(listHTTPResponse.statusCode) else {
            let message = String(data: listData, encoding: .utf8) ?? "unknown error"
            throw GoogleDriveUploaderError.uploadFailed(statusCode: (listResponse as? HTTPURLResponse)?.statusCode ?? -1, message: message)
        }

        struct FileListResponse: Decodable {
            struct File: Decodable { let id: String }
            let files: [File]
        }
        let listed = try JSONDecoder().decode(FileListResponse.self, from: listData)
        return listed.files.first?.id
    }

    private func downloadTextFile(fileId: String, token: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)?alt=media")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "unknown error"
            throw GoogleDriveUploaderError.uploadFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, message: message)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func updateFileContent(fileId: String, content: String, mimeType: String, token: String) async throws {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(fileId)?uploadType=media")!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(content.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "unknown error"
            throw GoogleDriveUploaderError.uploadFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? -1, message: message)
        }
    }

    /// Uploads `data` as a new file named `fileName` under `parentId`, returning the new file's id.
    private func uploadFile(data: Data, fileName: String, mimeType: String, parentId: String, token: String) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(
            url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id")!
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.multipartBody(data: data, fileName: fileName, mimeType: mimeType, boundary: boundary, parentId: parentId)

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleDriveUploaderError.invalidServerResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: responseData, encoding: .utf8) ?? "unknown error"
            throw GoogleDriveUploaderError.uploadFailed(statusCode: httpResponse.statusCode, message: message)
        }

        struct UploadResponse: Decodable { let id: String }
        return try JSONDecoder().decode(UploadResponse.self, from: responseData).id
    }

    /// Local date + time, e.g. "20261027T194516" — appended to uploaded file
    /// names so repeat uploads of the same capture index on the same day
    /// get distinct names instead of piling up identically named files.
    private static func localFileStamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.string(from: date)
    }

    /// Day-only — used for the Drive subfolder name, so captures from the
    /// same day keep landing in the same folder.
    private static func dateFolderName(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd_MM_yyyy"
        return formatter.string(from: date)
    }

    /// Day + time — used for the "date" value recorded in the metrics
    /// JSON/CSV, so multiple captures on the same day (e.g. testing the
    /// same melon a few times) can still be told apart.
    private static func timestampString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd_MM_yyyy HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func multipartBody(data: Data, fileName: String, mimeType: String, boundary: String, parentId: String) -> Data {
        let metadata: [String: Any] = ["name": fileName, "parents": [parentId]]
        let metadataJSON = (try? JSONSerialization.data(withJSONObject: metadata)) ?? Data()

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadataJSON)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--".data(using: .utf8)!)
        return body
    }

    private func escaped(_ name: String) -> String {
        name.replacingOccurrences(of: "'", with: "\\'")
    }

    private func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }
}

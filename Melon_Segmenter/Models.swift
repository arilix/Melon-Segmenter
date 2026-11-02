import Foundation

/// One melon being tracked. HST (hari setelah tanam / days after planting)
/// is entered once when the melon is added; it's stored as a planting date
/// so the current HST can be derived from the calendar at any time.
struct Melon: Identifiable, Codable, Hashable {
    var id = UUID()
    /// The melon's ID (shown as "capture index" everywhere else).
    var captureIndex: String
    /// Start of the day the melon was planted.
    var plantingDate: Date
    var createdAt = Date()

    /// Whole calendar days between planting and `date`.
    func hst(on date: Date = Date(), calendar: Calendar = .current) -> Int {
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: plantingDate),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        return max(0, days)
    }

    /// Planting date for a melon whose HST is `hst` on `date`.
    static func plantingDate(hst: Int, on date: Date = Date(), calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: -hst, to: today) ?? today
    }
}

/// A photo kept for a melon, waiting to be segmented/analyzed/uploaded.
struct CaptureRecord: Identifiable, Codable, Hashable {
    enum Status: String, Codable {
        case pending
        case uploaded
    }

    var id = UUID()
    var melonID: UUID
    var takenAt: Date
    /// The melon's HST on the day this photo was taken.
    var hstAtCapture: Int
    /// File name inside the captures folder.
    var fileName: String
    var status: Status = .pending
}

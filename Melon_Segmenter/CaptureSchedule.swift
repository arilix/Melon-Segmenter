import Combine
import Foundation
import UserNotifications

/// When data should be collected: on chosen weekdays, or every N days.
/// One schedule applies to all melons.
struct CaptureSchedule: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case weekdays
        case everyNDays

        var id: String { rawValue }
    }

    var isEnabled = false
    var mode: Mode = .weekdays
    /// Calendar weekdays: 1 = Sunday … 7 = Saturday.
    var weekdays: Set<Int> = [2, 4, 6]
    var intervalDays = 2
    /// First capture day for the every-N-days mode.
    var intervalStart = Calendar.current.startOfDay(for: Date())
    /// Reminder time, in minutes after midnight. Always kept inside the window below.
    var reminderMinuteOfDay = 7 * 60

    /// Reminders are only allowed in the morning-to-late-afternoon window.
    static let earliestMinute = 6 * 60
    static let latestMinute = 17 * 60 + 30

    static func clamp(_ minuteOfDay: Int) -> Int {
        min(max(minuteOfDay, earliestMinute), latestMinute)
    }

    func isCaptureDay(_ date: Date, calendar: Calendar = .current) -> Bool {
        switch mode {
        case .weekdays:
            return weekdays.contains(calendar.component(.weekday, from: date))
        case .everyNDays:
            let days = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: intervalStart),
                to: calendar.startOfDay(for: date)
            ).day ?? -1
            return days >= 0 && days % max(1, intervalDays) == 0
        }
    }

    /// The reminder moment on `day`.
    func reminderDate(on day: Date, calendar: Calendar = .current) -> Date {
        let minute = Self.clamp(reminderMinuteOfDay)
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day) ?? day
    }

    /// Upcoming reminder moments after `date`, soonest first.
    func upcomingReminders(after date: Date = Date(), count: Int, calendar: Calendar = .current) -> [Date] {
        guard isEnabled else { return [] }
        var result: [Date] = []
        let today = calendar.startOfDay(for: date)
        for offset in 0..<800 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { break }
            guard isCaptureDay(day, calendar: calendar) else { continue }
            let moment = reminderDate(on: day, calendar: calendar)
            if moment > date { result.append(moment) }
            if result.count >= count { break }
        }
        return result
    }
}

/// Holds the schedule (persisted in UserDefaults) and keeps the local
/// reminders in step with it.
@MainActor
final class ScheduleStore: ObservableObject {
    @Published var schedule: CaptureSchedule {
        didSet {
            guard schedule != oldValue else { return }
            save()
            Task { await reschedule() }
        }
    }
    /// Set when reminders are on but iOS notifications are blocked for the app.
    @Published private(set) var notificationsBlocked = false

    private static let key = "melon.captureSchedule"
    private static let idPrefix = "melon.capture."

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           var saved = try? JSONDecoder().decode(CaptureSchedule.self, from: data) {
            saved.reminderMinuteOfDay = CaptureSchedule.clamp(saved.reminderMinuteOfDay)
            schedule = saved
        } else {
            schedule = CaptureSchedule()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(schedule) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Re-creates every pending reminder from the current schedule.
    func reschedule() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(Self.idPrefix) }
        )
        guard schedule.isEnabled else {
            notificationsBlocked = false
            return
        }

        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            status = await center.notificationSettings().authorizationStatus
        }
        guard status == .authorized || status == .provisional || status == .ephemeral else {
            notificationsBlocked = true
            return
        }
        notificationsBlocked = false

        let calendar = Calendar.current
        let minute = CaptureSchedule.clamp(schedule.reminderMinuteOfDay)

        switch schedule.mode {
        case .weekdays:
            // Weekly repeating reminders keep firing without the app being opened.
            for weekday in schedule.weekdays.sorted() {
                var components = DateComponents()
                components.weekday = weekday
                components.hour = minute / 60
                components.minute = minute % 60
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                await add(id: "\(Self.idPrefix)weekday.\(weekday)", trigger: trigger)
            }
        case .everyNDays:
            // iOS can't repeat "every N days", so queue the next ones (the
            // system keeps at most 64 pending); each app launch tops them up.
            for moment in schedule.upcomingReminders(count: 60) {
                let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: moment)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                await add(id: "\(Self.idPrefix)day.\(Int(moment.timeIntervalSince1970))", trigger: trigger)
            }
        }
    }

    private func add(id: String, trigger: UNNotificationTrigger) async {
        let content = UNMutableNotificationContent()
        content.title = "Time to collect melon data"
        content.body = "Take today's photos of your melons."
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}

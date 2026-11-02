import SwiftUI
import UniformTypeIdentifiers

/// Account, capture schedule with reminders, and where photos are stored.
struct SettingsView: View {
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var store: MelonStore
    @EnvironmentObject private var scheduleStore: ScheduleStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var isPickingFolder = false
    @State private var isMoving = false
    @State private var usedBytes: Int64?
    @State private var errorMessage: String?

    private let calendar = Calendar.current

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                scheduleSection
                storageSection
            }
            .scrollContentBackground(.hidden)
            .background(MelonTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
                handlePickedFolder(result)
            }
            .alert("Storage", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task { usedBytes = await store.usedBytes() }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Account

    private var accountSection: some View {
        Section("Google account") {
            Text(auth.email ?? "Signed in")
            Button("Sign out", role: .destructive) {
                auth.signOut()
                dismiss()
            }
        }
    }

    // MARK: - Schedule

    private var scheduleSection: some View {
        Section {
            Toggle("Remind me to collect data", isOn: $scheduleStore.schedule.isEnabled)
                .tint(MelonTheme.accentTeal)

            if scheduleStore.schedule.isEnabled {
                Picker("Repeat", selection: $scheduleStore.schedule.mode) {
                    Text("Days of the week").tag(CaptureSchedule.Mode.weekdays)
                    Text("Every N days").tag(CaptureSchedule.Mode.everyNDays)
                }
                .pickerStyle(.segmented)

                switch scheduleStore.schedule.mode {
                case .weekdays:
                    weekdayPicker
                case .everyNDays:
                    Stepper("Every \(scheduleStore.schedule.intervalDays) day(s)", value: $scheduleStore.schedule.intervalDays, in: 1...30)
                    DatePicker("Starting", selection: $scheduleStore.schedule.intervalStart, displayedComponents: .date)
                }

                DatePicker(
                    "Reminder time",
                    selection: reminderTimeBinding,
                    in: reminderTimeRange,
                    displayedComponents: .hourAndMinute
                )

                if scheduleStore.notificationsBlocked {
                    Label("Notifications are turned off for this app.", systemImage: "bell.slash.fill")
                        .foregroundStyle(.orange)
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                } else if let next = scheduleStore.schedule.upcomingReminders(count: 1).first {
                    LabeledContent("Next reminder") {
                        Text(next.formatted(date: .abbreviated, time: .shortened))
                    }
                } else if scheduleStore.schedule.mode == .weekdays {
                    Text("Pick at least one day.")
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Capture schedule")
        } footer: {
            Text("One schedule for all melons. Reminders can be set between 06:00 and 17:30.")
        }
    }

    private var weekdayPicker: some View {
        HStack(spacing: 6) {
            // Monday first.
            ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { weekday in
                let isOn = scheduleStore.schedule.weekdays.contains(weekday)
                Button {
                    if isOn {
                        scheduleStore.schedule.weekdays.remove(weekday)
                    } else {
                        scheduleStore.schedule.weekdays.insert(weekday)
                    }
                } label: {
                    Text(calendar.veryShortWeekdaySymbols[weekday - 1])
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .foregroundStyle(isOn ? MelonTheme.navyDeep : .white)
                        .background(isOn ? MelonTheme.accentTeal : Color.white.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(calendar.weekdaySymbols[weekday - 1])
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }

    private var reminderTimeRange: ClosedRange<Date> {
        let today = calendar.startOfDay(for: Date())
        let lower = calendar.date(byAdding: .minute, value: CaptureSchedule.earliestMinute, to: today) ?? today
        let upper = calendar.date(byAdding: .minute, value: CaptureSchedule.latestMinute, to: today) ?? today
        return lower...upper
    }

    private var reminderTimeBinding: Binding<Date> {
        Binding(
            get: {
                let minute = CaptureSchedule.clamp(scheduleStore.schedule.reminderMinuteOfDay)
                return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = calendar.dateComponents([.hour, .minute], from: date)
                scheduleStore.schedule.reminderMinuteOfDay = CaptureSchedule.clamp((parts.hour ?? 7) * 60 + (parts.minute ?? 0))
            }
        )
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section {
            LabeledContent("Location") {
                Text(store.storageLocationDescription)
                    .multilineTextAlignment(.trailing)
            }
            if let usedBytes {
                LabeledContent("Photos use") {
                    Text(ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file))
                }
            }
            if let warning = store.storageWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            if isMoving {
                HStack {
                    ProgressView()
                    Text("Moving your photos…")
                }
            } else {
                Button("Choose folder in Files…") { isPickingFolder = true }
                if store.isUsingExternalStorage {
                    Button("Use internal storage") { moveToInternal() }
                }
            }
        } header: {
            Text("Photo storage")
        } footer: {
            Text("Kept photos and melon data move to the new place and are removed from the old one. A folder in Files (for example iCloud Drive) isn't covered by the app's iOS encryption.")
        }
    }

    private func handlePickedFolder(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let folder):
            isMoving = true
            Task {
                defer { isMoving = false }
                do {
                    try await store.moveStorage(toFolder: folder)
                    usedBytes = await store.usedBytes()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func moveToInternal() {
        isMoving = true
        Task {
            defer { isMoving = false }
            do {
                try await store.useInternalStorage()
                usedBytes = await store.usedBytes()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

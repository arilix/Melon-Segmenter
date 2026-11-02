import SwiftUI

/// Home screen after sign-in: every melon with its current HST and how many
/// kept photos are still waiting to be processed.
struct MelonListView: View {
    @EnvironmentObject private var store: MelonStore
    @EnvironmentObject private var scheduleStore: ScheduleStore

    @State private var path: [UUID] = []
    @State private var isAddingMelon = false
    @State private var isShowingSettings = false
    @State private var melonPendingDelete: Melon?
    @State private var processingQueue: ProcessingQueue?

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                MelonTheme.backgroundGradient.ignoresSafeArea()

                if store.melons.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Melons")
            .navigationDestination(for: UUID.self) { MelonDetailView(melonID: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { isShowingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    if !store.melons.isEmpty { EditButton() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isAddingMelon = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $isAddingMelon) {
                AddMelonView { melon in path.append(melon.id) }
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView()
            }
            .fullScreenCover(item: $processingQueue) { queue in
                ProcessingQueueView(queue: queue) { processingQueue = nil }
            }
            .confirmationDialog(
                "Delete melon \(melonPendingDelete?.captureIndex ?? "")?",
                isPresented: Binding(get: { melonPendingDelete != nil }, set: { if !$0 { melonPendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete melon and its photos", role: .destructive) {
                    if let melon = melonPendingDelete { store.deleteMelon(melon) }
                    melonPendingDelete = nil
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 56))
                .foregroundStyle(MelonTheme.meadowGreen)
            Text("No melons yet")
                .font(.title3.bold())
                .foregroundStyle(.white)
            Text("Add a melon with its ID and HST, then keep photos of it to process later.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button { isAddingMelon = true } label: {
                Label("Add Melon", systemImage: "plus")
            }
            .buttonStyle(MelonPrimaryButtonStyle())
            .padding(.horizontal, 40)
            .padding(.top, 8)
        }
    }

    private var list: some View {
        let waiting = store.captures.filter { $0.status == .pending }
        let schedule = scheduleStore.schedule
        return List {
            if schedule.isEnabled, schedule.isCaptureDay(Date()) {
                Label("Today is a capture day · reminder at \(schedule.reminderDate(on: Date()).formatted(date: .omitted, time: .shortened))", systemImage: "calendar.badge.clock")
                    .font(.subheadline.bold())
                    .foregroundStyle(MelonTheme.navyDeep)
                    .listRowBackground(MelonTheme.limeGreen)
            }
            if !waiting.isEmpty {
                Button {
                    // Oldest first, across all melons.
                    processingQueue = ProcessingQueue(captureIDs: waiting.sorted { $0.takenAt < $1.takenAt }.map(\.id))
                } label: {
                    Label("Process all waiting (\(waiting.count))", systemImage: "play.fill")
                }
                .buttonStyle(MelonPrimaryButtonStyle())
                .listRowBackground(Color.clear)
            }
            ForEach(store.melons) { melon in
                NavigationLink(value: melon.id) {
                    row(for: melon)
                }
                .listRowBackground(MelonTheme.cardBackground)
                .swipeActions {
                    Button(role: .destructive) { melonPendingDelete = melon } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            // Edit mode shows the red delete buttons; the confirmation dialog still asks first.
            .onDelete { offsets in
                if let i = offsets.first { melonPendingDelete = store.melons[i] }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func row(for melon: Melon) -> some View {
        let pending = store.pendingCount(for: melon.id)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(melon.captureIndex)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("HST \(melon.hst())")
                    .font(.subheadline)
                    .foregroundStyle(MelonTheme.accentTeal)
            }
            Spacer()
            if pending > 0 {
                Text("\(pending) waiting")
                    .font(.caption.bold())
                    .foregroundStyle(MelonTheme.navyDeep)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(MelonTheme.limeGreen, in: Capsule())
            }
        }
        .padding(.vertical, 4)
    }
}

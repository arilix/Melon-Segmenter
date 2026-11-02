import SwiftUI

/// Registers a melon: its ID (capture index) and its HST on the day it's
/// added. HST is typed in only here; afterwards it's counted from the date.
struct AddMelonView: View {
    @EnvironmentObject private var store: MelonStore
    @Environment(\.dismiss) private var dismiss

    var onAdded: (Melon) -> Void

    @State private var captureIndex = ""
    @State private var hstText = ""
    @State private var errorMessage: String?

    private var hst: Int? {
        guard let value = Int(hstText.trimmingCharacters(in: .whitespaces)), value >= 0 else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Melon ID, e.g. 001", text: $captureIndex)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("HST today (days after planting)", text: $hstText)
                        .keyboardType(.numberPad)
                } footer: {
                    Text("HST is entered only once. The app counts it up by itself from the day you add the melon.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(MelonTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Add Melon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(captureIndex.trimmingCharacters(in: .whitespaces).isEmpty || hst == nil)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func save() {
        guard let hst else { return }
        do {
            let melon = try store.addMelon(captureIndex: captureIndex, hst: hst)
            onAdded(melon)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

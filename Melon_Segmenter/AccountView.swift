import SwiftUI

/// Account sheet: who's signed in, and sign out.
struct AccountView: View {
    @EnvironmentObject private var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Google account") {
                    Text(auth.email ?? "Signed in")
                        .foregroundStyle(.white)
                }
                Section {
                    Button("Sign out", role: .destructive) {
                        auth.signOut()
                        dismiss()
                    }
                } footer: {
                    Text("Photos kept on this device stay here after signing out.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(MelonTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

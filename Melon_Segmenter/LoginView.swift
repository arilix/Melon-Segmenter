import SwiftUI

/// Shown at launch until the user has signed in with Google. Signing in up
/// front (instead of at upload time) means uploads never get interrupted
/// by a login prompt.
struct LoginView: View {
    @EnvironmentObject private var auth: AuthManager

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image("MelonLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                .shadow(color: MelonTheme.accentTeal.opacity(0.35), radius: 24, y: 8)

            VStack(spacing: 8) {
                Text("Melon")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                +
                Text(" Segmenter")
                    .font(.largeTitle.bold())
                    .foregroundStyle(MelonTheme.meadowGreen)

                Text("Sign in with Google so your results can be saved to your own Google Drive.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            if let message = auth.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()

            Button {
                Task { await auth.signIn() }
            } label: {
                if auth.isSigningIn {
                    ProgressView().tint(MelonTheme.navyDeep)
                } else {
                    Label("Sign in with Google", systemImage: "person.crop.circle.badge.checkmark")
                }
            }
            .buttonStyle(MelonPrimaryButtonStyle())
            .disabled(auth.isSigningIn)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }
}

import SwiftUI
import GoogleSignIn

@main struct MyApp: App {
    @StateObject private var auth = AuthManager()
    @StateObject private var store = MelonStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(store)
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}

/// Gate: restoring the saved session, then the login screen, then the app.
private struct RootView: View {
    @EnvironmentObject private var auth: AuthManager

    var body: some View {
        ZStack {
            MelonTheme.backgroundGradient.ignoresSafeArea()

            if auth.isRestoring {
                ProgressView().tint(MelonTheme.accentTeal)
            } else if auth.user == nil {
                LoginView()
            } else {
                MelonListView()
            }
        }
        .preferredColorScheme(.dark)
        .task { await auth.restore() }
    }
}

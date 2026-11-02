import SwiftUI
import GoogleSignIn

@main struct MyApp: App {
    @StateObject private var auth = AuthManager()
    @StateObject private var store = MelonStore()
    @StateObject private var scheduleStore = ScheduleStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(store)
                .environmentObject(scheduleStore)
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
                // Top up the queued reminders whenever the app comes forward.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await scheduleStore.reschedule() } }
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

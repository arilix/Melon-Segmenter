import SwiftUI
import GoogleSignIn

@main struct MyApp: App {
    init() {
        GIDSignIn.sharedInstance.restorePreviousSignIn()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}

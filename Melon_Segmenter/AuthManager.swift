import Combine
import UIKit
import GoogleSignIn

/// Google sign-in state for the whole app. The user signs in once at launch
/// (with the Drive scope), and uploads later reuse that session. Google
/// Sign-In keeps the tokens in the iOS Keychain.
@MainActor
final class AuthManager: ObservableObject {
    @Published private(set) var user: GIDGoogleUser?
    @Published private(set) var isRestoring = true
    @Published private(set) var isSigningIn = false
    @Published var errorMessage: String?

    var email: String? { user?.profile?.email }

    private func hasDriveScope(_ user: GIDGoogleUser) -> Bool {
        user.grantedScopes?.contains(GoogleDriveUploader.driveFileScope) == true
    }

    /// Restores the previous session, if any. A session that predates the
    /// Drive scope is treated as signed out so the user is asked again.
    func restore() async {
        defer { isRestoring = false }
        do {
            let restored = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            user = hasDriveScope(restored) ? restored : nil
        } catch {
            user = nil
        }
    }

    func signIn() async {
        guard !isSigningIn else { return }
        guard let presenter = UIApplication.shared.keyWindowRootViewController else {
            errorMessage = "Couldn't find a view to present Google sign-in."
            return
        }
        errorMessage = nil
        isSigningIn = true
        defer { isSigningIn = false }

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter,
                hint: nil,
                additionalScopes: [GoogleDriveUploader.driveFileScope]
            )
            guard hasDriveScope(result.user) else {
                GIDSignIn.sharedInstance.signOut()
                errorMessage = GoogleDriveUploaderError.driveScopeNotGranted.localizedDescription
                return
            }
            user = result.user
        } catch {
            let nsError = error as NSError
            if nsError.domain == kGIDSignInErrorDomain, nsError.code == GIDSignInError.canceled.rawValue { return }
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        user = nil
    }
}

extension UIApplication {
    var keyWindowRootViewController: UIViewController? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?.rootViewController
    }
}

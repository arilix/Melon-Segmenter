/// Google Sign-In on Android needs an OAuth *Web application* client ID as the
/// server client ID, plus an *Android* OAuth client for this app's package name
/// and signing SHA-1 in the same Google Cloud project. See README.
///
/// Pass it at build time:
///   flutter build apk --dart-define=GOOGLE_SERVER_CLIENT_ID=xxxx.apps.googleusercontent.com
const googleServerClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

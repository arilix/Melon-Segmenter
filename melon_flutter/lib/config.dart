/// Google Sign-In on Android needs an OAuth *Web application* client ID as the
/// server client ID, plus an *Android* OAuth client for this app's package name
/// and signing SHA-1 in the same Google Cloud project. See README.
///
/// The default below is this project's Web client. Override it at build time:
///   flutter build apk --dart-define=GOOGLE_SERVER_CLIENT_ID=xxxx.apps.googleusercontent.com
const googleServerClientId = String.fromEnvironment(
  'GOOGLE_SERVER_CLIENT_ID',
  defaultValue: '742595593039-vb78tud004lfu27sc1vl9urghs86ujat.apps.googleusercontent.com',
);

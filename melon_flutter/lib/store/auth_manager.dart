import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../config.dart';
import '../services/drive_uploader.dart';

/// Google sign-in state. The user signs in once at launch (with the Drive
/// scope) and uploads reuse that session.
class AuthManager extends ChangeNotifier {
  GoogleSignInAccount? user;
  bool isRestoring = true;
  bool isSigningIn = false;
  String? errorMessage;
  bool _initialized = false;

  String? get email => user?.email;

  Future<void> _init() async {
    if (_initialized) return;
    await GoogleSignIn.instance.initialize(
      serverClientId: googleServerClientId.isEmpty ? null : googleServerClientId,
    );
    _initialized = true;
  }

  Future<void> restore() async {
    try {
      await _init();
      final account = await GoogleSignIn.instance.attemptLightweightAuthentication();
      if (account != null && await _hasDriveScope(account)) user = account;
    } catch (_) {
      user = null;
    }
    isRestoring = false;
    notifyListeners();
  }

  Future<bool> _hasDriveScope(GoogleSignInAccount a) async =>
      await a.authorizationClient.authorizationForScopes([DriveUploader.driveFileScope]) != null;

  Future<void> signIn() async {
    if (isSigningIn) return;
    errorMessage = null;
    isSigningIn = true;
    notifyListeners();
    try {
      await _init();
      final account = await GoogleSignIn.instance.authenticate();
      await account.authorizationClient.authorizeScopes([DriveUploader.driveFileScope]);
      if (!await _hasDriveScope(account)) {
        await GoogleSignIn.instance.signOut();
        errorMessage = DriveException.driveScopeNotGranted().message;
      } else {
        user = account;
      }
    } on GoogleSignInException catch (e) {
      if (e.code != GoogleSignInExceptionCode.canceled) {
        errorMessage = e.description ?? 'Google sign-in failed (${e.code.name}).';
      }
    } catch (e) {
      errorMessage = '$e';
    }
    isSigningIn = false;
    notifyListeners();
  }

  Future<void> signOut() async {
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
    user = null;
    notifyListeners();
  }
}

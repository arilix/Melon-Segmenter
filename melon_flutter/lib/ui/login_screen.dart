import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../store/auth_manager.dart';
import '../theme.dart';

class LoginScreen extends StatelessWidget {
  final VoidCallback onSkip;
  const LoginScreen({super.key, required this.onSkip});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthManager>();
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const MelonHeader(),
                const SizedBox(height: 32),
                Text(
                  'Sign in with Google so results can be saved to your own Google Drive.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 15),
                ),
                const SizedBox(height: 24),
                if (auth.isSigningIn)
                  const CircularProgressIndicator(color: MelonTheme.accentTeal)
                else
                  PrimaryButton(label: 'Sign in with Google', icon: Icons.login, onPressed: auth.signIn),
                if (auth.errorMessage != null) ...[
                  const SizedBox(height: 16),
                  Text(auth.errorMessage!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.orangeAccent)),
                ],
                const SizedBox(height: 12),
                TextButton(onPressed: onSkip, child: const Text('Continue without signing in')),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

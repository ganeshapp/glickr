import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/auth_provider.dart';
import '../../../core/providers/config_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../albums/presentation/albums_screen.dart';
import '../../config/presentation/repo_setup_screen.dart';
import 'login_screen.dart';

/// The app's only routing decision that isn't a push: splash while the stored
/// token is checked, then login, then - once signed in - repo setup or the
/// albums grid.
///
/// Swapping the home widget on state rather than pushing routes is what makes
/// a session dying mid-use survivable: [AuthNotifier.onSessionExpired] fires
/// from any screen, and the user lands back on login with no route stack left
/// pointing at data they can no longer fetch.
class AuthWrapper extends ConsumerWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authNotifierProvider);

    return switch (authState) {
      AuthInitial() || AuthLoading() => const _SplashScreen(),
      AuthUnauthenticated() => const LoginScreen(),
      // An offline launch with a stored token counts as signed in: albums
      // render from the Hive cache, so no network means read-only rather than
      // a locked door.
      AuthAuthenticated() || AuthOfflineAuthenticated() => _signedIn(ref),
    };
  }

  Widget _signedIn(WidgetRef ref) {
    // The config box is opened in main() before runApp, so this read is
    // synchronous - there is no loading state to render between "signed in"
    // and "we know whether a repo is configured".
    final config = ref.watch(configNotifierProvider);
    if (config == null) return const RepoSetupScreen(isOnboarding: true);
    return const AlbumsScreen();
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;

    return Scaffold(
      body: Container(
        decoration: AppTheme.backgroundGradient(context),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset('assets/brand/glickr_mark.png', width: 96),
              const SizedBox(height: 18),
              Text(
                'glickr',
                style: AppTheme.mono(
                  context,
                  size: 30,
                  weight: FontWeight.w700,
                  letterSpacing: -1.5,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 32),
              // A hairline bar, not a spinner: validating a stored token is
              // usually sub-second, and a full spinner on a launch screen
              // reads as "something has gone wrong" rather than "one moment".
              SizedBox(
                width: 88,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    minHeight: 3,
                    backgroundColor: scheme.onSurface.withValues(alpha: 0.08),
                    semanticsLabel: 'Checking your GitHub session',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

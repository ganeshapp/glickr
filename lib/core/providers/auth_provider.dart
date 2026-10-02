import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../models/github_user.dart';
import '../services/auth_service.dart';
import '../services/dio_client.dart';
import '../services/github_oauth_service.dart';
import '../services/secure_storage_service.dart';

part 'auth_provider.g.dart';

/// Provider for SecureStorageService
@riverpod
SecureStorageService secureStorage(Ref ref) {
  return SecureStorageService();
}

/// How the current session was established ([AuthMethods.pat],
/// [AuthMethods.device], or null when logged out). Re-read on every auth
/// state change.
@riverpod
Future<String?> authMethod(Ref ref) {
  ref.watch(authNotifierProvider);
  return ref.watch(secureStorageProvider).getAuthMethod();
}

/// Provider for AuthService
@riverpod
AuthService authService(Ref ref) {
  final secureStorage = ref.watch(secureStorageProvider);
  return AuthService(
    secureStorage: secureStorage,
    dio: ref.watch(apiClientProvider).dio,
  );
}

/// State for authentication
sealed class AuthState {
  const AuthState();
}

class AuthInitial extends AuthState {
  const AuthInitial();
}

class AuthLoading extends AuthState {
  const AuthLoading();
}

class AuthAuthenticated extends AuthState {
  final GitHubUser user;
  const AuthAuthenticated(this.user);
}

/// A stored token exists but GitHub is unreachable (offline launch,
/// flaky network, GitHub outage). The user proceeds with cached data.
class AuthOfflineAuthenticated extends AuthState {
  const AuthOfflineAuthenticated();
}

class AuthUnauthenticated extends AuthState {
  final String? message;
  const AuthUnauthenticated([this.message]);
}

/// Notifier for managing auth state
@riverpod
class AuthNotifier extends _$AuthNotifier {
  @override
  AuthState build() {
    // Wire the shared client's 401 handler so a token revoked mid-session
    // transitions back to the login screen. The auth-validation calls set
    // ApiClient.skipUnauthorizedHandler, so this never fires recursively.
    final apiClient = ref.watch(apiClientProvider);
    apiClient.onUnauthorized = onSessionExpired;
    ref.onDispose(() {
      if (apiClient.onUnauthorized == onSessionExpired) {
        apiClient.onUnauthorized = null;
      }
    });

    // Check for existing auth on startup. Scheduled as a microtask so the
    // state writes aren't clobbered by build()'s own return value.
    Future.microtask(() async {
      try {
        await _checkExistingAuth();
      } catch (_) {
        // Provider was disposed before the check completed
      }
    });
    return const AuthLoading();
  }

  Future<void> _checkExistingAuth() async {
    final authService = ref.read(authServiceProvider);
    final result = await authService.checkExistingAuth();

    state = switch (result) {
      AuthSuccess(user: final user) => AuthAuthenticated(user),
      // Stored token but GitHub unreachable: stay in, use cached data
      AuthOffline() => const AuthOfflineAuthenticated(),
      AuthSignedOut() => const AuthUnauthenticated(),
      // A keychain that would not open, a revoked token: the sign-in screen
      // says why it is back
      AuthFailure(message: final message) => AuthUnauthenticated(message),
    };
  }

  Future<bool> login(String token) async {
    state = const AuthLoading();
    final authService = ref.read(authServiceProvider);
    return _applyResult(await authService.validateToken(token));
  }

  /// Finish a device-flow sign-in: validate the freshly issued token via
  /// GET /user and persist the full token set (method, refresh, expiry).
  Future<bool> completeDeviceLogin({
    required OAuthTokens tokens,
    required String clientId,
  }) async {
    state = const AuthLoading();
    final authService = ref.read(authServiceProvider);
    return _applyResult(await authService.completeDeviceLogin(
      tokens: tokens,
      clientId: clientId,
    ));
  }

  bool _applyResult(AuthResult result) {
    switch (result) {
      case AuthSuccess(user: final user):
        state = AuthAuthenticated(user);
        return true;
      // validateToken never returns these two; the switch has to be whole
      case AuthOffline():
        state = const AuthUnauthenticated('No internet connection');
        return false;
      case AuthSignedOut():
        state = const AuthUnauthenticated();
        return false;
      case AuthFailure(message: final message):
        state = AuthUnauthenticated(message);
        return false;
    }
  }

  Future<void> logout() async {
    final authService = ref.read(authServiceProvider);
    await authService.logout();
    state = const AuthUnauthenticated();
  }

  /// Called by the ApiClient when GitHub returns 401 mid-session (the
  /// token was revoked or expired). Transitions to the login screen with
  /// an explanatory message and clears the dead token.
  Future<void> onSessionExpired() async {
    // Already logged out or mid-login (login handles its own 401)
    if (state is AuthUnauthenticated || state is AuthLoading) return;

    state = const AuthUnauthenticated('Session expired - sign in again');
    final authService = ref.read(authServiceProvider);
    await authService.logout();
  }
}

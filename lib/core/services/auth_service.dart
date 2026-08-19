import 'dart:io';

import 'package:dio/dio.dart';
import '../models/github_user.dart';
import 'dio_client.dart';
import 'github_oauth_service.dart';
import 'secure_storage_service.dart';

/// Result of a token validation attempt
sealed class AuthResult {
  const AuthResult();
}

class AuthSuccess extends AuthResult {
  final GitHubUser user;
  const AuthSuccess(this.user);
}

class AuthFailure extends AuthResult {
  final String message;
  const AuthFailure(this.message);
}

/// A stored token exists but GitHub could not be reached to validate it.
/// The user should stay authenticated and work against cached data.
class AuthOffline extends AuthResult {
  const AuthOffline();
}

/// Service for handling GitHub authentication
class AuthService {
  final SecureStorageService _secureStorage;
  final Dio _dio;

  AuthService({
    required SecureStorageService secureStorage,
    required Dio dio,
  })  : _secureStorage = secureStorage,
        _dio = dio;

  /// Validate a GitHub Personal Access Token
  /// Returns AuthSuccess with user info if valid, AuthFailure otherwise
  Future<AuthResult> validateToken(String token) async {
    if (token.trim().isEmpty) {
      return const AuthFailure('Token cannot be empty');
    }

    try {
      final response = await _dio.get(
        '/user',
        options: Options(
          headers: {
            // Explicit candidate token: the shared client must not
            // substitute the stored one
            'Authorization': 'Bearer ${token.trim()}',
          },
          // A 401 here is a bad login attempt, not a revoked session
          extra: {ApiClient.skipUnauthorizedHandler: true},
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        final user = GitHubUser.fromJson(response.data);
        // Save token on successful validation
        await _secureStorage.saveToken(token.trim());
        await _secureStorage.saveAuthMethod(AuthMethods.pat);
        return AuthSuccess(user);
      } else {
        return const AuthFailure('Invalid response from GitHub');
      }
    } on DioException catch (e) {
      return _handleDioError(e);
    } catch (e) {
      return AuthFailure('Unexpected error: ${e.toString()}');
    }
  }

  /// Validate and persist a device-flow token set ([tokens] from
  /// [GitHubOAuthService.pollForToken]). On success the session is marked
  /// as [AuthMethods.device] and [clientId] is remembered so the ApiClient
  /// can auto-refresh and re-login stays one tap.
  Future<AuthResult> completeDeviceLogin({
    required OAuthTokens tokens,
    required String clientId,
  }) async {
    final result = await validateToken(tokens.accessToken);
    if (result is AuthSuccess) {
      await _secureStorage.saveClientId(clientId);
      await _secureStorage.saveDeviceFlowTokens(
        accessToken: tokens.accessToken.trim(),
        refreshToken: tokens.refreshToken,
        accessTokenExpiry: tokens.expiresInSeconds != null
            ? DateTime.now().add(Duration(seconds: tokens.expiresInSeconds!))
            : null,
      );
    }
    return result;
  }

  /// Check if user is already authenticated
  ///
  /// Unlike [validateToken], a network/connection failure here does NOT
  /// invalidate the session: the stored token is trusted and [AuthOffline]
  /// is returned so the app can proceed with cached data. Only a real 401
  /// response (revoked/expired token) or a missing token returns
  /// [AuthFailure].
  Future<AuthResult> checkExistingAuth() async {
    if (!await _secureStorage.hasToken()) {
      return const AuthFailure('No token stored');
    }

    try {
      final response = await _dio.get(
        '/user',
        options: Options(
          // This call's 401 is handled right here - firing the client's
          // onUnauthorized callback too would loop back into auth state
          extra: {ApiClient.skipUnauthorizedHandler: true},
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        return AuthSuccess(GitHubUser.fromJson(response.data));
      }
      // Unexpected but non-401 response: keep the session, work offline
      return const AuthOffline();
    } on DioException catch (e) {
      // Only a definitive 401 means the token was revoked or expired
      if (e.type == DioExceptionType.badResponse &&
          e.response?.statusCode == 401) {
        return const AuthFailure('Invalid or expired token');
      }
      // Network/connection errors (airplane mode, flaky data, GitHub
      // outage, rate limiting) with a stored token: stay authenticated
      if (_isNetworkError(e)) {
        return const AuthOffline();
      }
      // Other transient errors (403 rate limit, 5xx, cancel): don't log
      // the user out over them either
      return const AuthOffline();
    } catch (e) {
      return AuthFailure('Unexpected error: ${e.toString()}');
    }
  }

  /// True when the error indicates the network/GitHub was unreachable
  bool _isNetworkError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return true;
      case DioExceptionType.unknown:
        return e.error is SocketException;
      default:
        return false;
    }
  }

  /// Logout - clear stored token
  Future<void> logout() async {
    await _secureStorage.deleteToken();
  }

  AuthFailure _handleDioError(DioException e) {
    // Rate limiting must never read as a broken token
    if (ApiClient.isRateLimit(e)) {
      return AuthFailure(ApiClient.friendlyError(e));
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return const AuthFailure('Connection timed out. Please check your internet.');
      case DioExceptionType.badResponse:
        final statusCode = e.response?.statusCode;
        if (statusCode == 401) {
          return const AuthFailure('Invalid or expired token');
        } else if (statusCode == 403) {
          return const AuthFailure('Token lacks required permissions');
        } else if (statusCode == 404) {
          return const AuthFailure('GitHub API not reachable');
        }
        return AuthFailure('GitHub error: $statusCode');
      case DioExceptionType.connectionError:
        return const AuthFailure('No internet connection');
      case DioExceptionType.cancel:
        return const AuthFailure('Request cancelled');
      default:
        return AuthFailure('Network error: ${e.message}');
    }
  }
}

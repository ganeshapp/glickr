import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../providers/auth_provider.dart';
import 'github_oauth_service.dart';
import 'secure_storage_service.dart';

part 'dio_client.g.dart';

/// Single source of truth for authenticated GitHub API access.
/// keepAlive: one Dio instance (and its 401 callback wiring) for the
/// whole app lifetime.
@Riverpod(keepAlive: true)
ApiClient apiClient(Ref ref) {
  return ApiClient(
    secureStorage: ref.watch(secureStorageProvider),
    oauthService: ref.watch(gitHubOAuthServiceProvider),
  );
}

/// Marker error attached to DioExceptions the [ApiClient] identified as
/// GitHub rate limiting (403/429 with X-RateLimit-Remaining: 0 or
/// Retry-After). [toString] is the user-facing message.
///
/// [isPrimary] separates the two limits, which need different handling and
/// different copy. The primary limit (5,000 requests/hour, signalled by
/// `x-ratelimit-remaining: 0`) has a known reset time, so the upload queue
/// parks until then and tells the user when it will resume. A secondary limit
/// - 403/429 with neither header - is GitHub throttling burst writes and has
/// no published reset, so the only correct response is exponential backoff.
/// Treating the two the same either burns retries against a wall for an hour
/// or gives up on a throttle that would have cleared in a minute.
class GitHubRateLimitException implements Exception {
  final String message;

  /// True for the documented hourly quota, false for a burst/secondary limit.
  final bool isPrimary;

  /// When the primary quota resets, if GitHub said. Null for secondary.
  final DateTime? resetAt;

  const GitHubRateLimitException(
    this.message, {
    this.isPrimary = true,
    this.resetAt,
  });

  @override
  String toString() => message;
}

/// Exception whose [toString] is exactly the user-facing message, so
/// upstream catch-alls that display e.toString() surface it verbatim.
class ApiException implements Exception {
  final String message;
  const ApiException(this.message);

  @override
  String toString() => message;
}

/// The single authenticated GitHub API client shared by every service.
///
/// - Injects `Authorization: Bearer <token>` per request from
///   [SecureStorageService] (skipped when no token is stored, and never
///   overwrites an explicitly provided header - login validates a
///   candidate token before it is stored).
/// - Converts rate-limit responses into DioExceptions carrying a clear
///   'GitHub rate limit exceeded - try again in Xm' message.
/// - Reports 401s from api.github.com through [onUnauthorized] so the
///   auth layer can log the user out when a token is revoked mid-session.
class ApiClient {
  /// Request-options extra key: set true on auth-validation calls so a
  /// 401 there does not fire [onUnauthorized] (avoids logout loops).
  static const skipUnauthorizedHandler = 'skipUnauthorizedHandler';

  /// Refresh a device-flow access token this long before it expires
  static const refreshLeeway = Duration(minutes: 5);

  final SecureStorageService _secureStorage;

  /// Refreshes device-flow tokens; null disables auto-refresh (tests)
  final GitHubOAuthService? _oauthService;

  /// Single-flight guard: the refresh currently in progress, if any
  Future<void>? _refreshInFlight;

  /// Called when api.github.com returns 401 mid-session (token revoked
  /// or expired), or when a device-flow refresh is definitively denied.
  /// Wired by AuthNotifier.
  void Function()? onUnauthorized;

  late final Dio dio;

  ApiClient({
    required SecureStorageService secureStorage,
    GitHubOAuthService? oauthService,
  }) : _secureStorage = secureStorage,
       _oauthService = oauthService {
    dio = Dio(
      BaseOptions(
        baseUrl: 'https://api.github.com',
        connectTimeout: const Duration(seconds: 30),
        // Blob uploads are the long pole: an 18 MB video inflates to ~24 MB of
        // base64, which is well over three minutes on a slow mobile uplink
        // before GitHub even starts processing it. 60s - the usual default -
        // fails those on any connection worse than office wifi.
        sendTimeout: const Duration(minutes: 5),
        receiveTimeout: const Duration(seconds: 90),
        headers: {
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
          'User-Agent': 'glickr',
        },
      ),
    );

    // GitHub asks for a User-Agent that identifies the app. The version
    // arrives from the platform a moment later; the first request or two may
    // go out as plain 'glickr'.
    unawaited(
      PackageInfo.fromPlatform().then(
        (info) => dio.options.headers['User-Agent'] = 'glickr/${info.version}',
        onError: (_) {},
      ),
    );

    dio.interceptors.add(
      InterceptorsWrapper(onRequest: _onRequest, onError: _onError),
    );

    // Debug-only logging; requestHeader stays false so the
    // Authorization header (the token) never reaches device logs
    if (kDebugMode) {
      dio.interceptors.add(
        LogInterceptor(
          requestHeader: false,
          requestBody: false,
          responseHeader: false,
          responseBody: false,
          error: true,
        ),
      );
    }
  }

  /// Authorization headers for requests made outside [dio], e.g.
  /// Image.network on raw.githubusercontent.com for private repos.
  /// Null when no token is stored.
  Future<Map<String, String>?> authHeaders() async {
    await _maybeRefreshDeviceToken();
    final token = await _secureStorage.getToken();
    if (token == null || token.isEmpty) return null;
    return {'Authorization': 'Bearer ${token.trim()}'};
  }

  /// True when [e] was flagged as GitHub rate limiting by the interceptor
  static bool isRateLimit(DioException e) =>
      e.error is GitHubRateLimitException;

  /// Map a DioException to a user-facing message. Rate-limit errors
  /// produced by the interceptor are surfaced verbatim.
  static String friendlyError(DioException e) {
    final error = e.error;
    if (error is GitHubRateLimitException) return error.message;

    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'Connection timed out. Please check your internet.';
      case DioExceptionType.badResponse:
        final statusCode = e.response?.statusCode;
        if (statusCode == 401) {
          return 'Authentication failed - sign in again';
        }
        final ghMessage = _gitHubMessage(e);
        return ghMessage.isNotEmpty
            ? 'GitHub error ($statusCode): $ghMessage'
            : 'GitHub error ($statusCode)';
      case DioExceptionType.connectionError:
        return 'No internet connection';
      case DioExceptionType.cancel:
        return 'Request cancelled';
      default:
        return 'Network error: ${e.message}';
    }
  }

  /// Safely extract GitHub's error message from a Dio error response
  static String _gitHubMessage(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['message'] is String) {
      return data['message'] as String;
    }
    return '';
  }

  Future<void> _onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    // Respect an explicitly provided Authorization header
    if (!options.headers.containsKey('Authorization')) {
      // Device-flow tokens expire (~8h): refresh just-in-time
      await _maybeRefreshDeviceToken();
      // Cheap per-request read; the storage plugin memory-caches values
      final token = await _secureStorage.getToken();
      if (token != null && token.isNotEmpty) {
        options.headers['Authorization'] = 'Bearer ${token.trim()}';
      }
    }
    handler.next(options);
  }

  /// Refresh the stored device-flow access token when it expires within
  /// [refreshLeeway]. Single-flight: concurrent requests share one
  /// refresh (refresh tokens are single-use). Never throws - a failed
  /// refresh lets the request proceed with the current token.
  Future<void> _maybeRefreshDeviceToken() async {
    final oauthService = _oauthService;
    if (oauthService == null) return;
    try {
      if (await _secureStorage.getAuthMethod() != AuthMethods.device) return;
      final expiry = await _secureStorage.getAccessTokenExpiry();
      // No expiry = OAuth-App token, which never expires
      if (expiry == null) return;
      if (DateTime.now().add(refreshLeeway).isBefore(expiry)) return;

      final inFlight = _refreshInFlight;
      if (inFlight != null) return inFlight;

      final refresh = _refreshDeviceToken(oauthService);
      _refreshInFlight = refresh;
      try {
        await refresh;
      } finally {
        _refreshInFlight = null;
      }
    } catch (_) {
      // Refresh bookkeeping must never block the actual request
    }
  }

  Future<void> _refreshDeviceToken(GitHubOAuthService oauthService) async {
    final refreshToken = await _secureStorage.getRefreshToken();
    final clientId = await _secureStorage.getClientId();
    if (refreshToken == null ||
        refreshToken.isEmpty ||
        clientId == null ||
        clientId.isEmpty) {
      // Nothing to refresh with; the request will 401 into the logout path
      return;
    }
    try {
      final tokens = await oauthService.refreshAccessToken(
        clientId: clientId,
        refreshToken: refreshToken,
      );
      await _secureStorage.saveDeviceFlowTokens(
        accessToken: tokens.accessToken,
        // GitHub always rotates, but never burn the old one on a
        // response that omits it
        refreshToken: tokens.refreshToken ?? refreshToken,
        accessTokenExpiry:
            tokens.expiresInSeconds != null
                ? DateTime.now().add(
                  Duration(seconds: tokens.expiresInSeconds!),
                )
                : null,
      );
    } on OAuthRefreshDenied {
      // The session is definitively dead: same path as a mid-session 401
      onUnauthorized?.call();
    } on DioException {
      // Transient (offline, GitHub down): keep the current token; the
      // request itself will surface the error
    }
  }

  void _onError(DioException e, ErrorInterceptorHandler handler) {
    final rateLimit = _classifyRateLimit(e.response);
    if (rateLimit != null) {
      handler.reject(
        DioException(
          requestOptions: e.requestOptions,
          response: e.response,
          type: DioExceptionType.badResponse,
          error: rateLimit,
          message: rateLimit.message,
        ),
      );
      return;
    }

    // Token revoked/expired mid-session: tell the auth layer, except for
    // the auth-validation calls themselves (they handle 401 directly)
    if (e.response?.statusCode == 401 &&
        e.requestOptions.uri.host == 'api.github.com' &&
        e.requestOptions.extra[skipUnauthorizedHandler] != true) {
      onUnauthorized?.call();
    }

    handler.next(e);
  }

  /// Non-null when [response] is a GitHub rate-limit rejection.
  ///
  /// A 403/429 is only a rate limit when GitHub says so via a header - a plain
  /// 403 is a permissions problem and must keep reading as one, or every
  /// "your token can't write here" turns into a misleading "try again later".
  ///
  /// Secondary limits are the exception: GitHub documents them as 403/429 with
  /// no rate-limit headers at all, so a write request that comes back 403 with
  /// neither `x-ratelimit-remaining` nor `retry-after`, and whose body says as
  /// much, is classified as a burst throttle.
  static GitHubRateLimitException? _classifyRateLimit(
    Response<dynamic>? response,
  ) {
    if (response == null) return null;
    final statusCode = response.statusCode;
    if (statusCode != 403 && statusCode != 429) return null;

    final remaining = response.headers.value('x-ratelimit-remaining');
    final retryAfter = response.headers.value('retry-after');

    if (remaining == '0' || retryAfter != null) {
      final resetAt = _resetTime(response);
      return GitHubRateLimitException(
        'GitHub rate limit reached - retrying in ${_waitMinutes(response)}m',
        isPrimary: true,
        resetAt: resetAt,
      );
    }

    // No headers: only a secondary limit if GitHub's message says so,
    // otherwise this is an ordinary permission denial.
    final data = response.data;
    final body =
        (data is Map && data['message'] is String)
            ? (data['message'] as String).toLowerCase()
            : '';
    if (body.contains('secondary rate limit') ||
        body.contains('exceeded a secondary')) {
      return const GitHubRateLimitException(
        'GitHub is throttling uploads - slowing down and retrying',
        isPrimary: false,
      );
    }
    return null;
  }

  /// When the primary quota resets, from Retry-After or X-RateLimit-Reset.
  static DateTime? _resetTime(Response<dynamic> response) {
    final retrySeconds = int.tryParse(
      response.headers.value('retry-after') ?? '',
    );
    if (retrySeconds != null) {
      return DateTime.now().add(Duration(seconds: retrySeconds));
    }
    final resetEpoch = int.tryParse(
      response.headers.value('x-ratelimit-reset') ?? '',
    );
    if (resetEpoch != null) {
      return DateTime.fromMillisecondsSinceEpoch(resetEpoch * 1000);
    }
    return null;
  }

  /// Minutes (>= 1, rounded up) until the rate limit resets, from
  /// Retry-After (seconds) or X-RateLimit-Reset (epoch seconds)
  static int _waitMinutes(Response<dynamic> response) {
    final retrySeconds = int.tryParse(
      response.headers.value('retry-after') ?? '',
    );
    if (retrySeconds != null) {
      return _ceilMinutes(Duration(seconds: retrySeconds));
    }
    final resetEpoch = int.tryParse(
      response.headers.value('x-ratelimit-reset') ?? '',
    );
    if (resetEpoch != null) {
      final reset = DateTime.fromMillisecondsSinceEpoch(resetEpoch * 1000);
      return _ceilMinutes(reset.difference(DateTime.now()));
    }
    // Limited, but no reset information: suggest the shortest retry
    return 1;
  }

  static int _ceilMinutes(Duration wait) {
    if (wait.inSeconds <= 60) return 1;
    return (wait.inSeconds / 60).ceil();
  }
}

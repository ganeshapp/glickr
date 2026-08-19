import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'dio_client.dart';

part 'github_oauth_service.g.dart';

/// One service instance (and its github.com Dio) for the app lifetime.
@Riverpod(keepAlive: true)
GitHubOAuthService gitHubOAuthService(Ref ref) {
  return GitHubOAuthService();
}

/// Response of POST /login/device/code: the code the user types at
/// github.com/login/device plus polling parameters.
class DeviceCodeResponse {
  final String deviceCode;
  final String userCode;
  final String verificationUri;

  /// Seconds until [deviceCode] expires
  final int expiresIn;

  /// Minimum seconds between polls
  final int interval;

  const DeviceCodeResponse({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
  });

  factory DeviceCodeResponse.fromJson(Map<dynamic, dynamic> json) {
    return DeviceCodeResponse(
      deviceCode: json['device_code'] as String,
      userCode: json['user_code'] as String,
      verificationUri:
          json['verification_uri'] as String? ?? 'https://github.com/login/device',
      expiresIn: _asInt(json['expires_in']) ?? 900,
      interval: _asInt(json['interval']) ?? 5,
    );
  }
}

/// Tokens returned by a successful device-flow authorization or refresh.
///
/// GitHub Apps issue expiring `ghu_` access tokens plus single-use `ghr_`
/// refresh tokens; OAuth Apps issue a non-expiring access token with
/// [refreshToken] and [expiresInSeconds] both null.
class OAuthTokens {
  final String accessToken;
  final String? refreshToken;

  /// Access-token lifetime in seconds; null = never expires (OAuth App)
  final int? expiresInSeconds;

  const OAuthTokens({
    required this.accessToken,
    this.refreshToken,
    this.expiresInSeconds,
  });

  factory OAuthTokens.fromJson(Map<dynamic, dynamic> json) {
    return OAuthTokens(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String?,
      expiresInSeconds: _asInt(json['expires_in']),
    );
  }
}

/// Outcome of polling for the device-flow token
sealed class DeviceFlowResult {
  const DeviceFlowResult();
}

class DeviceFlowSuccess extends DeviceFlowResult {
  final OAuthTokens tokens;
  const DeviceFlowSuccess(this.tokens);
}

/// The user code expired before the user authorized the app
class DeviceFlowExpired extends DeviceFlowResult {
  const DeviceFlowExpired();
  String get message => 'The code expired - start over to get a new one';
}

/// The user pressed "Cancel" on github.com
class DeviceFlowDenied extends DeviceFlowResult {
  const DeviceFlowDenied();
  String get message => 'Authorization was denied on GitHub';
}

/// Device Flow is not enabled for this client id
class DeviceFlowDisabled extends DeviceFlowResult {
  const DeviceFlowDisabled();
  String get message =>
      'Device Flow is disabled for this Client ID - enable it in the '
      'app settings on GitHub';
}

/// Polling was cancelled locally (user dismissed the sign-in sheet)
class DeviceFlowCancelled extends DeviceFlowResult {
  const DeviceFlowCancelled();
}

/// Any other terminal error (network failure, unknown OAuth error)
class DeviceFlowFailure extends DeviceFlowResult {
  final String message;
  const DeviceFlowFailure(this.message);
}

/// GitHub definitively rejected the refresh token (revoked, already used,
/// or expired). Unlike a network error, this means the session is dead.
class OAuthRefreshDenied implements Exception {
  final String message;
  const OAuthRefreshDenied(this.message);

  @override
  String toString() => message;
}

/// GitHub OAuth 2.0 Device Flow against https://github.com (NOT
/// api.github.com - these endpoints live on the web host and are the only
/// GitHub auth flow that needs no client secret in the app).
///
/// Works for both classic OAuth Apps (what the app bundles: scope-based
/// access, non-expiring token, no refresh) and GitHub Apps (fine-grained
/// Contents permission, expiring tokens + secret-less refresh), which a
/// fork can select with `--dart-define=GITHUB_CLIENT_ID`.
class GitHubOAuthService {
  static const _deviceCodePath = '/login/device/code';
  static const _accessTokenPath = '/login/oauth/access_token';
  static const grantTypeDeviceCode =
      'urn:ietf:params:oauth:grant-type:device_code';
  static const grantTypeRefreshToken = 'refresh_token';

  final Dio _dio;

  GitHubOAuthService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: 'https://github.com',
              connectTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(seconds: 30),
            ));

  /// Both endpoints return JSON only when asked, and expect form bodies
  Options get _formOptions => Options(
        contentType: Headers.formUrlEncodedContentType,
        headers: {'Accept': 'application/json'},
      );

  /// Step 1: request a device + user code pair for [clientId].
  ///
  /// [scope] is required for OAuth Apps (a token issued without it can read
  /// nothing); GitHub Apps ignore it and take their permissions from the app
  /// registration, so it is omitted when empty.
  ///
  /// Throws [ApiException] with a user-facing message on failure.
  Future<DeviceCodeResponse> startDeviceFlow(
    String clientId, {
    String scope = '',
  }) async {
    try {
      final response = await _dio.post(
        _deviceCodePath,
        data: {
          'client_id': clientId,
          if (scope.isNotEmpty) 'scope': scope,
        },
        options: _formOptions,
      );
      final data = response.data;
      if (data is Map && data['device_code'] is String) {
        return DeviceCodeResponse.fromJson(data);
      }
      throw ApiException(
          _oauthErrorMessage(data) ?? 'Unexpected response from GitHub');
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        // github.com 404s the endpoint for unknown client ids
        throw const ApiException(
            'GitHub does not recognize this Client ID - check it and try again');
      }
      final message = _oauthErrorMessage(e.response?.data);
      throw ApiException(message ?? ApiClient.friendlyError(e));
    }
  }

  /// Step 2: poll for the access token while the user authorizes on
  /// github.com. Waits [interval] seconds between polls (plus 5s whenever
  /// GitHub answers `slow_down`) and gives up after [expiresIn] seconds.
  ///
  /// [isCancelled] is checked around every wait/poll so a UI cancel button
  /// stops the loop. [wait] is injectable for tests (defaults to a real
  /// delay).
  Future<DeviceFlowResult> pollForToken({
    required String clientId,
    required String deviceCode,
    required int interval,
    required int expiresIn,
    bool Function()? isCancelled,
    Future<void> Function(Duration delay)? wait,
  }) async {
    final doWait = wait ?? (delay) => Future<void>.delayed(delay);
    var pollInterval = interval < 1 ? 1 : interval;
    var remainingSeconds = expiresIn;

    while (true) {
      if (isCancelled?.call() ?? false) return const DeviceFlowCancelled();
      if (remainingSeconds <= 0) return const DeviceFlowExpired();

      // GitHub asks clients to wait the interval BEFORE the first poll too
      await doWait(Duration(seconds: pollInterval));
      remainingSeconds -= pollInterval;
      if (isCancelled?.call() ?? false) return const DeviceFlowCancelled();

      final Map<dynamic, dynamic> body;
      try {
        final response = await _dio.post(
          _accessTokenPath,
          data: {
            'client_id': clientId,
            'device_code': deviceCode,
            'grant_type': grantTypeDeviceCode,
          },
          options: _formOptions,
        );
        body = response.data is Map ? response.data as Map : const {};
      } on DioException catch (e) {
        return DeviceFlowFailure(
            _oauthErrorMessage(e.response?.data) ?? ApiClient.friendlyError(e));
      }

      if (body['access_token'] is String) {
        return DeviceFlowSuccess(OAuthTokens.fromJson(body));
      }

      switch (body['error']) {
        case 'authorization_pending':
          continue;
        case 'slow_down':
          pollInterval += 5;
          continue;
        case 'expired_token':
          return const DeviceFlowExpired();
        case 'access_denied':
          return const DeviceFlowDenied();
        case 'device_flow_disabled':
          return const DeviceFlowDisabled();
        default:
          return DeviceFlowFailure(
              _oauthErrorMessage(body) ?? 'Unexpected response from GitHub');
      }
    }
  }

  /// Exchange a single-use device-flow refresh token for a new
  /// access + refresh pair. Secret-less refresh works ONLY for tokens a
  /// GitHub App issued through the device flow.
  ///
  /// Throws [OAuthRefreshDenied] when GitHub rejects the refresh token
  /// (session is dead); network failures propagate as [DioException]
  /// (session may still be fine).
  Future<OAuthTokens> refreshAccessToken({
    required String clientId,
    required String refreshToken,
  }) async {
    final Map<dynamic, dynamic> body;
    try {
      final response = await _dio.post(
        _accessTokenPath,
        data: {
          'client_id': clientId,
          'grant_type': grantTypeRefreshToken,
          'refresh_token': refreshToken,
        },
        options: _formOptions,
      );
      body = response.data is Map ? response.data as Map : const {};
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final message = _oauthErrorMessage(e.response?.data);
      // A definitive 4xx OAuth error means the refresh token is dead;
      // anything else (5xx, timeouts, offline) is transient
      if (message != null && status != null && status >= 400 && status < 500) {
        throw OAuthRefreshDenied(message);
      }
      rethrow;
    }

    if (body['access_token'] is String) {
      return OAuthTokens.fromJson(body);
    }
    throw OAuthRefreshDenied(
        _oauthErrorMessage(body) ?? 'GitHub rejected the session refresh');
  }

  /// User-facing message for an OAuth error body, or null when [data]
  /// carries no error
  static String? _oauthErrorMessage(dynamic data) {
    if (data is! Map || data['error'] == null) return null;
    final description = data['error_description'];
    if (description is String && description.isNotEmpty) return description;
    return 'GitHub sign-in failed (${data['error']})';
  }
}

int? _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// How the stored access token was obtained
abstract final class AuthMethods {
  /// Personal Access Token pasted by the user
  static const pat = 'pat';

  /// GitHub Device Flow (GitHub App or OAuth App)
  static const device = 'device';
}

/// Service for securely storing sensitive data: the GitHub access token
/// (PAT or device-flow token) plus the device-flow session fields.
class SecureStorageService {
  static const _tokenKey = 'github_pat';
  static const _authMethodKey = 'auth_method';
  static const _clientIdKey = 'oauth_client_id';
  static const _refreshTokenKey = 'refresh_token';
  static const _expiryKey = 'access_token_expiry';

  final FlutterSecureStorage _storage;

  SecureStorageService() : _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
    // The default data-protection keychain needs an entitlement an ad-hoc
    // signed build cannot have (-34018); the login keychain needs none.
    // accountName is the keychain service name. Without it every
    // flutter_secure_storage app shares one, so glickr would try to read
    // JekyllPress's github_pat item and macOS would demand the login keychain
    // password for it.
    mOptions: MacOsOptions(
      useDataProtectionKeyChain: false,
      accountName: 'com.glickr.glickr',
    ),
  );

  /// Save the GitHub access token (PAT or device-flow access token)
  Future<void> saveToken(String token) async {
    await _storage.write(key: _tokenKey, value: token);
  }

  /// Retrieve the stored GitHub access token
  Future<String?> getToken() async {
    return await _storage.read(key: _tokenKey);
  }

  /// Delete all session data (logout). The OAuth client id survives so
  /// signing back in stays one tap.
  Future<void> deleteToken() async {
    await _storage.delete(key: _refreshTokenKey);
    await _storage.delete(key: _expiryKey);
    await _storage.delete(key: _authMethodKey);
    await _storage.delete(key: _tokenKey);
  }

  /// Check if a token exists
  Future<bool> hasToken() async {
    final token = await getToken();
    return token != null && token.isNotEmpty;
  }

  /// How the current token was obtained: [AuthMethods.pat],
  /// [AuthMethods.device], or null when logged out
  Future<String?> getAuthMethod() async {
    return await _storage.read(key: _authMethodKey);
  }

  Future<void> saveAuthMethod(String method) async {
    await _storage.write(key: _authMethodKey, value: method);
  }

  /// The GitHub App / OAuth App client id used for device-flow sign-in.
  /// Kept across logouts.
  Future<String?> getClientId() async {
    return await _storage.read(key: _clientIdKey);
  }

  Future<void> saveClientId(String clientId) async {
    await _storage.write(key: _clientIdKey, value: clientId);
  }

  /// Single-use device-flow refresh token; null for PAT/OAuth-App sessions
  Future<String?> getRefreshToken() async {
    return await _storage.read(key: _refreshTokenKey);
  }

  Future<void> saveRefreshToken(String? refreshToken) async {
    if (refreshToken == null) {
      await _storage.delete(key: _refreshTokenKey);
    } else {
      await _storage.write(key: _refreshTokenKey, value: refreshToken);
    }
  }

  /// When the device-flow access token expires; null = never (PAT or
  /// OAuth-App token)
  Future<DateTime?> getAccessTokenExpiry() async {
    final iso = await _storage.read(key: _expiryKey);
    if (iso == null) return null;
    return DateTime.tryParse(iso);
  }

  Future<void> saveAccessTokenExpiry(DateTime? expiry) async {
    if (expiry == null) {
      await _storage.delete(key: _expiryKey);
    } else {
      await _storage.write(key: _expiryKey, value: expiry.toIso8601String());
    }
  }

  /// Persist a device-flow token set as one operation.
  ///
  /// Refresh tokens are single-use, so the write ORDER matters if the app
  /// dies mid-update: the new refresh token lands first. Worst case after
  /// a crash is a stale access token + fresh refresh token, which the next
  /// refresh fixes - never a fresh access token whose only refresh token
  /// was already burned.
  Future<void> saveDeviceFlowTokens({
    required String accessToken,
    String? refreshToken,
    DateTime? accessTokenExpiry,
  }) async {
    await saveRefreshToken(refreshToken);
    await saveAccessTokenExpiry(accessTokenExpiry);
    await saveToken(accessToken);
    await saveAuthMethod(AuthMethods.device);
  }
}

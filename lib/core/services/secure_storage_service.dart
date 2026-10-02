import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// How the stored access token was obtained
abstract final class AuthMethods {
  /// Personal Access Token pasted by the user
  static const pat = 'pat';

  /// GitHub Device Flow (GitHub App or OAuth App)
  static const device = 'device';
}

/// The GitHub session - access token (PAT or device flow) plus the device-flow
/// fields - kept as ONE secure-storage item, a JSON object.
///
/// One item rather than one per field because of the macOS login keychain: an
/// ad-hoc signed build has a new code identity every release, so after an
/// update the first read of each item asks the user to allow it. One item,
/// one prompt. It also makes a device-flow token set a single write, so the
/// app dying mid-update can never leave a fresh access token next to a
/// refresh token that was already burned.
class SecureStorageService {
  /// The keychain service name (kSecAttrService). The plugin's default is
  /// shared by every app that uses it, so glickr would read JekyllPress's
  /// item and macOS would demand the login keychain password for it.
  static const serviceName = 'com.glickr.glickr';

  /// The default data-protection keychain needs an entitlement an ad-hoc
  /// signed build cannot have (-34018); the login keychain needs none.
  static const macOsOptions = MacOsOptions(
    useDataProtectionKeyChain: false,
    accountName: serviceName,
  );

  static const _sessionKey = 'session';

  // Fields of the JSON object. They are also the keys 1.1.x stored the same
  // values under, one item each, which is what [_migrate] reads.
  static const _token = 'github_pat';
  static const _authMethod = 'auth_method';
  static const _clientId = 'oauth_client_id';
  static const _refreshToken = 'refresh_token';
  static const _expiry = 'access_token_expiry';
  static const _fields = [
    _token,
    _authMethod,
    _clientId,
    _refreshToken,
    _expiry,
  ];

  final FlutterSecureStorage _storage;

  SecureStorageService({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(encryptedSharedPreferences: true),
            mOptions: macOsOptions,
          );

  /// Save the GitHub access token (PAT or device-flow access token)
  Future<void> saveToken(String token) => _update((s) => s[_token] = token);

  /// Retrieve the stored GitHub access token
  Future<String?> getToken() async => (await _read())[_token];

  /// Delete all session data (logout). The OAuth client id survives so
  /// signing back in stays one tap.
  Future<void> deleteToken() =>
      _update((s) => s.removeWhere((field, _) => field != _clientId));

  /// Check if a token exists
  Future<bool> hasToken() async => (await getToken())?.isNotEmpty ?? false;

  /// How the current token was obtained: [AuthMethods.pat],
  /// [AuthMethods.device], or null when logged out
  Future<String?> getAuthMethod() async => (await _read())[_authMethod];

  Future<void> saveAuthMethod(String method) =>
      _update((s) => s[_authMethod] = method);

  /// The GitHub App / OAuth App client id used for device-flow sign-in.
  /// Kept across logouts.
  Future<String?> getClientId() async => (await _read())[_clientId];

  Future<void> saveClientId(String clientId) =>
      _update((s) => s[_clientId] = clientId);

  /// Single-use device-flow refresh token; null for PAT/OAuth-App sessions
  Future<String?> getRefreshToken() async => (await _read())[_refreshToken];

  Future<void> saveRefreshToken(String? refreshToken) =>
      _update((s) => _set(s, _refreshToken, refreshToken));

  /// When the device-flow access token expires; null = never (PAT or
  /// OAuth-App token)
  Future<DateTime?> getAccessTokenExpiry() async {
    final iso = (await _read())[_expiry];
    return iso == null ? null : DateTime.tryParse(iso);
  }

  Future<void> saveAccessTokenExpiry(DateTime? expiry) =>
      _update((s) => _set(s, _expiry, expiry?.toIso8601String()));

  /// Persist a device-flow token set as one write.
  Future<void> saveDeviceFlowTokens({
    required String accessToken,
    String? refreshToken,
    DateTime? accessTokenExpiry,
  }) => _update((s) {
    _set(s, _refreshToken, refreshToken);
    _set(s, _expiry, accessTokenExpiry?.toIso8601String());
    s[_token] = accessToken;
    s[_authMethod] = AuthMethods.device;
  });

  /// 1.1.0 wrote its items under the plugin's default service name, which it
  /// shares with every other flutter_secure_storage app on the Mac. Delete
  /// those, once. Never read them - the same slot may hold another app's
  /// token, which is how the shared name surfaced - and never deleteAll,
  /// which would take the other apps' items with them.
  static Future<void> deleteSharedServiceItems() async {
    const shared = FlutterSecureStorage(
      mOptions: MacOsOptions(useDataProtectionKeyChain: false),
    );
    for (final field in _fields) {
      try {
        await shared.delete(key: field);
      } catch (_) {
        // The item's ACL may refuse. Once is all this is tried.
      }
    }
  }

  Future<Map<String, String>> _read() async {
    final raw = await _storage.read(key: _sessionKey);
    if (raw == null) return _migrate();
    return Map<String, String>.from(jsonDecode(raw) as Map);
  }

  Future<void> _update(
    void Function(Map<String, String> session) change,
  ) async {
    final session = await _read();
    change(session);
    if (session.isEmpty) {
      await _storage.delete(key: _sessionKey);
    } else {
      await _storage.write(key: _sessionKey, value: jsonEncode(session));
    }
  }

  /// Fold the one-item-per-field layout of 1.1.x into the session item.
  Future<Map<String, String>> _migrate() async {
    final session = <String, String>{};
    for (final field in _fields) {
      final value = await _storage.read(key: field);
      if (value != null) session[field] = value;
    }
    if (session.isEmpty) return session;
    await _storage.write(key: _sessionKey, value: jsonEncode(session));
    for (final field in _fields) {
      await _storage.delete(key: field);
    }
    return session;
  }

  static void _set(Map<String, String> session, String field, String? value) {
    if (value == null) {
      session.remove(field);
    } else {
      session[field] = value;
    }
  }
}

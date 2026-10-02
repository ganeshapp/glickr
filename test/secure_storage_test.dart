import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glickr/core/services/secure_storage_service.dart';

/// The session is one secure-storage item, so a macOS update costs one
/// keychain prompt rather than five, and the 1.1.x item-per-field layout is
/// folded into it on first read.
void main() {
  late Map<String, String> items;
  late SecureStorageService storage;

  setUp(() {
    items = {};
    FlutterSecureStorage.setMockInitialValues(items);
    storage = SecureStorageService();
  });

  Map<String, dynamic> session() => jsonDecode(items['session']!);

  test('the keychain service name is the app id, not the plugin default', () {
    final options = SecureStorageService.macOsOptions.toMap();
    expect(options['accountName'], 'com.glickr.glickr');
    expect(options['accountName'], isNot(AppleOptions.defaultAccountName));
    expect(options['useDataProtectionKeyChain'], 'false');
  });

  test('a device-flow session round-trips through one item', () async {
    final expiry = DateTime.utc(2026, 10, 3, 12);
    await storage.saveClientId('Ov23liABC');
    await storage.saveDeviceFlowTokens(
      accessToken: 'ghu_token',
      refreshToken: 'ghr_refresh',
      accessTokenExpiry: expiry,
    );

    expect(items.keys, ['session']);
    expect(await storage.getToken(), 'ghu_token');
    expect(await storage.getAuthMethod(), AuthMethods.device);
    expect(await storage.getClientId(), 'Ov23liABC');
    expect(await storage.getRefreshToken(), 'ghr_refresh');
    expect(await storage.getAccessTokenExpiry(), expiry);
    expect(await storage.hasToken(), isTrue);
  });

  test('a PAT session has no refresh token or expiry', () async {
    await storage.saveToken('ghp_pat');
    await storage.saveAuthMethod(AuthMethods.pat);

    expect(session(), {'github_pat': 'ghp_pat', 'auth_method': 'pat'});
    expect(await storage.getRefreshToken(), isNull);
    expect(await storage.getAccessTokenExpiry(), isNull);
  });

  test('the five 1.1.x items are folded into the session once', () async {
    items.addAll({
      'github_pat': 'ghu_old',
      'auth_method': 'device',
      'oauth_client_id': 'Ov23liABC',
      'refresh_token': 'ghr_old',
      'access_token_expiry': '2026-10-03T12:00:00.000Z',
    });

    expect(await storage.getToken(), 'ghu_old');

    expect(items.keys, ['session']);
    expect(session(), {
      'github_pat': 'ghu_old',
      'auth_method': 'device',
      'oauth_client_id': 'Ov23liABC',
      'refresh_token': 'ghr_old',
      'access_token_expiry': '2026-10-03T12:00:00.000Z',
    });
    expect(await storage.getRefreshToken(), 'ghr_old');
  });

  test('nothing stored reads as signed out and writes nothing', () async {
    expect(await storage.hasToken(), isFalse);
    expect(await storage.getClientId(), isNull);
    expect(items, isEmpty);
  });

  test('logout clears everything but the client id', () async {
    await storage.saveClientId('Ov23liABC');
    await storage.saveDeviceFlowTokens(
      accessToken: 'ghu_token',
      refreshToken: 'ghr_refresh',
      accessTokenExpiry: DateTime.utc(2026, 10, 3),
    );

    await storage.deleteToken();

    expect(session(), {'oauth_client_id': 'Ov23liABC'});
    expect(await storage.hasToken(), isFalse);
    expect(await storage.getAuthMethod(), isNull);
    expect(await storage.getRefreshToken(), isNull);
    expect(await storage.getAccessTokenExpiry(), isNull);
  });

  test('logging a PAT session out leaves no item at all', () async {
    await storage.saveToken('ghp_pat');
    await storage.saveAuthMethod(AuthMethods.pat);

    await storage.deleteToken();

    expect(items, isEmpty);
  });

  test(
    'the shared-service cleanup deletes the five keys and nothing else',
    () async {
      items.addAll({
        'github_pat': 'another_apps_token',
        'auth_method': 'pat',
        'oauth_client_id': 'x',
        'refresh_token': 'y',
        'access_token_expiry': 'z',
        'someone_elses_key': 'keep',
      });

      await SecureStorageService.deleteSharedServiceItems();

      expect(items, {'someone_elses_key': 'keep'});
    },
  );
}

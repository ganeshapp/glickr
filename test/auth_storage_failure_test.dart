import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glickr/core/providers/auth_provider.dart';
import 'package:glickr/core/services/auth_service.dart';
import 'package:glickr/core/services/secure_storage_service.dart';

/// A keychain that refuses: Linux with no Secret Service daemon, or Deny on
/// the macOS keychain prompt. flutter_secure_storage reports both as a
/// PlatformException.
class _RefusingStorage extends FlutterSecureStoragePlatform {
  Never _refuse() => throw PlatformException(code: 'Libsecret error');

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async => _refuse();
  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async => _refuse();
  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async => _refuse();
  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async => _refuse();
  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async => _refuse();
  @override
  Future<void> deleteAll({required Map<String, String> options}) async =>
      _refuse();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStoragePlatform.instance = _RefusingStorage());

  test(
    'an unreadable keychain at launch is "not signed in", not a throw',
    () async {
      final auth = AuthService(
        secureStorage: SecureStorageService(),
        dio: Dio(),
      );
      expect(await auth.checkExistingAuth(), isA<AuthFailure>());
    },
  );

  test(
    'the launch check lands on the sign-in screen, not the splash',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.listen(authNotifierProvider, (_, _) {});
      expect(container.read(authNotifierProvider), isA<AuthLoading>());

      // The check runs as a microtask off build().
      await Future<void>.delayed(Duration.zero);

      expect(container.read(authNotifierProvider), isA<AuthUnauthenticated>());
    },
  );
}

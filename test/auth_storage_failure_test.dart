import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glickr/core/providers/auth_provider.dart';
import 'package:glickr/core/services/auth_service.dart';
import 'package:glickr/core/services/secure_storage_service.dart';

/// A keychain that refuses: Linux with no Secret Service daemon, or Deny on
/// the macOS keychain prompt. flutter_secure_storage reports both as a
/// PlatformException.
class _RefusingStorage extends FlutterSecureStorage {
  const _RefusingStorage();

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) => throw PlatformException(code: 'Libsecret error');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final refusing = SecureStorageService(storage: const _RefusingStorage());

  test(
    'an unreadable keychain at launch is "not signed in", not a throw',
    () async {
      final auth = AuthService(secureStorage: refusing, dio: Dio());
      expect(await auth.checkExistingAuth(), isA<AuthFailure>());
    },
  );

  test(
    'the launch check lands on the sign-in screen, not the splash',
    () async {
      final container = ProviderContainer(
        overrides: [secureStorageProvider.overrideWithValue(refusing)],
      );
      addTearDown(container.dispose);
      container.listen(authNotifierProvider, (_, _) {});
      expect(container.read(authNotifierProvider), isA<AuthLoading>());

      // The check runs as a microtask off build().
      await Future<void>.delayed(Duration.zero);

      expect(container.read(authNotifierProvider), isA<AuthUnauthenticated>());
    },
  );
}

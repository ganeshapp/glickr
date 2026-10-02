import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
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
    'an unreadable keychain at launch is "not signed in", with the reason',
    () async {
      final auth = AuthService(secureStorage: refusing, dio: Dio());
      expect(
        await auth.checkExistingAuth(),
        isA<AuthFailure>().having(
          (f) => f.message,
          'message',
          startsWith("Couldn't read your sign-in from the keychain"),
        ),
      );

      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      expect(
        await auth.checkExistingAuth(),
        isA<AuthFailure>().having(
          (f) => f.message,
          'message',
          contains('gnome-keyring'),
        ),
      );
    },
  );

  test('nothing stored is the plain sign-in screen, with no message', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final auth = AuthService(secureStorage: SecureStorageService(), dio: Dio());
    expect(await auth.checkExistingAuth(), isA<AuthSignedOut>());
  });

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

      expect(
        container.read(authNotifierProvider),
        isA<AuthUnauthenticated>().having(
          (s) => s.message,
          'message',
          contains('keychain'),
        ),
      );
    },
  );
}

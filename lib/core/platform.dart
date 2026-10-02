import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Platform gates. Read through [defaultTargetPlatform], not dart:io Platform:
/// under `flutter test` it reports android on every host, so the suite keeps
/// testing the phone path on a Linux CI runner; a test opts in with
/// `debugDefaultTargetPlatformOverride`; release builds constant-fold it.
bool get isLinux => defaultTargetPlatform == TargetPlatform.linux;
bool get isMacOS => defaultTargetPlatform == TargetPlatform.macOS;
bool get isDesktop => isLinux || isMacOS;

/// The macOS bundle id and Linux APPLICATION_ID, and so the name of the app's
/// directories on both.
const appId = 'com.glickr.glickr';

/// Stands in for [Platform.environment] under test.
@visibleForTesting
Map<String, String>? debugEnvironmentOverride;

/// Where the app keeps its own files: Hive boxes and queued uploads.
///
/// Android keeps the documents dir existing installs already use; macOS uses
/// Application Support. Linux is computed from the XDG base directory rather
/// than asked of path_provider, whose Linux lookup names the directory after
/// the GApplication id when libgio can be dlopen'd and after the executable
/// when it cannot - so installing libglib2.0-dev moved the data.
Future<Directory> appDataDir() => switch (defaultTargetPlatform) {
  TargetPlatform.linux => _xdgDir('XDG_DATA_HOME', '.local/share'),
  TargetPlatform.macOS => getApplicationSupportDirectory(),
  _ => getApplicationDocumentsDirectory(),
};

/// Where downloaded media is cached: Android's own cache dir, ~/Library/Caches
/// on macOS, $XDG_CACHE_HOME on Linux. Never /tmp, which every user on the
/// machine shares and which is emptied at boot.
Future<Directory> appCacheDir() => switch (defaultTargetPlatform) {
  TargetPlatform.linux => _xdgDir('XDG_CACHE_HOME', '.cache'),
  TargetPlatform.macOS => getApplicationCacheDirectory(),
  _ => getTemporaryDirectory(),
};

/// `$variable/com.glickr.glickr`, or `~/fallback/com.glickr.glickr` when the
/// variable is unset or not absolute, as the XDG spec has it. Private to the
/// user: Directory.create cannot set a mode, so chmod follows it.
Future<Directory> _xdgDir(String variable, String fallback) async {
  final env = debugEnvironmentOverride ?? Platform.environment;
  final base = env[variable] ?? '';
  final root = base.startsWith('/') ? base : p.join(env['HOME']!, fallback);
  final dir = await Directory(p.join(root, appId)).create(recursive: true);
  await Process.run('chmod', ['0700', dir.path]);
  return dir;
}

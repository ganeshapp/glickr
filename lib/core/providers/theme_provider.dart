import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'theme_provider.g.dart';

/// Hive box for small app-level settings (plain string values)
@riverpod
Box<String> appSettingsBox(Ref ref) {
  return Hive.box<String>('app_settings');
}

/// Persisted theme override: system (default), light, or dark.
/// Backed by the `app_settings` Hive box so it survives restarts.
@riverpod
class ThemeModeNotifier extends _$ThemeModeNotifier {
  static const _key = 'theme_mode';

  @override
  ThemeMode build() {
    final stored = ref.watch(appSettingsBoxProvider).get(_key);
    return switch (stored) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> setMode(ThemeMode mode) async {
    await ref.read(appSettingsBoxProvider).put(_key, mode.name);
    state = mode;
  }
}

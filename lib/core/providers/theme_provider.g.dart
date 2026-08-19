// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'theme_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$appSettingsBoxHash() => r'1c5daae3d0eacf794bdd43b23e4ff6ed6b8eea3d';

/// Hive box for small app-level settings (plain string values)
///
/// Copied from [appSettingsBox].
@ProviderFor(appSettingsBox)
final appSettingsBoxProvider = AutoDisposeProvider<Box<String>>.internal(
  appSettingsBox,
  name: r'appSettingsBoxProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$appSettingsBoxHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef AppSettingsBoxRef = AutoDisposeProviderRef<Box<String>>;
String _$themeModeNotifierHash() => r'2f7d9f3e01461d6ccdc39c7d7c3ae8a5f4874c23';

/// Persisted theme override: system (default), light, or dark.
/// Backed by the `app_settings` Hive box so it survives restarts.
///
/// Copied from [ThemeModeNotifier].
@ProviderFor(ThemeModeNotifier)
final themeModeNotifierProvider =
    AutoDisposeNotifierProvider<ThemeModeNotifier, ThemeMode>.internal(
  ThemeModeNotifier.new,
  name: r'themeModeNotifierProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$themeModeNotifierHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

typedef _$ThemeModeNotifier = AutoDisposeNotifier<ThemeMode>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package

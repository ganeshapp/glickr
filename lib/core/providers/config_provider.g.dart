// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'config_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$configBoxHash() => r'6f49d6e1420a9aa00f3a4fca21d8d5a171b8cf88';

/// See also [configBox].
@ProviderFor(configBox)
final configBoxProvider = Provider<Box<AppConfig>>.internal(
  configBox,
  name: r'configBoxProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product') ? null : _$configBoxHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef ConfigBoxRef = ProviderRef<Box<AppConfig>>;
String _$albumsBoxHash() => r'df5d306d3d20253909d9c563dfc99a12f7812068';

/// See also [albumsBox].
@ProviderFor(albumsBox)
final albumsBoxProvider = Provider<Box<Album>>.internal(
  albumsBox,
  name: r'albumsBoxProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product') ? null : _$albumsBoxHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef AlbumsBoxRef = ProviderRef<Box<Album>>;
String _$syncStateBoxHash() => r'e5a1b51910f522684aa8c7533abac3f65f4cbb4f';

/// Head sha, etag and last-sync time. Deliberately separate from [AppConfig]
/// so clearing the cache never touches the user's repo choice.
///
/// Copied from [syncStateBox].
@ProviderFor(syncStateBox)
final syncStateBoxProvider = Provider<Box<Map>>.internal(
  syncStateBox,
  name: r'syncStateBoxProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product') ? null : _$syncStateBoxHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef SyncStateBoxRef = ProviderRef<Box<Map>>;
String _$uploadBatchBoxHash() => r'd3234f0ddfa44e3b6676c939cfdc047a5a03032b';

/// See also [uploadBatchBox].
@ProviderFor(uploadBatchBox)
final uploadBatchBoxProvider = Provider<Box<Map>>.internal(
  uploadBatchBox,
  name: r'uploadBatchBoxProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$uploadBatchBoxHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef UploadBatchBoxRef = ProviderRef<Box<Map>>;
String _$uploadItemBoxHash() => r'6314db09e0d5e5273e114966201bb265a1c21322';

/// See also [uploadItemBox].
@ProviderFor(uploadItemBox)
final uploadItemBoxProvider = Provider<Box<Map>>.internal(
  uploadItemBox,
  name: r'uploadItemBoxProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$uploadItemBoxHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef UploadItemBoxRef = ProviderRef<Box<Map>>;
String _$configNotifierHash() => r'8df9c4d464fe35821ec8f50ff756d0a487394d87';

/// The configured repository, or null until the user picks one.
///
/// keepAlive, not autoDispose: this is app-global state that outlives every
/// screen. With autoDispose, a caller holding the notifier across a navigation
/// would mutate a detached provider element and the write would be silently
/// lost.
///
/// Copied from [ConfigNotifier].
@ProviderFor(ConfigNotifier)
final configNotifierProvider =
    NotifierProvider<ConfigNotifier, AppConfig?>.internal(
  ConfigNotifier.new,
  name: r'configNotifierProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$configNotifierHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

typedef _$ConfigNotifier = Notifier<AppConfig?>;
String _$syncStateNotifierHash() => r'e0a13d3d586306db89e5886f988b9a732f8a6c39';

/// See also [SyncStateNotifier].
@ProviderFor(SyncStateNotifier)
final syncStateNotifierProvider =
    NotifierProvider<SyncStateNotifier, RepoSyncState>.internal(
  SyncStateNotifier.new,
  name: r'syncStateNotifierProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$syncStateNotifierHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

typedef _$SyncStateNotifier = Notifier<RepoSyncState>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package

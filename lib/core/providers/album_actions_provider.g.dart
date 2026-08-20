// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'album_actions_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$albumByFolderHash() => r'9c6a0ba89bcaea6b8c80fc65167b71f6b740c435';

/// Copied from Dart SDK
class _SystemHash {
  _SystemHash._();

  static int combine(int hash, int value) {
    // ignore: parameter_assignments
    hash = 0x1fffffff & (hash + value);
    // ignore: parameter_assignments
    hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
    return hash ^ (hash >> 6);
  }

  static int finish(int hash) {
    // ignore: parameter_assignments
    hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
    // ignore: parameter_assignments
    hash = hash ^ (hash >> 11);
    return 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
  }
}

/// The live album for [folder], straight from the albums list so it updates
/// whenever a sync or a mutation lands.
///
/// Copied from [albumByFolder].
@ProviderFor(albumByFolder)
const albumByFolderProvider = AlbumByFolderFamily();

/// The live album for [folder], straight from the albums list so it updates
/// whenever a sync or a mutation lands.
///
/// Copied from [albumByFolder].
class AlbumByFolderFamily extends Family<Album?> {
  /// The live album for [folder], straight from the albums list so it updates
  /// whenever a sync or a mutation lands.
  ///
  /// Copied from [albumByFolder].
  const AlbumByFolderFamily();

  /// The live album for [folder], straight from the albums list so it updates
  /// whenever a sync or a mutation lands.
  ///
  /// Copied from [albumByFolder].
  AlbumByFolderProvider call(
    String folder,
  ) {
    return AlbumByFolderProvider(
      folder,
    );
  }

  @override
  AlbumByFolderProvider getProviderOverride(
    covariant AlbumByFolderProvider provider,
  ) {
    return call(
      provider.folder,
    );
  }

  static const Iterable<ProviderOrFamily>? _dependencies = null;

  @override
  Iterable<ProviderOrFamily>? get dependencies => _dependencies;

  static const Iterable<ProviderOrFamily>? _allTransitiveDependencies = null;

  @override
  Iterable<ProviderOrFamily>? get allTransitiveDependencies =>
      _allTransitiveDependencies;

  @override
  String? get name => r'albumByFolderProvider';
}

/// The live album for [folder], straight from the albums list so it updates
/// whenever a sync or a mutation lands.
///
/// Copied from [albumByFolder].
class AlbumByFolderProvider extends AutoDisposeProvider<Album?> {
  /// The live album for [folder], straight from the albums list so it updates
  /// whenever a sync or a mutation lands.
  ///
  /// Copied from [albumByFolder].
  AlbumByFolderProvider(
    String folder,
  ) : this._internal(
          (ref) => albumByFolder(
            ref as AlbumByFolderRef,
            folder,
          ),
          from: albumByFolderProvider,
          name: r'albumByFolderProvider',
          debugGetCreateSourceHash:
              const bool.fromEnvironment('dart.vm.product')
                  ? null
                  : _$albumByFolderHash,
          dependencies: AlbumByFolderFamily._dependencies,
          allTransitiveDependencies:
              AlbumByFolderFamily._allTransitiveDependencies,
          folder: folder,
        );

  AlbumByFolderProvider._internal(
    super._createNotifier, {
    required super.name,
    required super.dependencies,
    required super.allTransitiveDependencies,
    required super.debugGetCreateSourceHash,
    required super.from,
    required this.folder,
  }) : super.internal();

  final String folder;

  @override
  Override overrideWith(
    Album? Function(AlbumByFolderRef provider) create,
  ) {
    return ProviderOverride(
      origin: this,
      override: AlbumByFolderProvider._internal(
        (ref) => create(ref as AlbumByFolderRef),
        from: from,
        name: null,
        dependencies: null,
        allTransitiveDependencies: null,
        debugGetCreateSourceHash: null,
        folder: folder,
      ),
    );
  }

  @override
  AutoDisposeProviderElement<Album?> createElement() {
    return _AlbumByFolderProviderElement(this);
  }

  @override
  bool operator ==(Object other) {
    return other is AlbumByFolderProvider && other.folder == folder;
  }

  @override
  int get hashCode {
    var hash = _SystemHash.combine(0, runtimeType.hashCode);
    hash = _SystemHash.combine(hash, folder.hashCode);

    return _SystemHash.finish(hash);
  }
}

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
mixin AlbumByFolderRef on AutoDisposeProviderRef<Album?> {
  /// The parameter `folder` of this provider.
  String get folder;
}

class _AlbumByFolderProviderElement extends AutoDisposeProviderElement<Album?>
    with AlbumByFolderRef {
  _AlbumByFolderProviderElement(super.provider);

  @override
  String get folder => (origin as AlbumByFolderProvider).folder;
}

String _$albumActionsHash() => r'aeaa1a1a83d0635f1c2db28ae7f98c364dd63721';

/// Every album mutation the UI can trigger.
///
/// Each one is a single git commit, and each one refreshes the album list
/// afterwards so the local cache and the repo cannot drift.
///
/// Each one also keeps STAGED captions in step with what it just did, HERE
/// rather than in the screen that called it. A staged caption is filed under
/// (folder, filename), so a delete, a rename or a cover swap moves the ground
/// under it - and when that bookkeeping lived in the screens, the album screen
/// did it and the album LIST silently did not: renaming from the list stranded
/// unsaved captions on a dead folder, and deleting from it left them to
/// reattach to the next album that took the name. There is one door per
/// mutation and it is this class; a caller cannot forget what it never had to
/// remember.
///
/// Copied from [AlbumActions].
@ProviderFor(AlbumActions)
final albumActionsProvider =
    AutoDisposeNotifierProvider<AlbumActions, bool>.internal(
  AlbumActions.new,
  name: r'albumActionsProvider',
  debugGetCreateSourceHash:
      const bool.fromEnvironment('dart.vm.product') ? null : _$albumActionsHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

typedef _$AlbumActions = AutoDisposeNotifier<bool>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package

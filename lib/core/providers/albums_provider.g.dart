// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'albums_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$visibleAlbumsHash() => r'f95698bc973e905dd44424fc848d15e6b49941a9';

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

/// The album list as the UI shows it: sorted and filtered.
///
/// Copied from [visibleAlbums].
@ProviderFor(visibleAlbums)
const visibleAlbumsProvider = VisibleAlbumsFamily();

/// The album list as the UI shows it: sorted and filtered.
///
/// Copied from [visibleAlbums].
class VisibleAlbumsFamily extends Family<List<Album>> {
  /// The album list as the UI shows it: sorted and filtered.
  ///
  /// Copied from [visibleAlbums].
  const VisibleAlbumsFamily();

  /// The album list as the UI shows it: sorted and filtered.
  ///
  /// Copied from [visibleAlbums].
  VisibleAlbumsProvider call(
    String query,
  ) {
    return VisibleAlbumsProvider(
      query,
    );
  }

  @override
  VisibleAlbumsProvider getProviderOverride(
    covariant VisibleAlbumsProvider provider,
  ) {
    return call(
      provider.query,
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
  String? get name => r'visibleAlbumsProvider';
}

/// The album list as the UI shows it: sorted and filtered.
///
/// Copied from [visibleAlbums].
class VisibleAlbumsProvider extends AutoDisposeProvider<List<Album>> {
  /// The album list as the UI shows it: sorted and filtered.
  ///
  /// Copied from [visibleAlbums].
  VisibleAlbumsProvider(
    String query,
  ) : this._internal(
          (ref) => visibleAlbums(
            ref as VisibleAlbumsRef,
            query,
          ),
          from: visibleAlbumsProvider,
          name: r'visibleAlbumsProvider',
          debugGetCreateSourceHash:
              const bool.fromEnvironment('dart.vm.product')
                  ? null
                  : _$visibleAlbumsHash,
          dependencies: VisibleAlbumsFamily._dependencies,
          allTransitiveDependencies:
              VisibleAlbumsFamily._allTransitiveDependencies,
          query: query,
        );

  VisibleAlbumsProvider._internal(
    super._createNotifier, {
    required super.name,
    required super.dependencies,
    required super.allTransitiveDependencies,
    required super.debugGetCreateSourceHash,
    required super.from,
    required this.query,
  }) : super.internal();

  final String query;

  @override
  Override overrideWith(
    List<Album> Function(VisibleAlbumsRef provider) create,
  ) {
    return ProviderOverride(
      origin: this,
      override: VisibleAlbumsProvider._internal(
        (ref) => create(ref as VisibleAlbumsRef),
        from: from,
        name: null,
        dependencies: null,
        allTransitiveDependencies: null,
        debugGetCreateSourceHash: null,
        query: query,
      ),
    );
  }

  @override
  AutoDisposeProviderElement<List<Album>> createElement() {
    return _VisibleAlbumsProviderElement(this);
  }

  @override
  bool operator ==(Object other) {
    return other is VisibleAlbumsProvider && other.query == query;
  }

  @override
  int get hashCode {
    var hash = _SystemHash.combine(0, runtimeType.hashCode);
    hash = _SystemHash.combine(hash, query.hashCode);

    return _SystemHash.finish(hash);
  }
}

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
mixin VisibleAlbumsRef on AutoDisposeProviderRef<List<Album>> {
  /// The parameter `query` of this provider.
  String get query;
}

class _VisibleAlbumsProviderElement
    extends AutoDisposeProviderElement<List<Album>> with VisibleAlbumsRef {
  _VisibleAlbumsProviderElement(super.provider);

  @override
  String get query => (origin as VisibleAlbumsProvider).query;
}

String _$albumsNotifierHash() => r'8cfb09033112cd9c1b99690508ce4de307d78312';

/// The album list, cache-first.
///
/// Copied from [AlbumsNotifier].
@ProviderFor(AlbumsNotifier)
final albumsNotifierProvider =
    AutoDisposeNotifierProvider<AlbumsNotifier, AlbumsState>.internal(
  AlbumsNotifier.new,
  name: r'albumsNotifierProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$albumsNotifierHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

typedef _$AlbumsNotifier = AutoDisposeNotifier<AlbumsState>;
String _$albumSortNotifierHash() => r'fdce2fc99ec78cb856bc1545f7166c43ec516e9a';

/// Persisted sort order for the album grid.
///
/// Copied from [AlbumSortNotifier].
@ProviderFor(AlbumSortNotifier)
final albumSortNotifierProvider =
    AutoDisposeNotifierProvider<AlbumSortNotifier, AlbumSort>.internal(
  AlbumSortNotifier.new,
  name: r'albumSortNotifierProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$albumSortNotifierHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

typedef _$AlbumSortNotifier = AutoDisposeNotifier<AlbumSort>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package

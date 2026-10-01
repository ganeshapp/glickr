// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'gallery_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$galleryNotifierHash() => r'126c96fd59d4d74f2cbe22d130bbe232371efee7';

/// The device gallery, paged.
///
/// Permission is requested lazily, when the picker first opens - never at
/// launch. A permission dialog as the first thing after sign-in is the
/// highest-friction opening a mobile app can have, and the albums screen
/// renders perfectly well from cache without it.
///
/// Copied from [GalleryNotifier].
@ProviderFor(GalleryNotifier)
final galleryNotifierProvider =
    AutoDisposeNotifierProvider<GalleryNotifier, GalleryState>.internal(
  GalleryNotifier.new,
  name: r'galleryNotifierProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$galleryNotifierHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

typedef _$GalleryNotifier = AutoDisposeNotifier<GalleryState>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package

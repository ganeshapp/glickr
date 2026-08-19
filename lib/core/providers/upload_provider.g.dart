// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'upload_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$uploadQueueNotifierHash() =>
    r'e46d6490a9501c5a1cb7df62ad994a03c208050d';

/// Owns the upload queue and drains it.
///
/// keepAlive because it must keep listening while no screen is mounted: an
/// upload started from the album screen has to survive the user navigating
/// into the viewer, out to settings, and back.
///
/// Copied from [UploadQueueNotifier].
@ProviderFor(UploadQueueNotifier)
final uploadQueueNotifierProvider =
    NotifierProvider<UploadQueueNotifier, UploadQueueState>.internal(
  UploadQueueNotifier.new,
  name: r'uploadQueueNotifierProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$uploadQueueNotifierHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

typedef _$UploadQueueNotifier = Notifier<UploadQueueState>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package

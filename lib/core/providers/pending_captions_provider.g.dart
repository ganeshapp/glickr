// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'pending_captions_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$pendingCaptionsBoxHash() =>
    r'1de1f7b494c54cc87d8a943b4e796e8ac53df247';

/// Caption edits made but not yet committed, per album folder.
///
/// Captions are staged locally and flushed as ONE commit, because every commit
/// to the album repo triggers the site's build. Committing on each keystroke-
/// pause meant captioning a 23-photo album queued 23 builds; the app was
/// effectively DDoSing its own website.
///
/// Staged edits are persisted, so closing the app with unsaved captions keeps
/// them rather than quietly dropping the user's typing.
///
/// Copied from [pendingCaptionsBox].
@ProviderFor(pendingCaptionsBox)
final pendingCaptionsBoxProvider = Provider<Box<Map>>.internal(
  pendingCaptionsBox,
  name: r'pendingCaptionsBoxProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$pendingCaptionsBoxHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef PendingCaptionsBoxRef = ProviderRef<Box<Map>>;
String _$pendingCaptionsNotifierHash() =>
    r'4d7d52270f37514ce9aa4dcfe2c1de6f7ae36b31';

/// See also [PendingCaptionsNotifier].
@ProviderFor(PendingCaptionsNotifier)
final pendingCaptionsNotifierProvider =
    NotifierProvider<PendingCaptionsNotifier, PendingCaptions>.internal(
  PendingCaptionsNotifier.new,
  name: r'pendingCaptionsNotifierProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$pendingCaptionsNotifierHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

typedef _$PendingCaptionsNotifier = Notifier<PendingCaptions>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package

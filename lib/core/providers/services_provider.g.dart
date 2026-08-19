// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'services_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

String _$githubRateGateHash() => r'673b658289dbf1abb928e831594a4a889be858db';

/// The single write gate for the whole app.
///
/// keepAlive is load-bearing rather than an optimisation: the gate's job is to
/// remember how many content requests have gone out in the last hour and when
/// the last one started. A gate rebuilt on navigation would forget both and
/// walk straight into a secondary rate limit.
///
/// Copied from [githubRateGate].
@ProviderFor(githubRateGate)
final githubRateGateProvider = Provider<GitHubRateGate>.internal(
  githubRateGate,
  name: r'githubRateGateProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$githubRateGateHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef GithubRateGateRef = ProviderRef<GitHubRateGate>;
String _$gitDataServiceHash() => r'8b136265d8b67fcf0c5470c08f6ba1d455e80f8f';

/// See also [gitDataService].
@ProviderFor(gitDataService)
final gitDataServiceProvider = Provider<GitDataService>.internal(
  gitDataService,
  name: r'gitDataServiceProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$gitDataServiceHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef GitDataServiceRef = ProviderRef<GitDataService>;
String _$commitServiceHash() => r'a8d44b536c0ba1947989db1af9acb197a4ac4c9f';

/// See also [commitService].
@ProviderFor(commitService)
final commitServiceProvider = Provider<CommitService>.internal(
  commitService,
  name: r'commitServiceProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$commitServiceHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef CommitServiceRef = ProviderRef<CommitService>;
String _$albumRepositoryHash() => r'624a7060b4d8c68c4aec0bb0f903d3a836194374';

/// See also [albumRepository].
@ProviderFor(albumRepository)
final albumRepositoryProvider = Provider<AlbumRepository>.internal(
  albumRepository,
  name: r'albumRepositoryProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$albumRepositoryHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef AlbumRepositoryRef = ProviderRef<AlbumRepository>;
String _$albumWriteServiceHash() => r'3dd044d73e9812213cf6854fe8d57f590f7e67e4';

/// See also [albumWriteService].
@ProviderFor(albumWriteService)
final albumWriteServiceProvider = Provider<AlbumWriteService>.internal(
  albumWriteService,
  name: r'albumWriteServiceProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$albumWriteServiceHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef AlbumWriteServiceRef = ProviderRef<AlbumWriteService>;
String _$repoRepositoryHash() => r'2088981082aa27405cda4bbd77eab9e0870e5330';

/// See also [repoRepository].
@ProviderFor(repoRepository)
final repoRepositoryProvider = Provider<RepoRepository>.internal(
  repoRepository,
  name: r'repoRepositoryProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$repoRepositoryHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef RepoRepositoryRef = ProviderRef<RepoRepository>;
String _$mediaPipelineServiceHash() =>
    r'3779a6593c74353ed4bd87ccd24f52fb28afa73b';

/// See also [mediaPipelineService].
@ProviderFor(mediaPipelineService)
final mediaPipelineServiceProvider = Provider<MediaPipelineService>.internal(
  mediaPipelineService,
  name: r'mediaPipelineServiceProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$mediaPipelineServiceHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef MediaPipelineServiceRef = ProviderRef<MediaPipelineService>;
String _$mediaCacheServiceHash() => r'bdcc7deec69954674fe1fd89ebfe8eec2ff577b1';

/// One cache manager for the app's lifetime. Two instances pointed at the same
/// directory would fight over the same sqlite index.
///
/// Copied from [mediaCacheService].
@ProviderFor(mediaCacheService)
final mediaCacheServiceProvider = Provider<MediaCacheService>.internal(
  mediaCacheService,
  name: r'mediaCacheServiceProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$mediaCacheServiceHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef MediaCacheServiceRef = ProviderRef<MediaCacheService>;
String _$uploadQueueServiceHash() =>
    r'42af11d11a7f97d117f2db827cc838b825781d59';

/// See also [uploadQueueService].
@ProviderFor(uploadQueueService)
final uploadQueueServiceProvider = Provider<UploadQueueService>.internal(
  uploadQueueService,
  name: r'uploadQueueServiceProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$uploadQueueServiceHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef UploadQueueServiceRef = ProviderRef<UploadQueueService>;
String _$uploadServiceHash() => r'088c6e2bb17016089ee05a42b0e6b60421f80005';

/// See also [uploadService].
@ProviderFor(uploadService)
final uploadServiceProvider = Provider<UploadService>.internal(
  uploadService,
  name: r'uploadServiceProvider',
  debugGetCreateSourceHash: const bool.fromEnvironment('dart.vm.product')
      ? null
      : _$uploadServiceHash,
  dependencies: null,
  allTransitiveDependencies: null,
);

@Deprecated('Will be removed in 3.0. Use Ref instead')
// ignore: unused_element
typedef UploadServiceRef = ProviderRef<UploadService>;
// ignore_for_file: type=lint
// ignore_for_file: subtype_of_sealed_class, invalid_use_of_internal_member, invalid_use_of_visible_for_testing_member, deprecated_member_use_from_same_package

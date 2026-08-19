import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../services/album_repository.dart';
import '../services/album_write_service.dart';
import '../services/commit_service.dart';
import '../services/dio_client.dart';
import '../services/git_data_service.dart';
import '../services/github_rate_gate.dart';
import '../services/media_cache_service.dart';
import '../services/media_pipeline_service.dart';
import '../services/repo_repository.dart';
import '../services/upload_queue_service.dart';
import '../services/upload_service.dart';
import 'config_provider.dart';

part 'services_provider.g.dart';

/// The single write gate for the whole app.
///
/// keepAlive is load-bearing rather than an optimisation: the gate's job is to
/// remember how many content requests have gone out in the last hour and when
/// the last one started. A gate rebuilt on navigation would forget both and
/// walk straight into a secondary rate limit.
@Riverpod(keepAlive: true)
GitHubRateGate githubRateGate(Ref ref) => GitHubRateGate();

@Riverpod(keepAlive: true)
GitDataService gitDataService(Ref ref) {
  return GitDataService(
    dio: ref.watch(apiClientProvider).dio,
    gate: ref.watch(githubRateGateProvider),
  );
}

@Riverpod(keepAlive: true)
CommitService commitService(Ref ref) {
  return CommitService(git: ref.watch(gitDataServiceProvider));
}

@Riverpod(keepAlive: true)
AlbumRepository albumRepository(Ref ref) {
  return AlbumRepository(git: ref.watch(gitDataServiceProvider));
}

@Riverpod(keepAlive: true)
AlbumWriteService albumWriteService(Ref ref) {
  return AlbumWriteService(
    git: ref.watch(gitDataServiceProvider),
    commits: ref.watch(commitServiceProvider),
  );
}

@Riverpod(keepAlive: true)
RepoRepository repoRepository(Ref ref) {
  return RepoRepository(
    dio: ref.watch(apiClientProvider).dio,
    git: ref.watch(gitDataServiceProvider),
  );
}

@Riverpod(keepAlive: true)
MediaPipelineService mediaPipelineService(Ref ref) => MediaPipelineService();

/// One cache manager for the app's lifetime. Two instances pointed at the same
/// directory would fight over the same sqlite index.
@Riverpod(keepAlive: true)
MediaCacheService mediaCacheService(Ref ref) {
  final config = ref.watch(configNotifierProvider);
  // Roughly 250 KB a photo at the default preset, so the object count is
  // derived from the user's chosen disk budget rather than guessed.
  final budgetMb = config?.cacheBudgetMb ?? 300;
  return MediaCacheService(maxObjects: (budgetMb * 1024) ~/ 250);
}

@Riverpod(keepAlive: true)
UploadQueueService uploadQueueService(Ref ref) {
  return UploadQueueService(
    batches: ref.watch(uploadBatchBoxProvider),
    items: ref.watch(uploadItemBoxProvider),
  );
}

@Riverpod(keepAlive: true)
UploadService uploadService(Ref ref) {
  return UploadService(
    git: ref.watch(gitDataServiceProvider),
    commits: ref.watch(commitServiceProvider),
    queue: ref.watch(uploadQueueServiceProvider),
    media: ref.watch(mediaPipelineServiceProvider),
    cache: ref.watch(mediaCacheServiceProvider),
  );
}

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/album.dart';
import '../models/app_config.dart';
import '../services/album_repository.dart';
import '../services/media_pipeline_service.dart';
import 'config_provider.dart';
import 'services_provider.dart';
import 'theme_provider.dart';

part 'albums_provider.g.dart';

/// How the album list is sorted. Persisted, since it is a preference rather
/// than a per-visit choice.
enum AlbumSort {
  /// The order the WEBSITE shows, because the site sorts folders by name.
  /// Home matching the published site is worth more than recency here.
  nameAsc('Name A-Z'),
  newestFirst('Recently updated'),
  mostItems('Most items');

  const AlbumSort(this.label);
  final String label;
}

sealed class AlbumsState {
  const AlbumsState();

  /// Whatever is known right now, even mid-error. Every branch carries it so
  /// the grid never blanks out during a refresh or a failure.
  List<Album> get albums => const [];
}

class AlbumsInitial extends AlbumsState {
  const AlbumsInitial();
}

class AlbumsLoaded extends AlbumsState {
  @override
  final List<Album> albums;
  final bool isRefreshing;
  final DateTime? lastSynced;
  final int repoBytes;

  /// Progress while fetching per-album sidecars, for "Syncing 3 of 12".
  final int? syncDone;
  final int? syncTotal;

  /// Set when a refresh failed but cached content is still on screen. Distinct
  /// from [AlbumsError] on purpose: this is what powers the "showing cached
  /// data" banner rather than an error page over the user's albums.
  final String? syncError;

  /// The repo was too large for one tree response, so item lists may be
  /// partial.
  final bool truncated;

  const AlbumsLoaded({
    required this.albums,
    this.isRefreshing = false,
    this.lastSynced,
    this.repoBytes = 0,
    this.syncDone,
    this.syncTotal,
    this.syncError,
    this.truncated = false,
  });

  AlbumsLoaded copyWith({
    List<Album>? albums,
    bool? isRefreshing,
    DateTime? lastSynced,
    int? repoBytes,
    int? syncDone,
    int? syncTotal,
    String? syncError,
    bool clearSyncError = false,
    bool clearSyncProgress = false,
    bool? truncated,
  }) {
    return AlbumsLoaded(
      albums: albums ?? this.albums,
      isRefreshing: isRefreshing ?? this.isRefreshing,
      lastSynced: lastSynced ?? this.lastSynced,
      repoBytes: repoBytes ?? this.repoBytes,
      syncDone: clearSyncProgress ? null : (syncDone ?? this.syncDone),
      syncTotal: clearSyncProgress ? null : (syncTotal ?? this.syncTotal),
      syncError: clearSyncError ? null : (syncError ?? this.syncError),
      truncated: truncated ?? this.truncated,
    );
  }

  /// True once the repo is close enough to the host's size limit that the
  /// user should know before adding more.
  bool get isNearRepoLimit => repoBytes >= MediaPipelineService.repoWarnBytes;
  bool get isOverRepoLimit => repoBytes >= MediaPipelineService.repoBlockBytes;
}

class AlbumsError extends AlbumsState {
  final String message;
  @override
  final List<Album> albums;
  const AlbumsError(this.message, [this.albums = const []]);
}

/// The album list, cache-first.
@riverpod
class AlbumsNotifier extends _$AlbumsNotifier {
  bool _refreshInFlight = false;

  /// Which repo the automatic build-time refresh has already been fired for,
  /// as [_repoKey]. build() re-runs for reasons that are not "there is new
  /// content to fetch" (any config write, however unrelated), so the trigger
  /// has to be a change of TARGET, not a rebuild.
  String? _autoRefreshedFor;

  /// Identifies the run a refresh belongs to. Bumped whenever what we are
  /// syncing stops being what we were syncing - repo switched, cache wiped,
  /// signed out. A refresh captures this at its start and abandons every write
  /// if it no longer matches, so a response for the previous repo or the
  /// previous account can never land in storage that was just cleared.
  int _generation = 0;

  @override
  AlbumsState build() {
    // Watch the CONFIG - the only input whose change means "these albums are
    // the wrong albums". The sync state is deliberately `read`: refresh()
    // writes it at the end of every sync, so watching it here would close a
    // feedback loop (sync -> save -> rebuild -> sync) that never settles.
    // RepoSyncState has no value equality, so every save notifies.
    final config = ref.watch(configNotifierProvider);
    final sync = ref.read(syncStateNotifierProvider);

    // The cache is RETURNED from build(), not assigned to `state` inside it:
    // Riverpod discards writes made during build's synchronous prelude, so
    // assigning here would silently show an empty grid on every cold start.
    List<Album> cached;
    try {
      cached = _loadCache();
    } catch (_) {
      cached = const [];
    }

    final target = config == null ? null : _repoKey(config);
    final retarget = target != _autoRefreshedFor;
    if (retarget) {
      _autoRefreshedFor = target;
      // Anything already in flight was fetched for the old repo (or the old
      // token) and must not be written anywhere.
      _abandonInFlight();
      if (target != null) {
        // Kick the network refresh out of build so it cannot clobber the value
        // being returned. It is armed, not committed: a caller that builds this
        // notifier only to clear it (repo setup does exactly that, while the
        // config still names the old repo) bumps the generation in between, and
        // the fetch is dropped before it starts rather than refilling the box
        // that was just emptied.
        final generation = _generation;
        Future.microtask(() async {
          if (generation != _generation) return;
          try {
            await refresh();
          } catch (_) {
            // refresh() already folds failures into state.
          }
        });
      }
    }

    if (cached.isEmpty) return const AlbumsInitial();
    return AlbumsLoaded(
      albums: cached,
      isRefreshing: retarget && target != null,
      lastSynced: sync.lastSynced,
      repoBytes: sync.repoBytes,
    );
  }

  /// Everything that decides which folders are albums. Two configs with the
  /// same key describe the same album list, so switching between them needs no
  /// network round-trip.
  String _repoKey(AppConfig config) =>
      '${config.repoOwner}/${config.repoName}@${config.branch}:'
      '${config.albumRoot}';

  /// Retire any refresh that is currently awaiting the network.
  ///
  /// The in-flight call keeps running - there is no way to cancel it - but its
  /// generation is now stale, so it writes nothing. The flag is cleared here
  /// rather than left to its `finally` so the refresh for the NEW target can
  /// start at once instead of being swallowed by the in-flight guard.
  void _abandonInFlight() {
    _generation++;
    _refreshInFlight = false;
  }

  List<Album> _loadCache() {
    final box = ref.read(albumsBoxProvider);
    final albums = box.values.toList();
    albums.sort((a, b) => a.folder.compareTo(b.folder));
    return albums;
  }

  /// Pull the repo and rebuild the list.
  ///
  /// [force] skips the conditional request, for an explicit pull-to-refresh
  /// where "nothing changed" should still feel like it did something.
  Future<void> refresh({bool force = false}) async {
    if (_refreshInFlight) return;
    final config = ref.read(configNotifierProvider);
    if (config == null) return;

    _refreshInFlight = true;
    final generation = _generation;
    final cached = state.albums;
    final sync = ref.read(syncStateNotifierProvider);

    state = AlbumsLoaded(
      albums: cached,
      isRefreshing: true,
      lastSynced: sync.lastSynced,
      repoBytes: sync.repoBytes,
    );

    try {
      final result = await ref
          .read(albumRepositoryProvider)
          .sync(
            config,
            cachedEtag: force ? null : sync.etag,
            cachedAlbums: cached,
            onProgress: (done, total) {
              if (total <= 1 || generation != _generation) return;
              final current = state;
              if (current is AlbumsLoaded) {
                state = current.copyWith(syncDone: done, syncTotal: total);
              }
            },
          );

      if (generation != _generation) return;
      await _writeCache(result.albums);
      await ref
          .read(syncStateNotifierProvider.notifier)
          .save(
            RepoSyncState(
              commitSha: result.commitSha,
              etag: result.etag,
              lastSynced: DateTime.now(),
              repoBytes: result.repoBytes,
            ),
          );

      state = AlbumsLoaded(
        albums: result.albums,
        lastSynced: DateTime.now(),
        repoBytes: result.repoBytes,
        truncated: result.truncated,
      );
    } on AlbumSyncUnchanged {
      // 304: the cached snapshot is exact. Cost one request, no rate limit.
      if (generation != _generation) return;
      await ref
          .read(syncStateNotifierProvider.notifier)
          .save(
            RepoSyncState(
              commitSha: sync.commitSha,
              etag: sync.etag,
              lastSynced: DateTime.now(),
              repoBytes: sync.repoBytes,
            ),
          );
      state = AlbumsLoaded(
        albums: cached,
        lastSynced: DateTime.now(),
        repoBytes: sync.repoBytes,
      );
    } catch (e) {
      if (generation != _generation) return;
      final message = e is Exception ? _friendly(e) : e.toString();
      // Cached content stays on screen; the banner explains why it may be
      // stale. An error page over the user's own albums would be worse.
      state = cached.isEmpty
          ? AlbumsError(message)
          : AlbumsLoaded(
              albums: cached,
              lastSynced: sync.lastSynced,
              repoBytes: sync.repoBytes,
              syncError: message,
            );
    } finally {
      // Only if this call still owns the slot. An abandoned refresh unwinding
      // late must not clear the flag out from under its replacement.
      if (generation == _generation) _refreshInFlight = false;
    }
  }

  Future<void> _writeCache(List<Album> albums) async {
    final box = ref.read(albumsBoxProvider);
    final keep = albums.map((a) => a.folder).toSet();
    final stale = box.keys.where((k) => !keep.contains(k)).toList();
    await box.deleteAll(stale);
    await box.putAll({for (final album in albums) album.folder: album});
  }

  /// Replace one album in memory and cache, for optimistic updates.
  Future<void> upsert(Album album) async {
    await ref.read(albumsBoxProvider).put(album.folder, album);
    final current = state;
    final updated = [...current.albums];
    final index = updated.indexWhere((a) => a.folder == album.folder);
    if (index == -1) {
      updated.add(album);
    } else {
      updated[index] = album;
    }
    updated.sort((a, b) => a.folder.compareTo(b.folder));
    state = current is AlbumsLoaded
        ? current.copyWith(albums: updated)
        : AlbumsLoaded(albums: updated);
  }

  /// Drop an album from memory and cache, for optimistic delete.
  Future<void> removeLocal(String folder) async {
    await ref.read(albumsBoxProvider).delete(folder);
    final current = state;
    final updated = current.albums.where((a) => a.folder != folder).toList();
    state = current is AlbumsLoaded
        ? current.copyWith(albums: updated)
        : AlbumsLoaded(albums: updated);
  }

  Album? byFolder(String folder) {
    for (final album in state.albums) {
      if (album.folder == folder) return album;
    }
    return null;
  }

  /// Wipe every cached album. Used on logout and repo change.
  ///
  /// Nothing is re-fetched here, and nothing may re-fetch on its own
  /// afterwards: at this point the config still names the OLD repo (repo setup
  /// clears before it saves) or the token is about to be dropped, so any
  /// refresh triggered by the clearing itself would refill the box with
  /// exactly the data the caller asked to be rid of. The next fetch happens
  /// when the config actually changes, or when a caller asks for one.
  Future<void> clearCache() async {
    _abandonInFlight();
    await ref.read(albumsBoxProvider).clear();
    await ref.read(syncStateNotifierProvider.notifier).clear();
    state = const AlbumsInitial();
  }

  String _friendly(Exception e) {
    final message = e.toString();
    return message.startsWith('Exception: ')
        ? message.substring('Exception: '.length)
        : message;
  }
}

/// Persisted sort order for the album grid.
@riverpod
class AlbumSortNotifier extends _$AlbumSortNotifier {
  static const _key = 'album_sort';

  @override
  AlbumSort build() {
    final stored = ref.watch(appSettingsBoxProvider).get(_key);
    return AlbumSort.values.firstWhere(
      (s) => s.name == stored,
      orElse: () => AlbumSort.nameAsc,
    );
  }

  Future<void> setSort(AlbumSort sort) async {
    await ref.read(appSettingsBoxProvider).put(_key, sort.name);
    state = sort;
  }
}

/// The album list as the UI shows it: sorted and filtered.
@riverpod
List<Album> visibleAlbums(Ref ref, String query) {
  final albums = [...ref.watch(albumsNotifierProvider).albums];
  final sort = ref.watch(albumSortNotifierProvider);

  switch (sort) {
    case AlbumSort.nameAsc:
      albums.sort((a, b) => a.folder.compareTo(b.folder));
    case AlbumSort.newestFirst:
      albums.sort((a, b) {
        final at = a.lastSynced, bt = b.lastSynced;
        if (at == null && bt == null) return a.folder.compareTo(b.folder);
        if (at == null) return 1;
        if (bt == null) return -1;
        return bt.compareTo(at);
      });
    case AlbumSort.mostItems:
      albums.sort((a, b) {
        final diff = b.gallery.length.compareTo(a.gallery.length);
        return diff != 0 ? diff : a.folder.compareTo(b.folder);
      });
  }

  final trimmed = query.trim().toLowerCase();
  if (trimmed.isEmpty) return albums;
  return albums
      .where(
        (a) =>
            a.title.toLowerCase().contains(trimmed) ||
            a.folder.toLowerCase().contains(trimmed) ||
            a.blurb.toLowerCase().contains(trimmed),
      )
      .toList();
}

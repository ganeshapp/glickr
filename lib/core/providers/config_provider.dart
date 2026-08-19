import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../models/album.dart';
import '../models/app_config.dart';

part 'config_provider.g.dart';

// --------------------------------------------------------------- Hive boxes
// Opened in main() before runApp, so every accessor here is synchronous and
// no screen has to render a loading state for local storage.

@Riverpod(keepAlive: true)
Box<AppConfig> configBox(Ref ref) => Hive.box<AppConfig>('app_config');

@Riverpod(keepAlive: true)
Box<Album> albumsBox(Ref ref) => Hive.box<Album>('albums_box');

/// Head sha, etag and last-sync time. Deliberately separate from [AppConfig]
/// so clearing the cache never touches the user's repo choice.
@Riverpod(keepAlive: true)
Box<Map> syncStateBox(Ref ref) => Hive.box<Map>('sync_state');

@Riverpod(keepAlive: true)
Box<Map> uploadBatchBox(Ref ref) => Hive.box<Map>('upload_batches');

@Riverpod(keepAlive: true)
Box<Map> uploadItemBox(Ref ref) => Hive.box<Map>('upload_items');

// -------------------------------------------------------------------- Config

/// The configured repository, or null until the user picks one.
///
/// keepAlive, not autoDispose: this is app-global state that outlives every
/// screen. With autoDispose, a caller holding the notifier across a navigation
/// would mutate a detached provider element and the write would be silently
/// lost.
@Riverpod(keepAlive: true)
class ConfigNotifier extends _$ConfigNotifier {
  static const _key = 'current_config';

  @override
  AppConfig? build() => ref.watch(configBoxProvider).get(_key);

  Future<void> save(AppConfig config) async {
    await ref.read(configBoxProvider).put(_key, config);
    state = config;
  }

  Future<void> update(AppConfig Function(AppConfig) transform) async {
    final current = state;
    if (current == null) return;
    await save(transform(current));
  }

  Future<void> clear() async {
    await ref.read(configBoxProvider).delete(_key);
    state = null;
  }

  bool get isConfigured => state != null;
}

// ---------------------------------------------------------------- Sync state

/// Cached head commit, etag and repo size for the configured repo.
class RepoSyncState {
  final String? commitSha;
  final String? etag;
  final DateTime? lastSynced;
  final int repoBytes;

  const RepoSyncState({
    this.commitSha,
    this.etag,
    this.lastSynced,
    this.repoBytes = 0,
  });

  Map<String, dynamic> toMap() => {
    'commitSha': commitSha,
    'etag': etag,
    'lastSynced': lastSynced?.toIso8601String(),
    'repoBytes': repoBytes,
  };

  static RepoSyncState fromMap(Map<dynamic, dynamic>? map) {
    if (map == null) return const RepoSyncState();
    return RepoSyncState(
      commitSha: map['commitSha'] as String?,
      etag: map['etag'] as String?,
      lastSynced: DateTime.tryParse(map['lastSynced'] as String? ?? ''),
      repoBytes: (map['repoBytes'] as num?)?.toInt() ?? 0,
    );
  }
}

@Riverpod(keepAlive: true)
class SyncStateNotifier extends _$SyncStateNotifier {
  static const _key = 'repo';

  @override
  RepoSyncState build() {
    return RepoSyncState.fromMap(ref.watch(syncStateBoxProvider).get(_key));
  }

  Future<void> save(RepoSyncState value) async {
    await ref.read(syncStateBoxProvider).put(_key, value.toMap());
    state = value;
  }

  Future<void> clear() async {
    await ref.read(syncStateBoxProvider).delete(_key);
    state = const RepoSyncState();
  }
}

import 'dart:async';

import '../models/app_config.dart';
import 'git_data_service.dart';

/// Outcome of a commit attempt.
sealed class CommitOutcome {
  const CommitOutcome();
}

class CommitApplied extends CommitOutcome {
  final String commitSha;
  final TreeSnapshot treeBefore;
  const CommitApplied({required this.commitSha, required this.treeBefore});
}

/// The requested change was already true, so nothing was committed.
///
/// Not a failure. It is what a resumed batch sees when the ref update landed
/// but the app died before clearing the queue, and what a delete sees when
/// another device already removed the file.
class CommitNoop extends CommitOutcome {
  final String commitSha;
  const CommitNoop(this.commitSha);
}

/// Builds and lands a single commit, rebasing when the branch moves.
///
/// Every write in glickr goes through here, so there is exactly one place that
/// knows how to talk to a moving branch. Two properties matter:
///
///   * ENTRIES ARE BUILT FROM A FRESH TREE, via a callback rather than a fixed
///     list. On a rebase the callback runs again against the new head, which
///     is what lets an upload renumber its files (`0007.jpg` becoming
///     `0009.jpg` because another device claimed the range) WITHOUT
///     re-uploading a single byte - the blobs are content addresses and are
///     already on GitHub.
///   * NOTHING IS VISIBLE UNTIL THE REF MOVES. Blobs and trees created along
///     the way are unreferenced git objects: invisible in the UI, harmless,
///     and garbage-collected. So a 30-photo album upload is effectively one
///     atomic transaction.
class CommitService {
  final GitDataService _git;

  CommitService({required GitDataService git}) : _git = git;

  /// Read the current head and full tree.
  Future<TreeSnapshot> readTree(AppConfig config) async {
    final head = await _git.getHead(
      config.repoOwner,
      config.repoName,
      config.branch,
    );
    return _git.getTree(
      config.repoOwner,
      config.repoName,
      commitSha: head.commitSha!,
      treeSha: head.treeSha!,
    );
  }

  /// Land one commit containing whatever [buildEntries] produces.
  ///
  /// [buildEntries] receives the tree the commit will be based on and returns
  /// the paths to add, replace, or delete. Returning an empty list means the
  /// work is already done and yields [CommitNoop].
  ///
  /// A rejected ref update is expected, not exceptional: another device or a
  /// repo Action may push at any moment. It is retried by rebuilding on the
  /// new head, and only surfaces as an error if that keeps losing.
  Future<CommitOutcome> commit({
    required AppConfig config,
    required String message,
    required FutureOr<List<TreeEntry>> Function(TreeSnapshot tree) buildEntries,
    int maxAttempts = 4,
  }) async {
    Object? lastError;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final tree = await readTree(config);
      final entries = await buildEntries(tree);
      if (entries.isEmpty) return CommitNoop(tree.commitSha);

      final newTreeSha = await _git.createTree(
        config.repoOwner,
        config.repoName,
        baseTreeSha: tree.treeSha,
        entries: entries,
      );
      final newCommitSha = await _git.createCommit(
        config.repoOwner,
        config.repoName,
        message: message,
        treeSha: newTreeSha,
        parentSha: tree.commitSha,
      );

      try {
        await _git.updateRef(
          config.repoOwner,
          config.repoName,
          config.branch,
          newCommitSha,
        );
        return CommitApplied(commitSha: newCommitSha, treeBefore: tree);
      } on NonFastForwardException catch (e) {
        // Someone pushed between our read and our write. Loop: re-read the
        // head, rebuild the entries against it, and try again. Costs four
        // requests and zero re-uploaded bytes.
        lastError = e;
      }
    }
    throw lastError ?? const NonFastForwardException();
  }

  /// Delete entries for [paths], skipping any the tree no longer contains.
  ///
  /// Deleting a path that is absent from base_tree is an API error, so a
  /// delete must always be built from a freshly read tree - never from cached
  /// state, and never blindly retried after a rebase.
  static List<TreeEntry> deletionsFor(TreeSnapshot tree, Set<String> paths) {
    final existing = {
      for (final node in tree.nodes)
        if (node.isBlob) node.path: node,
    };
    final entries = <TreeEntry>[];
    for (final path in paths) {
      final node = existing[path];
      if (node == null) continue; // already gone; treat as success
      entries.add(TreeEntry.delete(path, mode: node.mode));
    }
    return entries;
  }
}

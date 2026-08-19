import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_manager/photo_manager.dart';

import 'package:glickr/core/providers/gallery_provider.dart';

/// A mutable switch, kept off [_FakeBucket] itself: [AssetPathEntity] is
/// `@immutable`, so a non-final field on a subclass trips the analyzer.
class _Hold {
  bool on = false;
}

/// A device album whose pages are handed out by the test rather than by the
/// platform, so a page can be left hanging while the user switches albums.
class _FakeBucket extends AssetPathEntity {
  _FakeBucket(this.label) : super(id: label, name: label);

  static const int pageSize = 120;

  final String label;
  final List<int> requestedPages = [];
  final List<Completer<List<AssetEntity>>> pending = [];

  /// While on, [getAssetListPaged] waits until the test releases it.
  final _Hold hold = _Hold();

  List<AssetEntity> _page(String tag) => List.generate(
    pageSize,
    (i) => AssetEntity(
      id: '$label-$tag-$i',
      typeInt: 1,
      width: 100,
      height: 100,
    ),
  );

  @override
  Future<List<AssetEntity>> getAssetListPaged({
    required int page,
    required int size,
    RequestType? type,
  }) {
    requestedPages.add(page);
    if (!hold.on) return Future.value(_page('$page'));
    final completer = Completer<List<AssetEntity>>();
    pending.add(completer);
    return completer.future;
  }

  void release() {
    for (final completer in pending) {
      if (!completer.isCompleted) completer.complete(_page('late'));
    }
    pending.clear();
  }
}

void main() {
  group('GalleryNotifier paging', () {
    test('a page still in flight cannot land in another album', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // A listener keeps the autoDispose provider alive across the awaits, the
      // way the picker screen does.
      container.listen(galleryNotifierProvider, (_, _) {});
      final notifier = container.read(galleryNotifierProvider.notifier);

      final a = _FakeBucket('A');
      final b = _FakeBucket('B');

      await notifier.selectBucket(a);
      expect(container.read(galleryNotifierProvider).assets, hasLength(120));

      // Scroll to the end of A: page 1 goes out and does not come back yet.
      a.hold.on = true;
      unawaited(notifier.loadMore());
      await pumpEventQueue();

      // The user picks album B while A's page is still out.
      await notifier.selectBucket(b);
      a.release();
      await pumpEventQueue();

      final state = container.read(galleryNotifierProvider);
      expect(state.activeBucket, same(b));
      expect(
        state.assets.every((asset) => asset.id.startsWith('B-')),
        isTrue,
        reason: "album A's photos must not appear under album B",
      );
      expect(state.assets, hasLength(120));
      // B must be paged from the start: its page 1 is still unfetched, so the
      // next scroll has to ask for 1, not 2.
      expect(b.requestedPages, [0]);
      await notifier.loadMore();
      expect(b.requestedPages, [0, 1]);
    });

    test('two overlapping loadMore calls fetch two different pages', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // A listener keeps the autoDispose provider alive across the awaits, the
      // way the picker screen does.
      container.listen(galleryNotifierProvider, (_, _) {});
      final notifier = container.read(galleryNotifierProvider.notifier);

      final bucket = _FakeBucket('A');
      await notifier.selectBucket(bucket);

      bucket.hold.on = true;
      final first = notifier.loadMore();
      final second = notifier.loadMore();
      bucket.release();
      await Future.wait([first, second]);

      expect(bucket.requestedPages, [0, 1]);
      expect(container.read(galleryNotifierProvider).assets, hasLength(240));
    });
  });
}

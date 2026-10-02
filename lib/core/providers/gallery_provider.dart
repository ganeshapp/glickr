import 'package:photo_manager/photo_manager.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../platform.dart';
import '../services/desktop_media.dart';

part 'gallery_provider.g.dart';

/// How much of the device gallery glickr is allowed to see.
enum GalleryAccess {
  /// Not asked yet.
  unknown,

  /// Full access.
  granted,

  /// Android 14+ "selected photos only". The grid genuinely shows a subset,
  /// which users reliably report as missing photos unless the UI says so.
  limited,

  /// Refused. Not a dead end - the system picker needs no permission at all.
  denied,
}

class GalleryState {
  final GalleryAccess access;
  final List<AssetPathEntity> buckets;
  final AssetPathEntity? activeBucket;
  final List<AssetEntity> assets;
  final bool isLoading;
  final bool hasMore;
  final String? error;

  const GalleryState({
    this.access = GalleryAccess.unknown,
    this.buckets = const [],
    this.activeBucket,
    this.assets = const [],
    this.isLoading = false,
    this.hasMore = true,
    this.error,
  });

  GalleryState copyWith({
    GalleryAccess? access,
    List<AssetPathEntity>? buckets,
    AssetPathEntity? activeBucket,
    List<AssetEntity>? assets,
    bool? isLoading,
    bool? hasMore,
    String? error,
    bool clearError = false,
  }) {
    return GalleryState(
      access: access ?? this.access,
      buckets: buckets ?? this.buckets,
      activeBucket: activeBucket ?? this.activeBucket,
      assets: assets ?? this.assets,
      isLoading: isLoading ?? this.isLoading,
      hasMore: hasMore ?? this.hasMore,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// The device gallery, paged.
///
/// Permission is requested lazily, when the picker first opens - never at
/// launch. A permission dialog as the first thing after sign-in is the
/// highest-friction opening a mobile app can have, and the albums screen
/// renders perfectly well from cache without it.
@riverpod
class GalleryNotifier extends _$GalleryNotifier {
  static const int _pageSize = 120;
  int _page = 0;

  /// Identifies the list currently being paged. `_page` and `state.assets` only
  /// mean anything together with this: bumping it declares that every page
  /// request already issued belongs to a list nobody is looking at any more.
  int _generation = 0;

  /// A page request is awaiting the platform. Without this, a scroll-triggered
  /// fetch and a bucket switch both page the same counter.
  bool _loadInFlight = false;

  @override
  GalleryState build() => const GalleryState();

  /// Abandon any page request in flight and start a new paging run.
  void _restartPaging() {
    _generation++;
    // The abandoned request will still complete, but it writes nothing and no
    // longer owns the in-flight slot, so the new run can start immediately.
    _loadInFlight = false;
    _page = 0;
  }

  /// Ask for gallery access and load the first page.
  Future<void> requestAndLoad() async {
    if (isDesktop) return _loadFolder();
    _restartPaging();
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      final access = switch (permission) {
        PermissionState.authorized => GalleryAccess.granted,
        PermissionState.limited => GalleryAccess.limited,
        _ => GalleryAccess.denied,
      };

      if (access == GalleryAccess.denied) {
        state = state.copyWith(access: access, isLoading: false);
        return;
      }

      final buckets = await PhotoManager.getAssetPathList(
        // Both kinds in one query, so a mixed selection keeps the order the
        // user tapped them in - which is what decides filenames, and therefore
        // the order the website shows.
        type: RequestType.common,
        hasAll: true,
        filterOption: FilterOptionGroup(
          orders: [
            const OrderOption(type: OrderOptionType.createDate, asc: false),
          ],
        ),
      );

      if (buckets.isEmpty) {
        state = state.copyWith(
          access: access,
          buckets: const [],
          assets: const [],
          isLoading: false,
          hasMore: false,
        );
        return;
      }

      state = state.copyWith(access: access, buckets: buckets);
      await selectBucket(buckets.first);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  /// Linux has no photo library; a folder the user picks stands in for one.
  /// Cancelling the dialog keeps whatever is already showing.
  Future<void> _loadFolder() async {
    try {
      final assets = await pickPhotoFolder();
      if (assets == null) return;
      state = GalleryState(
        access: GalleryAccess.granted,
        assets: assets,
        hasMore: false,
        // Say why, or an iPhone export (HEIC, MOV) looks like a failed pick.
        error:
            assets.isEmpty
                ? 'That folder has no JPEG, PNG or WebP photos.'
                : null,
      );
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  Future<void> selectBucket(AssetPathEntity bucket) async {
    _restartPaging();
    state = state.copyWith(
      activeBucket: bucket,
      assets: const [],
      isLoading: true,
      hasMore: true,
      clearError: true,
    );
    await loadMore();
  }

  Future<void> loadMore() async {
    final bucket = state.activeBucket;
    if (bucket == null || !state.hasMore || _loadInFlight) return;

    // A page belongs to the bucket AND the run it was requested for. If either
    // has moved on by the time the platform answers, appending it would splice
    // one device album's photos into another's grid and advance `_page` past a
    // page of the new bucket that was never fetched.
    final generation = _generation;
    _loadInFlight = true;
    try {
      final page = await bucket.getAssetListPaged(
        page: _page,
        size: _pageSize,
      );
      if (generation != _generation) return;
      _page++;
      state = state.copyWith(
        assets: [...state.assets, ...page],
        isLoading: false,
        hasMore: page.length == _pageSize,
      );
    } catch (e) {
      if (generation != _generation) return;
      state = state.copyWith(isLoading: false, error: e.toString());
    } finally {
      if (generation == _generation) _loadInFlight = false;
    }
  }

  /// Let the user widen an Android 14 partial grant.
  ///
  /// Always offered rather than shown conditionally: Android never revokes an
  /// already-granted asset, so "limited" is a permanent state the user may want
  /// to add to at any time.
  Future<void> presentLimitedPicker() async {
    await PhotoManager.presentLimited();
    await PhotoManager.clearFileCache();
    final bucket = state.activeBucket;
    if (bucket != null) {
      // The bucket handle caches its count; refetch the list so newly shared
      // assets actually appear.
      await requestAndLoad();
    }
  }

  Future<void> openSettings() => PhotoManager.openSetting();
}

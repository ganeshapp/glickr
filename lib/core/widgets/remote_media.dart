import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/album.dart';
import '../models/media_item.dart';
import '../providers/config_provider.dart';
import '../providers/services_provider.dart';
import '../theme/app_theme.dart';

/// One album item rendered from the byte cache, downloading only if needed.
///
/// Goes through [MediaCacheService] rather than `CachedNetworkImage` directly,
/// because the cache is keyed on the git BLOB sha, not the URL. The media URL
/// contains the head commit sha and therefore changes on every push to any
/// album - a URL-keyed cache would re-download an entire album's thumbnails
/// because one photo was added to a different album.
class RemoteMedia extends ConsumerStatefulWidget {
  final Album album;
  final MediaItem item;
  final BoxFit fit;

  /// Decode width in device pixels. Always pass it in a grid: the repo stores
  /// full-size images (the website has no separate thumbnail tier), so a
  /// 3-column grid would otherwise decode 1600px frames into memory.
  final int? decodeWidth;

  final BorderRadius? borderRadius;

  const RemoteMedia({
    super.key,
    required this.album,
    required this.item,
    this.fit = BoxFit.cover,
    this.decodeWidth,
    this.borderRadius,
  });

  @override
  ConsumerState<RemoteMedia> createState() => _RemoteMediaState();
}

class _RemoteMediaState extends ConsumerState<RemoteMedia> {
  Future<File?>? _future;
  String? _requestedSha;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureRequest();
  }

  @override
  void didUpdateWidget(RemoteMedia oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensureRequest();
  }

  void _ensureRequest() {
    if (_requestedSha == widget.item.blobSha && _future != null) return;
    _requestedSha = widget.item.blobSha;
    _future = _load();
  }

  Future<File?> _load() async {
    final cache = ref.read(mediaCacheServiceProvider);
    final config = ref.read(configNotifierProvider);
    final commitSha = ref.read(syncStateNotifierProvider).commitSha;
    final item = widget.item;

    // What renders for a video is a poster frame, not the clip: an .mp4 has no
    // bytes an image decoder can read, so handing the file itself to
    // Image.file below fails and leaves an empty square with a play glyph on
    // it. The poster is cached under its own key, so this is a disk read on
    // every view after the first.
    final video = item.isVideo;

    // Cache first, always, and without touching the network - so an offline
    // launch shows real photos instead of spinners.
    final hit =
        video ? await cache.cachedPoster(item) : await cache.cachedFile(item);
    if (hit != null) return hit;

    if (config == null || commitSha == null) return null;
    try {
      // Deriving a poster means downloading the clip, which is slow for a big
      // one - but the FutureBuilder below holds the placeholder while it runs,
      // so the grid keeps scrolling either way, and `poster` returns null
      // rather than throwing when it cannot be made.
      return video
          ? await cache.poster(
            config: config,
            album: widget.album,
            item: item,
            commitSha: commitSha,
          )
          : await cache.fetch(
            config: config,
            album: widget.album,
            item: item,
            commitSha: commitSha,
          );
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final radius = widget.borderRadius;
    final content = FutureBuilder<File?>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return _Placeholder(icon: null);
        }
        final file = snapshot.data;
        if (file == null) {
          // Never a broken-image glyph and never a spinner that spins forever.
          // A grid of calm cloud icons reads as "not downloaded yet"; a grid
          // of broken images reads as a bug.
          return const _Placeholder(icon: Icons.cloud_off_rounded);
        }
        return Image.file(
          file,
          fit: widget.fit,
          cacheWidth: widget.decodeWidth,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) =>
              const _Placeholder(icon: Icons.broken_image_outlined),
        );
      },
    );

    if (radius == null) return content;
    return ClipRRect(borderRadius: radius, child: content);
  }
}

class _Placeholder extends StatelessWidget {
  final IconData? icon;
  const _Placeholder({this.icon});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: context.colorScheme.surfaceContainer,
      child: icon == null
          ? const SizedBox.expand()
          : Center(
              child: Icon(
                icon,
                size: 20,
                color: context.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.4,
                ),
              ),
            ),
    );
  }
}

/// The play badge and duration overlay for a video tile.
///
/// Video is signalled by a glyph AND text, never by colour alone.
class VideoBadge extends StatelessWidget {
  final String? duration;
  final double size;

  const VideoBadge({super.key, this.duration, this.size = 28});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.play_arrow_rounded,
            size: size * 0.68,
            color: Colors.white,
          ),
        ),
        if (duration != null) ...[
          const SizedBox(width: 6),
          Text(
            duration!,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              shadows: AppTheme.photoTextShadow,
            ),
          ),
        ],
      ],
    );
  }
}

/// Staggered entrance for grid children.
///
/// The index clamp is essential: without it a 300-item album would take twelve
/// seconds to finish appearing.
class StaggeredFadeIn extends StatelessWidget {
  final int index;
  final Widget child;

  const StaggeredFadeIn({super.key, required this.index, required this.child});

  @override
  Widget build(BuildContext context) {
    final duration = context.motion(
      Duration(milliseconds: 260 + (index.clamp(0, 12)) * 35),
    );
    if (duration == Duration.zero) return child;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: duration,
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 14 * (1 - value)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

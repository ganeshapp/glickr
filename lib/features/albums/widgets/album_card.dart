import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/models/album.dart';
import '../../../core/models/media_item.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/remote_media.dart';

/// One album tile in the home grid: cover photo, title over a scrim, counts
/// underneath.
class AlbumCard extends StatefulWidget {
  final Album album;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const AlbumCard({
    super.key,
    required this.album,
    required this.onTap,
    this.onLongPress,
  });

  @override
  State<AlbumCard> createState() => _AlbumCardState();
}

class _AlbumCardState extends State<AlbumCard> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final album = widget.album;
    final scheme = context.colorScheme;

    // The cover is the preferred face of the album, but a folder can have
    // media and no `0.jpg` - the site falls back to the first gallery item
    // there, so the app does too rather than showing a placeholder for an
    // album that clearly has photos.
    final MediaItem? preview =
        album.cover ?? (album.gallery.isEmpty ? null : album.gallery.first);

    return Listener(
      // Pointer events rather than the InkWell's own callbacks: the press
      // scale has to start the instant the finger lands, and onTapDown does
      // not fire until the gesture arena decides this is not a scroll.
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1,
        duration: context.motion(const Duration(milliseconds: 120)),
        curve: Curves.easeOut,
        // One semantics node for the whole tile. Left alone, a screen reader
        // announces the card, the image, the title and the count as four
        // separate stops.
        child: MergeSemantics(
          child: Card(
            clipBehavior: Clip.antiAlias,
            margin: EdgeInsets.zero,
            child: InkWell(
              onTap: widget.onTap,
              onLongPress: widget.onLongPress == null
                  ? null
                  : () {
                      HapticFeedback.mediumImpact();
                      widget.onLongPress!();
                    },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (preview != null)
                          Hero(
                            tag: 'album-${album.folder}',
                            child: RemoteMedia(
                              album: album,
                              item: preview,
                              // The repo stores full-size images, so without a
                              // decode bound a 4-up tablet grid holds a dozen
                              // 1600px bitmaps at once.
                              decodeWidth: 600,
                            ),
                          )
                        else
                          ColoredBox(
                            color: scheme.surfaceContainer,
                            child: Icon(
                              Icons.photo_outlined,
                              size: 26,
                              color: scheme.onSurfaceVariant.withValues(
                                alpha: 0.5,
                              ),
                            ),
                          ),
                        // Contrast over a user's photograph is undefined - the
                        // cover might be a white sky - so the scrim and the
                        // text shadow together are what keep the title legible.
                        ExcludeSemantics(
                          child: DecoratedBox(
                            decoration: AppTheme.photoScrim(),
                          ),
                        ),
                        Positioned(
                          left: 10,
                          right: 10,
                          bottom: 8,
                          child: Text(
                            album.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context.textTheme.titleSmall?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              height: 1.2,
                              shadows: AppTheme.photoTextShadow,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(6),
                    child: Text(
                      _countLabel(album),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.textTheme.labelSmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "24 photos - 2 videos".
///
/// Counted off [Album.gallery], which excludes the cover, so the number here is
/// the number of items the website actually renders. (When the cover is the
/// only file, `gallery` falls back to including it - again matching the site,
/// which would otherwise render an empty album page.)
String _countLabel(Album album) {
  final photos = album.photoCount;
  final videos = album.videoCount;

  if (photos == 0 && videos == 0) return 'No items yet';

  final videoText = videos == 1 ? '1 video' : '$videos videos';
  if (photos == 0) return videoText;

  final photoText = photos == 1 ? '1 photo' : '$photos photos';
  return videos == 0 ? photoText : '$photoText - $videoText';
}

import 'package:flutter/material.dart';

import '../../../core/models/album.dart';
import '../../../core/models/media_item.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/remote_media.dart';

/// One square in the album grid.
///
/// Stateless on purpose: selection lives in the screen, so a sync that replaces
/// the [Album] instance mid-scroll can rebuild every tile without any of them
/// forgetting whether they were selected.
class MediaTile extends StatelessWidget {
  final Album album;
  final MediaItem item;
  final bool isSelected;

  /// True while ANY tile is selected. Drives the empty ring on unselected
  /// tiles - without it, selection mode is invisible on every square the user
  /// has not touched yet.
  final bool selectionMode;

  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const MediaTile({
    super.key,
    required this.album,
    required this.item,
    required this.isSelected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final duration = context.motion(const Duration(milliseconds: 140));

    // One scrim under both bottom-edge badges rather than a small pad behind
    // each: two overlapping gradients on the same corner read as a smudge.
    final needsScrim = item.isVideo || item.hasCaption;

    return Semantics(
      container: true,
      image: true,
      button: true,
      selected: isSelected,
      // A caption, when it exists, IS the alt text - that is what captions are
      // for. Only fall back to the media kind when there is nothing to read.
      label: item.caption.isNotEmpty
          ? item.caption
          : (item.isVideo ? 'Video' : 'Photo'),
      onTap: onTap,
      onLongPress: onLongPress,
      // Excluded so the "Cover" chip's own text can't be appended to a
      // caption a user wrote, and so the tile stays a single focus stop.
      child: ExcludeSemantics(
        child: GestureDetector(
          // The WHOLE tile toggles: the check badge is 22dp and carries no
          // gesture of its own, because a badge-sized hit target in a 3-up grid
          // is a miss waiting to happen.
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          onLongPress: onLongPress,
          child: AnimatedContainer(
            duration: duration,
            curve: Curves.easeOut,
            // The colour revealed by the inset. Matching the darkest surface
            // rather than the grid gutter keeps the gap reading as a shadow
            // under the lifted photo instead of a white border around it.
            color: scheme.surfaceContainerLowest,
            padding: EdgeInsets.all(isSelected ? 6 : 0),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Inset plus a scale-down: the photo physically pulls back into
                // the grid, which is why this reads better than a flat colour
                // wash over an otherwise unchanged tile.
                AnimatedScale(
                  scale: isSelected ? 0.88 : 1.0,
                  duration: duration,
                  curve: Curves.easeOut,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Hero(
                        tag: 'media-${album.folder}/${item.name}',
                        child: RemoteMedia(
                          album: album,
                          item: item,
                          decodeWidth: 400,
                        ),
                      ),
                      if (needsScrim)
                        DecoratedBox(
                          decoration: AppTheme.photoScrim(stop: 0.62),
                        ),
                      if (album.isCover(item))
                        const Positioned(top: 5, left: 5, child: _CoverChip()),
                      if (item.isVideo)
                        const Positioned(
                          left: 5,
                          bottom: 5,
                          child: VideoBadge(size: 22),
                        ),
                      // Which items are annotated, visible without opening any
                      // of them.
                      if (item.hasCaption)
                        const Positioned(
                          right: 6,
                          bottom: 6,
                          child: Icon(
                            Icons.notes_rounded,
                            size: 13,
                            color: Colors.white,
                            shadows: AppTheme.photoTextShadow,
                          ),
                        ),
                    ],
                  ),
                ),
                // Outside the scale: the badge is tile chrome, not part of the
                // photograph, so it holds its size and its corner.
                Positioned(
                  top: 6,
                  right: 6,
                  child: AnimatedOpacity(
                    opacity: selectionMode ? 1 : 0,
                    duration: duration,
                    child: _SelectionBadge(
                      selected: isSelected,
                      duration: duration,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The chip on the album's first image.
///
/// The cover is not a separate file - it is simply whichever image sorts
/// first, so it is an ordinary photo in the grid like any other. The chip is
/// the only thing telling the user that this particular one is also the face
/// of the album, and therefore what "Set as cover" on another photo will
/// change.
class _CoverChip extends StatelessWidget {
  const _CoverChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        'Cover',
        style: AppTheme.mono(
          context,
          size: 9,
          weight: FontWeight.w600,
          // The champagne from the DARK palette in both themes: the pill is
          // black-45 over a photo, so this is always a dark context, and the
          // light palette's deep brown computes to under 3:1 on it.
          color: AppColors.dark.coverBadge,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// Check badge, top-right.
///
/// A white ring around a filled circle, so it survives both a white sky and a
/// black night shot - the two photos that break every single-colour badge.
class _SelectionBadge extends StatelessWidget {
  final bool selected;
  final Duration duration;

  const _SelectionBadge({required this.selected, required this.duration});

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;

    return AnimatedContainer(
      duration: duration,
      curve: Curves.easeOut,
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: selected ? scheme.primary : Colors.black.withValues(alpha: 0.28),
        shape: BoxShape.circle,
        border: const Border.fromBorderSide(
          BorderSide(color: Colors.white, width: 2),
        ),
      ),
      child: AnimatedOpacity(
        opacity: selected ? 1 : 0,
        duration: duration,
        // onPrimary, not a literal white: the dark theme's primary is a pale
        // rose, and a white tick on it computes below 2:1. onPrimary is the
        // near-white in the light theme and the plum ink in the dark one.
        child: Icon(Icons.check_rounded, size: 13, color: scheme.onPrimary),
      ),
    );
  }
}

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import '../platform.dart';
import '../services/desktop_media.dart';

/// Drops enter the same selection and review flow as the folder picker.
class DesktopPhotoDropTarget extends StatefulWidget {
  final Widget child;
  final bool enabled;
  final String label;
  final Future<void> Function(List<AssetEntity>) onPhotos;

  const DesktopPhotoDropTarget({
    super.key,
    required this.child,
    required this.onPhotos,
    this.enabled = true,
    this.label = 'Drop photos to choose an album',
  });

  @override
  State<DesktopPhotoDropTarget> createState() => _DesktopPhotoDropTargetState();
}

class _DesktopPhotoDropTargetState extends State<DesktopPhotoDropTarget> {
  bool _hovering = false;
  bool _opening = false;
  bool get _active =>
      widget.enabled &&
      !_opening &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  Future<void> _drop(DropDoneDetails details) async {
    if (!_active) return;
    setState(() {
      _hovering = false;
      _opening = true;
    });
    try {
      final assets = await droppedPhotoAssets(details.files.map((f) => f.path));
      if (!mounted) return;
      if (assets.length < details.files.length) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              assets.isEmpty
                  ? 'Drop $photoFormats photo files.'
                  : 'Added ${assets.length} photos. Other files were skipped.',
            ),
          ),
        );
      }
      if (assets.isNotEmpty) await widget.onPhotos(assets);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not read these photos. Try choosing their folder.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!isDesktop) return widget.child;
    final active = _active;
    return DropTarget(
      enable: active,
      onDragEntered: (_) {
        if (_active) setState(() => _hovering = true);
      },
      onDragExited: (_) => setState(() => _hovering = false),
      onDragDone: _drop,
      child: Stack(
        children: [
          widget.child,
          if (_hovering && active)
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: Theme.of(
                    context,
                  ).colorScheme.surface.withValues(alpha: 0.94),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.add_photo_alternate_outlined,
                          size: 56,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          widget.label,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        const Text('Review before uploading'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

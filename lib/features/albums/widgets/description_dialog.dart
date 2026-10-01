import 'package:flutter/material.dart';

import '../../../core/models/album.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/album_conventions.dart';

/// Edit [album]'s summary and note together.
///
/// Resolves to the new pair, or null when cancelled or nothing changed: every
/// save is a real commit, and a site build.
Future<({String summary, String note})?> showDescriptionDialog(
  BuildContext context,
  Album album,
) {
  return showDialog<({String summary, String note})>(
    context: context,
    builder: (_) => _DescriptionDialog(album: album),
  );
}

class _DescriptionDialog extends StatefulWidget {
  final Album album;

  const _DescriptionDialog({required this.album});

  @override
  State<_DescriptionDialog> createState() => _DescriptionDialogState();
}

class _DescriptionDialogState extends State<_DescriptionDialog> {
  late final TextEditingController _summary = TextEditingController(
    text: widget.album.summary,
  );
  late final TextEditingController _note = TextEditingController(
    text: widget.album.note,
  );

  @override
  void dispose() {
    _summary.dispose();
    _note.dispose();
    super.dispose();
  }

  void _save() {
    final summary = _summary.text.trim();
    final note = _note.text.trim();
    final changed =
        summary != widget.album.summary || note != widget.album.note;
    Navigator.of(context).pop(changed ? (summary: summary, note: note) : null);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Description', style: context.textTheme.titleLarge),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _summary,
              autofocus: true,
              maxLength: kSummaryMaxLength,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Summary',
                hintText: 'Malaysia trip with friends',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _note,
              minLines: 3,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Note',
                hintText: 'Optional - who came, what happened',
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'The summary shows on your album list and under the title. The '
              'note is markdown, saved as album.md and shown above the photos.',
              style: context.textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/external_url.dart';

const String _repoUrl = 'https://github.com/ganeshapp/glickr';
const String _issuesUrl = '$_repoUrl/issues';

/// The colophon: what glickr is, the folder convention it writes, and the
/// things it cannot do.
///
/// The limitations list is deliberately long and unhedged. Every entry on it
/// is something a user would otherwise discover from their own website being
/// wrong, which is a much worse place to learn it.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('about')),
      body: DecoratedBox(
        decoration: AppTheme.backgroundGradient(context),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 48),
          children: [
            const _Wordmark(),
            const SizedBox(height: 40),

            const _SectionLabel('What it does'),
            const _Paragraph(
              'glickr manages photo albums stored as folders in a GitHub repo, '
              'so a Jekyll site can render them.',
            ),
            const _Paragraph(
              "Your photos stay in your own repo - glickr just writes to it "
              "through GitHub's API, so your phone never has to clone "
              'anything.',
            ),

            const _SectionLabel('How your albums are stored'),
            const _Paragraph(
              'One folder per album, exactly one level deep. Your site only '
              'looks at files directly inside an album folder, so nothing is '
              'ever nested any further.',
            ),
            const _PathNote(
              path: '<album_folder>/0001.jpg',
              note:
                  'Your photos and videos. glickr numbers them in a single '
                  'sequence in the order you uploaded them, four digits wide, '
                  'and your site sorts by filename.',
            ),
            const _PathNote(
              path: '<album_folder>/0.jpg',
              note:
                  'The cover. Your site leaves it out of the gallery grid; '
                  'glickr shows it with a "Cover" chip, because a file you '
                  'uploaded that then disappears reads as data loss.',
            ),
            const _PathNote(
              path: '<album_folder>/album.md',
              note: 'The album description, as plain markdown.',
            ),
            const _PathNote(
              path: '<album_folder>/album.json',
              note: 'Per-item captions, keyed by filename.',
            ),
            const _Paragraph(
              'None of that is a glickr format - it is just what your site '
              'already reads. You can edit any of it by hand, and glickr picks '
              'up the change the next time it syncs.',
            ),

            const _SectionLabel('Limitations'),
            const _Bullet('Android only.'),
            const _Bullet(
              "Album repos have to be public. The CDN that serves your site "
              "can't read private repositories, so anything you upload is "
              'publicly readable by URL.',
            ),
            const _Bullet(
              "Photos appear in the order you uploaded them. There's no manual "
              'reordering, because your site sorts by filename.',
            ),
            const _Bullet(
              'Adding photos to an album that has older, differently-named '
              'files will place the new ones first, not last.',
            ),
            const _Bullet(
              'Renaming an album changes its web address and breaks old links.',
            ),
            const _Bullet(
              'Videos are re-encoded to MP4 and capped at 18 MB each.',
            ),
            const _Bullet(
              'Your whole repo needs to stay under 50 MB, or the CDN stops '
              'serving it.',
            ),
            const _Bullet(
              'Captions are written to album.json, but showing them on your '
              'site needs a small plugin change.',
            ),
            const _Bullet(
              "Keep glickr open while an upload is running. If it's "
              'interrupted it resumes on its own next time you open the app.',
            ),

            const _SectionLabel('Privacy'),
            const _Paragraph(
              'Location and camera EXIF are stripped from every photo before '
              'upload. Git history keeps whatever it is given forever, so this '
              'happens on the way out rather than being something to clean up '
              'later.',
            ),
            const _Paragraph(
              'glickr talks only to github.com and the CDN that serves your '
              'site. There is no analytics and no server of its own.',
            ),

            const SizedBox(height: 28),
            const _LinkRow(
              icon: Icons.code_rounded,
              label: 'Source on GitHub',
              url: _repoUrl,
            ),
            const _LinkRow(
              icon: Icons.bug_report_outlined,
              label: 'Report an issue',
              url: _issuesUrl,
            ),

            const SizedBox(height: 28),
            Text(
              'Released under the MIT licence.',
              style: context.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// Mark, wordmark, tagline and version - the same lockup as the login screen,
/// so arriving here from settings still feels like the app that signed you in.
class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Image.asset(
          'assets/brand/glickr_mark.png',
          width: 88,
          // The wordmark right below says the name; a screen reader announcing
          // it twice is noise.
          excludeFromSemantics: true,
        ),
        Text(
          'glickr',
          style: AppTheme.mono(
            context,
            size: 32,
            weight: FontWeight.w700,
            letterSpacing: -1.5,
            color: context.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 6),
        Text('albums, versioned.', style: context.textTheme.bodyMedium),
        const SizedBox(height: 10),
        const _Version(),
      ],
    );
  }
}

class _Version extends StatefulWidget {
  const _Version();

  @override
  State<_Version> createState() => _VersionState();
}

class _VersionState extends State<_Version> {
  /// Held in a field rather than created in build: PackageInfo.fromPlatform is
  /// a platform-channel call, and a fresh future per rebuild would flicker the
  /// line back to blank.
  late final Future<PackageInfo> _info = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: _info,
      builder: (context, snapshot) {
        final info = snapshot.data;
        return Text(
          info == null ? '' : 'Version ${info.version} (${info.buildNumber})',
          style: AppTheme.mono(context, size: 12),
        );
      },
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 30, 0, 10),
      child: Text(
        text.toUpperCase(),
        style: context.textTheme.labelSmall?.copyWith(
          fontSize: 11,
          letterSpacing: 1.4,
          color: context.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _Paragraph extends StatelessWidget {
  final String text;
  const _Paragraph(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(text, style: context.textTheme.bodyMedium),
    );
  }
}

/// One repo path and what lives at it. The path is set in the same monospace
/// face the rest of the app uses for repo data, so someone reading this can go
/// and type it into their own repository.
class _PathNote extends StatelessWidget {
  final String path;
  final String note;

  const _PathNote({required this.path, required this.note});

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: scheme.surfaceContainer,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.outline.withValues(alpha: 0.35)),
            ),
            child: Text(
              path,
              style: AppTheme.mono(
                context,
                size: 12.5,
                color: scheme.onSurface,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(note, style: context.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  final String text;
  const _Bullet(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            // Nudged down onto the first line's baseline; a dot centred on the
            // row floats above the text at these line heights.
            padding: const EdgeInsets.only(top: 7, right: 10),
            child: Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                color: context.colorScheme.primary,
                shape: BoxShape.circle,
              ),
            ),
          ),
          Expanded(child: Text(text, style: context.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String url;

  const _LinkRow({required this.icon, required this.label, required this.url});

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;

    return InkWell(
      onTap: () => openExternalUrl(context, url),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: scheme.primary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: context.textTheme.labelLarge?.copyWith(
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(url, style: AppTheme.mono(context, size: 11.5)),
                ],
              ),
            ),
            Icon(
              Icons.open_in_new_rounded,
              size: 16,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/external_url.dart';

/// glickr's OWN repository - never the album repo the user configured.
///
/// Hardcoded on purpose. An earlier version of this screen built the link from
/// `config.repoSlug`, so "source on GitHub" opened whichever site repo happened
/// to be selected and the app appeared to be authored by whoever owned it.
const String _repoUrl = 'https://github.com/ganeshapp/glickr';
const String _issuesUrl = '$_repoUrl/issues';
const String _privacyUrl = '$_repoUrl/blob/main/PRIVACY.md';
const String _creatorUrl = 'https://www.gapp.in';

/// The colophon: what glickr is, why it exists, the folder convention it
/// writes, the things it cannot do, and who made it.
///
/// The limitations list is deliberately long and unhedged. Every entry on it is
/// something a user would otherwise discover from their own website being
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
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 48),
          children: const [
            _Wordmark(),
            SizedBox(height: 34),

            _Section(
              icon: Icons.info_outline_rounded,
              title: 'What it is',
              children: [
                _Paragraph(
                  'glickr manages photo albums stored as folders in a GitHub '
                  'repo, so a Jekyll site can render them.',
                ),
                _Paragraph(
                  "Your photos stay in your own repo - glickr writes to it "
                  "through GitHub's API, so your device never has to clone "
                  'anything.',
                ),
              ],
            ),
            SizedBox(height: 16),

            _Section(
              icon: Icons.lightbulb_outline_rounded,
              title: 'Why it exists',
              children: [
                _Paragraph(
                  'Putting an album on your own site normally means getting the '
                  'photos onto a laptop, resizing them, stripping the location '
                  'data, numbering them by hand and pushing a commit. That is '
                  'enough steps that the album never gets posted.',
                ),
                _Paragraph(
                  'glickr does all of it from the device the photos are '
                  'already on, and leaves the result as ordinary files you can '
                  'edit without it.',
                ),
              ],
            ),
            SizedBox(height: 16),

            _Section(
              icon: Icons.play_circle_outline_rounded,
              title: 'How to use it',
              children: [
                _Paragraph(
                  'Sign in with GitHub, pick the repo your site builds from, '
                  'and point glickr at the folder your albums live in.',
                ),
                _Paragraph(
                  'Then create an album and pick photos and videos in the order '
                  'you want them. glickr resizes them, strips their EXIF, '
                  'numbers them and commits the whole batch at once - your site '
                  'rebuilds from that commit.',
                ),
              ],
            ),
            SizedBox(height: 16),

            _Section(
              icon: Icons.folder_outlined,
              title: 'How your albums are stored',
              children: [
                _Paragraph(
                  'One folder per album, exactly one level deep. Your site only '
                  'looks at files directly inside an album folder, so nothing '
                  'is ever nested any further.',
                ),
                _PathNote(
                  path: '<album_folder>/0001.jpg',
                  note:
                      'Your photos and videos. glickr numbers them in a single '
                      'sequence in the order you uploaded them, four digits '
                      'wide, and your site sorts by filename.',
                ),
                _PathNote(
                  path: '<album_folder>/album.json',
                  note:
                      'A one-line summary, shown on your album list and under '
                      'the title. Per-item captions, keyed by filename, plus '
                      'the highest number the album has ever used so a deleted '
                      'photo can never hand its caption to a later one.',
                ),
                _PathNote(
                  path: '<album_folder>/album.md',
                  note:
                      'An optional longer note, in markdown, shown only on the '
                      'album page above the photos.',
                ),
                _Paragraph(
                  'There is no separate cover file. The cover is simply the '
                  'first image in the folder, so "Set as cover" swaps that '
                  'photo with the current first one - two files change and '
                  'every other photo keeps its URL.',
                ),
                _Paragraph(
                  'Caption edits are staged on this device and committed '
                  'together when you save, so captioning a whole album is one '
                  'commit rather than one per photo.',
                ),
                _Paragraph(
                  'None of that is a glickr format - it is just what your site '
                  'already reads. You can edit any of it by hand, and glickr '
                  'picks up the change the next time it syncs.',
                ),
              ],
            ),
            SizedBox(height: 16),

            _Section(
              icon: Icons.warning_amber_rounded,
              title: 'Limitations',
              children: [
                _Bullet(
                  'No iOS or Windows build. On macOS and Linux, uploads are '
                  'photos only - use the phone for videos.',
                ),
                _Bullet(
                  'Album repos have to be public. Media is fetched straight '
                  "from raw.githubusercontent.com, which won't serve a private "
                  'repo without a token - so anything you upload is readable by '
                  'anyone with the link.',
                ),
                _Bullet(
                  "Photos appear in the order you uploaded them. There's no "
                  'manual reordering, because your site sorts by filename.',
                ),
                _Bullet(
                  'Adding photos to an album that has older, differently-named '
                  'files will place the new ones first, not last.',
                ),
                _Bullet(
                  'Renaming an album changes its web address and breaks old '
                  'links.',
                ),
                _Bullet(
                  'Videos are re-encoded to MP4 and capped at 40 MB each.',
                ),
                _Bullet(
                  'Your whole repo has to stay under 1 GB, which is what GitHub '
                  'Pages allows. Git keeps every version of every photo, so '
                  'deleting an album does not give the space back.',
                ),
                _Bullet(
                  'Captions are written to album.json, but showing them on your '
                  'site needs a small plugin change.',
                ),
                _Bullet(
                  "Keep glickr open while an upload is running. If it's "
                  'interrupted it resumes on its own next time you open the '
                  'app.',
                ),
              ],
            ),
            SizedBox(height: 16),

            _Section(
              icon: Icons.privacy_tip_outlined,
              title: 'Privacy',
              actions: [_SectionAction('Read privacy policy', _privacyUrl)],
              children: [
                _Paragraph(
                  'Location and camera metadata are stripped from every photo '
                  'and video before upload. Git history keeps whatever it is '
                  'given forever, so this happens on the way out rather than '
                  'being something to clean up later.',
                ),
                _Paragraph(
                  'glickr talks only to github.com and '
                  'raw.githubusercontent.com. There is no glickr server, no '
                  'analytics and no account - your GitHub token stays in '
                  "this device's secure storage (Android keystore, macOS "
                  'keychain or Linux keyring).',
                ),
              ],
            ),
            SizedBox(height: 16),

            _Section(
              icon: Icons.code_rounded,
              title: 'Open source',
              actions: [
                _SectionAction('View on GitHub', _repoUrl),
                _SectionAction('Report an issue', _issuesUrl),
              ],
              children: [
                _Paragraph(
                  'glickr is MIT-licensed and developed in the open. The album '
                  "rules it follows are a port of the site's own generator, so "
                  'if your site changes how it reads albums, you can change the '
                  'app to match.',
                ),
              ],
            ),
            SizedBox(height: 28),

            _CreatorCard(),
            SizedBox(height: 28),

            _Licence(),
          ],
        ),
      ),
    );
  }
}

/// Mark, wordmark, tagline and version - the same lockup as the login screen,
/// so arriving here from the album list still feels like the app that signed
/// you in.
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

/// A labelled link rendered as a full-width button at the foot of a section.
/// Carries a URL rather than a callback so the whole screen stays const.
class _SectionAction {
  final String label;
  final String url;

  const _SectionAction(this.label, this.url);
}

/// One titled card: icon chip, heading, body, and any links it offers.
class _Section extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<Widget> children;
  final List<_SectionAction> actions;

  const _Section({
    required this.icon,
    required this.title,
    required this.children,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  // Decorative tint only - the icon itself carries full-strength
                  // primary against the card, and the heading says the same
                  // thing in words.
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 18, color: scheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(title, style: context.textTheme.titleMedium),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ...children,
          for (final action in actions) ...[
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => openExternalUrl(context, action.url),
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: Text(action.label),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
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
              color: scheme.surfaceContainerHigh,
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

/// Who made the app, and where to find them. Deliberately not derived from the
/// signed-in GitHub account or the configured repo: this is authorship, not
/// session state.
class _CreatorCard extends StatelessWidget {
  const _CreatorCard();

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;

    return Semantics(
      button: true,
      label: 'Made by Gapp - opens www.gapp.in',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: () => openExternalUrl(context, _creatorUrl),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              // Flat surface rather than a primary-tinted gradient: the link
              // line below is set in `primary`, and primary on primaryContainer
              // is under 4.5:1 in both themes.
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: scheme.primary.withValues(alpha: 0.35)),
            ),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Center(
                    child: Text(
                      'G',
                      style: AppTheme.mono(
                        context,
                        size: 26,
                        weight: FontWeight.w700,
                        color: scheme.onPrimary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Made by', style: context.textTheme.bodySmall),
                      const SizedBox(height: 2),
                      Text('Gapp', style: context.textTheme.titleLarge),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.language_rounded,
                            size: 14,
                            color: scheme.primary,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'www.gapp.in',
                            style: AppTheme.mono(
                              context,
                              size: 12.5,
                              color: scheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Licence extends StatelessWidget {
  const _Licence();

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: context.appColors.info.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.gavel_rounded,
                  size: 18,
                  color: context.appColors.info,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'MIT licence',
                  style: context.textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Copyright (c) 2026 Ganesh Attangudi Perichiappan Perichappan\n\n'
            'Permission is hereby granted, free of charge, to any person '
            'obtaining a copy of this software and associated documentation '
            'files, to deal in the Software without restriction, including '
            'without limitation the rights to use, copy, modify, merge, '
            'publish, distribute, sublicense, and/or sell copies of the '
            'Software.',
            // Full-strength variant colour rather than a dimmed one: this is
            // the smallest type on the screen and has the least contrast to
            // spare.
            style: AppTheme.mono(context, size: 11.5),
          ),
        ],
      ),
    );
  }
}

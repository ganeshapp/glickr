import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../core/models/app_config.dart';
import '../../../core/providers/albums_provider.dart';
import '../../../core/providers/auth_provider.dart';
import '../../../core/providers/config_provider.dart';
import '../../../core/providers/services_provider.dart';
import '../../../core/providers/theme_provider.dart';
import '../../../core/providers/upload_provider.dart';
import '../../../core/services/media_pipeline_service.dart'
    show MediaPipelineService, formatBytes;
import '../../../core/theme/app_theme.dart';
import '../../config/presentation/folder_browser_screen.dart';
import '../../config/presentation/repo_setup_screen.dart';
import 'about_screen.dart';

/// A representative 12 MP 4:3 phone photo, used only to turn a preset into a
/// number the user can weigh against the repo's 50 MB ceiling. Fixed rather
/// than sampled from the gallery so the three options stay comparable.
const int _samplePhotoWidth = 4032;
const int _samplePhotoHeight = 3024;

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  /// Re-run by hand after a clear rather than watched: the cache is a
  /// directory on disk that nothing notifies us about, so this figure is only
  /// ever as fresh as the last walk of it.
  late Future<int> _cacheSize;

  /// Held in a field so a rebuild - every switch flip is one - does not start
  /// another platform-channel round trip and flash the row back to blank.
  late final Future<PackageInfo> _packageInfo;

  bool _clearingCache = false;
  bool _signingOut = false;

  @override
  void initState() {
    super.initState();
    _cacheSize = ref.read(mediaCacheServiceProvider).cacheSizeBytes();
    _packageInfo = PackageInfo.fromPlatform();
  }

  // --------------------------------------------------------------- actions

  Future<void> _signOut() async {
    if (_signingOut) return;
    final confirmed = await _confirm(
      title: 'Sign out?',
      body: 'This removes your token and clears every cached album and '
          'thumbnail from this device.',
      confirmLabel: 'Sign out',
    );
    if (!confirmed || !mounted) return;

    setState(() => _signingOut = true);
    // Order matters. The queue goes first because a pending batch carries its
    // own bytes and its own target folder, and the token is dropped last so
    // every step above still has one if it needs to reach GitHub.
    await ref.read(uploadQueueNotifierProvider.notifier).clear();
    await ref.read(albumsNotifierProvider.notifier).clearCache();
    await ref.read(mediaCacheServiceProvider).clear();
    await ref.read(authNotifierProvider.notifier).logout();

    if (!mounted) return;
    setState(() => _signingOut = false);
    // The AuthWrapper swaps the root route out on its own, but this screen was
    // pushed on top of it and would otherwise sit there over the login page.
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _clearCache() async {
    if (_clearingCache) return;
    final confirmed = await _confirm(
      title: 'Clear cached media?',
      body: 'Photos will download again the next time you open an album. '
          "Your albums on GitHub aren't touched.",
      confirmLabel: 'Clear',
    );
    if (!confirmed || !mounted) return;

    setState(() => _clearingCache = true);
    await ref.read(mediaCacheServiceProvider).clear();
    if (!mounted) return;
    setState(() {
      _clearingCache = false;
      _cacheSize = ref.read(mediaCacheServiceProvider).cacheSizeBytes();
    });
  }

  Future<void> _editSiteUrl(AppConfig config) async {
    final controller = TextEditingController(text: config.siteUrl);
    try {
      final value = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Site URL'),
          // Scrollable because the keyboard is up the whole time this dialog
          // is open, and in landscape that leaves it barely taller than the
          // field itself.
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  style: AppTheme.mono(
                    context,
                    color: context.colorScheme.onSurface,
                  ),
                  decoration: const InputDecoration(
                    hintText: 'https://example.com',
                  ),
                  onSubmitted: (text) =>
                      Navigator.of(dialogContext).pop(text.trim()),
                ),
                const SizedBox(height: 14),
                Text(
                  "Where 'View on web' sends you. Leave it empty and glickr "
                  'hides that action rather than offering a link that 404s.',
                  style: context.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.of(dialogContext).pop(controller.text.trim()),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (value == null) return;
      await ref
          .read(configNotifierProvider.notifier)
          .update((c) => c.copyWith(siteUrl: value));
    } finally {
      controller.dispose();
    }
  }

  /// Move which repo directory glickr reads albums from.
  ///
  /// The browser opens first and the confirmation comes after: asking "are you
  /// sure?" before the user has picked anything is a question about nothing,
  /// and the cost is only real once there is a folder to name.
  Future<void> _pickAlbumFolder(AppConfig config) async {
    final picked = await showFolderBrowser(
      context,
      owner: config.repoOwner,
      repo: config.repoName,
      branch: config.branch,
      initialPath: config.albumRoot,
    );
    if (picked == null || !mounted || picked == config.albumRoot) return;

    final confirmed = await _confirm(
      title: 'Change albums folder?',
      body: 'glickr will look for albums in the new folder. Cached albums '
          'from the old one are cleared.',
      confirmLabel: 'Change',
    );
    if (!confirmed || !mounted) return;

    await ref
        .read(configNotifierProvider.notifier)
        .update((c) => c.copyWith(albumRoot: picked));
    // Every cached album is keyed to the old folder, so the grid would keep
    // showing albums that are not in the new one until something else forced a
    // sync.
    await ref.read(albumsNotifierProvider.notifier).clearCache();
    await ref.read(albumsNotifierProvider.notifier).refresh();
  }

  Future<void> _pickQuality(AppConfig config) async {
    final chosen = await showModalBottomSheet<QualityPreset>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sheetTitle('Default quality'),
            for (final preset in QualityPreset.values)
              RadioListTile<QualityPreset>(
                value: preset,
                groupValue: config.quality,
                title: Text(preset.label),
                subtitle: Text(_qualityDetail(preset)),
                onChanged: (value) => Navigator.of(sheetContext).pop(value),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 20),
              child: Text(
                'This is the default. You can still change quality for a '
                'single upload.',
                style: context.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
    if (chosen == null || chosen == config.quality) return;
    await ref
        .read(configNotifierProvider.notifier)
        .update((c) => c.copyWith(quality: chosen));
  }

  Future<void> _pickTheme(ThemeMode current) async {
    final chosen = await showModalBottomSheet<ThemeMode>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sheetTitle('Theme'),
            for (final mode in ThemeMode.values)
              RadioListTile<ThemeMode>(
                value: mode,
                groupValue: current,
                title: Text(_themeLabel(mode)),
                onChanged: (value) => Navigator.of(sheetContext).pop(value),
              ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
    if (chosen == null || chosen == current) return;
    await ref.read(themeModeNotifierProvider.notifier).setMode(chosen);
  }

  Future<bool> _confirm({
    required String title,
    required String body,
    required String confirmLabel,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// The three numbers that actually differ between presets, in the order
  /// someone weighs them: how much of a photo survives, how big a video gets,
  /// and what that costs against the repo's 50 MB ceiling.
  String _qualityDetail(QualityPreset preset) {
    final spec = MediaPipelineService.specFor(preset);
    // Routed through the pipeline's own projection rather than restated here,
    // so this number cannot drift away from what the uploader really produces.
    final perPhoto = ref
        .read(mediaPipelineServiceProvider)
        .projectedPhotoBytes(
          width: _samplePhotoWidth,
          height: _samplePhotoHeight,
          preset: preset,
        );
    return '${spec.imageMaxEdge} px long edge · ${spec.videoLabel} video · '
        'about ${formatBytes(perPhoto)} a photo';
  }

  String _themeLabel(ThemeMode mode) => switch (mode) {
    ThemeMode.system => 'System default',
    ThemeMode.light => 'Light',
    ThemeMode.dark => 'Dark',
  };

  // -------------------------------------------------------------------- ui

  @override
  Widget build(BuildContext context) {
    final config = ref.watch(configNotifierProvider);
    final auth = ref.watch(authNotifierProvider);
    final themeMode = ref.watch(themeModeNotifierProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('settings')),
      body: DecoratedBox(
        decoration: AppTheme.backgroundGradient(context),
        child: ListView(
          // Deep bottom padding so the last row can still be read and tapped
          // with the upload tray docked over this screen.
          padding: const EdgeInsets.only(bottom: 120),
          children: [
            _sectionLabel('Account'),
            _accountTile(auth),

            _sectionLabel('Repository'),
            _repositoryTile(config),
            // Everything below the repo row describes a repo, so with none
            // configured these rows would be settings for nothing.
            if (config != null) ...[
              _albumFolderTile(config),
              _siteUrlTile(config),
              _sectionLabel('Uploads'),
              _qualityTile(config),
              _wifiTile(config),
            ],

            _sectionLabel('Storage'),
            _cacheTile(),

            _sectionLabel('Appearance'),
            ListTile(
              leading: const Icon(Icons.contrast_rounded),
              title: const Text('Theme'),
              trailing: Text(
                _themeLabel(themeMode),
                style: context.textTheme.bodyMedium,
              ),
              onTap: () => _pickTheme(themeMode),
            ),

            _sectionLabel('About'),
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: const Text('About glickr'),
              subtitle: const Text('What it does, and what it cannot do.'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const AboutScreen()),
              ),
            ),
            _versionTile(),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 26, 20, 6),
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

  Widget _sheetTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 6),
      child: Text(text, style: context.textTheme.titleLarge),
    );
  }

  Widget _accountTile(AuthState auth) {
    // AuthOfflineAuthenticated carries no user: the stored token is fine but
    // GitHub was unreachable at launch, so there is no login or avatar to show
    // and inventing one would misreport who is signed in.
    final user = switch (auth) {
      AuthAuthenticated(user: final user) => user,
      _ => null,
    };
    final scheme = context.colorScheme;

    return ListTile(
      leading: CircleAvatar(
        radius: 20,
        backgroundColor: scheme.surfaceContainerHigh,
        foregroundImage: user == null ? null : NetworkImage(user.avatarUrl),
        // Without a handler a failed avatar fetch escalates to the framework's
        // error reporter; the CircleAvatar's child is already the fallback.
        onForegroundImageError: user == null ? null : (_, _) {},
        child: Icon(Icons.person_rounded, color: scheme.onSurfaceVariant),
      ),
      title: Text(
        user == null ? 'Signed in' : '@${user.login}',
        style: AppTheme.mono(
          context,
          size: 15,
          weight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
      subtitle: user == null
          ? const Text(
              "glickr couldn't reach GitHub, so your account details aren't "
              'loaded.',
            )
          : (user.name == null ? null : Text(user.name!)),
      trailing: _signingOut
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(onPressed: _signOut, child: const Text('Sign out')),
    );
  }

  Widget _repositoryTile(AppConfig? config) {
    return ListTile(
      leading: const Icon(Icons.inventory_2_outlined),
      title: Text(
        config?.repoSlug ?? 'Not set',
        style: AppTheme.mono(
          context,
          size: 14,
          weight: FontWeight.w600,
          color: context.colorScheme.onSurface,
        ),
      ),
      subtitle: Text(
        config == null
            ? 'Pick the repo your albums live in.'
            : 'Branch ${config.branch}',
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const RepoSetupScreen(isOnboarding: false),
        ),
      ),
    );
  }

  Widget _albumFolderTile(AppConfig config) {
    return ListTile(
      leading: const Icon(Icons.folder_open_rounded),
      title: const Text('Albums folder'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            config.albumRootLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTheme.mono(context, size: 12.5),
          ),
          const SizedBox(height: 2),
          Text(
            'The directory in the repo that albums live in.',
            style: context.textTheme.bodySmall,
          ),
        ],
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => _pickAlbumFolder(config),
    );
  }

  Widget _siteUrlTile(AppConfig config) {
    final url = config.siteUrl;
    return ListTile(
      leading: const Icon(Icons.public_rounded),
      title: const Text('Site URL'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            url.isEmpty ? 'Not set' : url,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: url.isEmpty
                ? context.textTheme.bodyMedium
                : AppTheme.mono(context, size: 12.5),
          ),
          const SizedBox(height: 2),
          Text("Used by 'View on web'.", style: context.textTheme.bodySmall),
        ],
      ),
      onTap: () => _editSiteUrl(config),
    );
  }

  Widget _qualityTile(AppConfig config) {
    return ListTile(
      leading: const Icon(Icons.tune_rounded),
      title: const Text('Default quality'),
      subtitle: Text(_qualityDetail(config.quality)),
      trailing: Text(config.quality.label, style: context.textTheme.bodyMedium),
      onTap: () => _pickQuality(config),
    );
  }

  Widget _wifiTile(AppConfig config) {
    return SwitchListTile(
      secondary: const Icon(Icons.wifi_rounded),
      title: const Text('Upload only on Wi-Fi'),
      subtitle: const Text(
        'Queued uploads wait for Wi-Fi instead of spending mobile data.',
      ),
      value: config.wifiOnlyUploads,
      onChanged: (value) => ref
          .read(configNotifierProvider.notifier)
          .update((c) => c.copyWith(wifiOnlyUploads: value)),
    );
  }

  Widget _cacheTile() {
    return ListTile(
      leading: const Icon(Icons.sd_storage_outlined),
      title: const Text('Cached media'),
      subtitle: FutureBuilder<int>(
        future: _cacheSize,
        builder: (context, snapshot) {
          // Not "0 B" while the walk is in flight: an empty cache and an
          // unmeasured one are different claims.
          final size = snapshot.data;
          return Text(
            size == null ? 'Measuring...' : formatBytes(size),
            style: AppTheme.mono(context, size: 12.5),
          );
        },
      ),
      trailing: _clearingCache
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(onPressed: _clearCache, child: const Text('Clear')),
    );
  }

  Widget _versionTile() {
    return ListTile(
      leading: const Icon(Icons.numbers_rounded),
      title: const Text('Version'),
      trailing: FutureBuilder<PackageInfo>(
        future: _packageInfo,
        builder: (context, snapshot) {
          final info = snapshot.data;
          return Text(
            info == null ? '' : '${info.version} (${info.buildNumber})',
            style: AppTheme.mono(context, size: 12.5),
          );
        },
      ),
    );
  }
}

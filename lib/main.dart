import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'core/app_navigator.dart';
import 'core/models/album.dart';
import 'core/models/app_config.dart';
import 'core/models/media_item.dart';
import 'core/platform.dart';
import 'core/providers/theme_provider.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/presentation/auth_wrapper.dart';
import 'features/uploads/widgets/upload_tray.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  Hive.init((await appDataDir()).path); // == initFlutter() on Android

  // MediaItem BEFORE Album: Album nests a List<MediaItem>, and registering
  // them the other way round throws "unknown typeId" - but only against a
  // warm cache, never on a fresh install, so it is easy to miss in testing.
  Hive.registerAdapter(AppConfigAdapter());
  Hive.registerAdapter(MediaItemAdapter());
  Hive.registerAdapter(AlbumAdapter());

  await Hive.openBox<AppConfig>('app_config');
  await Hive.openBox<Album>('albums_box');
  await Hive.openBox<Map>('sync_state');
  // Queue records are plain maps with no TypeAdapter on purpose - see
  // UploadQueueService.
  await Hive.openBox<Map>('upload_batches');
  await Hive.openBox<Map>('upload_items');
  await Hive.openBox<String>('app_settings');
  // Caption edits staged but not yet committed, so closing the app with
  // unsaved captions keeps them.
  await Hive.openBox<Map>('pending_captions');

  runApp(const ProviderScope(child: GlickrApp()));
}

class GlickrApp extends ConsumerWidget {
  const GlickrApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeNotifierProvider);

    return MaterialApp(
      title: 'glickr',
      debugShowCheckedModeBanner: false,
      // The tray lives above this Navigator and so cannot reach it through the
      // element tree; see [appNavigatorKey].
      navigatorKey: appNavigatorKey,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      // Desktop: a mouse drag pages the viewer, pulls to refresh and moves
      // sheets, like a finger. Flutter leaves the mouse out by default.
      scrollBehavior:
          isDesktop
              ? const MaterialScrollBehavior().copyWith(
                dragDevices: PointerDeviceKind.values.toSet(),
              )
              : null,
      builder: (context, child) {
        final scheme = Theme.of(context).colorScheme;
        final iconBrightness = scheme.brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: iconBrightness,
            systemNavigationBarColor: scheme.surface,
            systemNavigationBarIconBrightness: iconBrightness,
          ),
          child: RootOverlay(child: child),
        );
      },
      home: const AuthWrapper(),
    );
  }
}

/// The routed app with the upload tray floating above it.
///
/// The tray is mounted ABOVE the Navigator rather than inside a screen, so an
/// upload in progress stays visible while the user moves between albums, opens
/// the viewer, or wanders into settings. Parenting it to a route would make it
/// vanish on the first push - which is exactly when the user most wants to
/// know it is still running.
///
/// Split out of [GlickrApp.build] so a test can pump this exact stacking over
/// a Scaffold with a FAB: the tray sharing a Stack with the whole app is what
/// makes it able to cover things, and that is only testable if the arrangement
/// is a widget rather than a closure.
class RootOverlay extends StatelessWidget {
  /// The `child` MaterialApp's builder was handed: the routed content.
  final Widget? child;

  const RootOverlay({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child ?? const SizedBox.shrink(),
        // Left/right 0 sets the band the tray may use; the tray itself insets
        // and height-limits inside it, and lifts clear of the FAB. Do NOT give
        // it more room than it draws in - it is the last child of the Stack,
        // so anything it occupies it also takes taps from.
        const Positioned(left: 0, right: 0, bottom: 0, child: UploadTray()),
      ],
    );
  }
}

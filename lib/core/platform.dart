import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Platform gates. Read through [defaultTargetPlatform], not dart:io Platform:
/// under `flutter test` it reports android on every host, so the suite keeps
/// testing the phone path on a Linux CI runner; a test opts in with
/// `debugDefaultTargetPlatformOverride`; release builds constant-fold it.
bool get isLinux => defaultTargetPlatform == TargetPlatform.linux;
bool get isMacOS => defaultTargetPlatform == TargetPlatform.macOS;
bool get isDesktop => isLinux || isMacOS;

/// Where the app keeps its own files. Android keeps the documents dir existing
/// installs already use; on desktop that dir is the user's ~/Documents.
Future<Directory> appDataDir() =>
    isDesktop
        ? getApplicationSupportDirectory()
        : getApplicationDocumentsDirectory();

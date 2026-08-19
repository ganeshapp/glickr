import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Launch modes tried in order by [openExternalUrl], most reliable first.
///
/// An in-app browser tab (Custom Tabs on Android) is tried before a full
/// external browser because it needs neither a task switch nor an "Open with"
/// chooser. Devices with more than one browser installed show that chooser for
/// `externalApplication`, and handing off from the chooser can leave the
/// browser's task in the background - the button then looks like it did
/// nothing. Custom Tabs still shares the default browser's cookies and
/// autofill, so GitHub sign-in state carries over, and Back returns here.
const _launchModes = <LaunchMode>[
  LaunchMode.inAppBrowserView,
  LaunchMode.externalApplication,
];

/// Opens [url], degrading gracefully so the caller is never a dead button.
///
/// Falls back through [_launchModes] and finally copies the link to the
/// clipboard, telling the user via a snackbar. Returns true if a browser
/// actually opened.
///
/// Pass `copyOnFailure: false` when the caller shows its own fallback UI,
/// so the user does not get two snackbars.
Future<bool> openExternalUrl(
  BuildContext context,
  String url, {
  bool copyOnFailure = true,
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;

  for (final mode in _launchModes) {
    try {
      if (await launchUrl(uri, mode: mode)) return true;
    } catch (_) {
      // Try the next mode.
    }
  }

  if (!copyOnFailure || !context.mounted) return false;
  await Clipboard.setData(ClipboardData(text: url));
  if (!context.mounted) return false;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('Could not open browser - link copied: $url')),
  );
  return false;
}

/// Fire-and-forget variant for call sites that cannot await (or whose widget
/// may be popped before the launch resolves). Silently ignores failures.
void openExternalUrlUnawaited(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return;

  Future<void> attempt() async {
    for (final mode in _launchModes) {
      try {
        if (await launchUrl(uri, mode: mode)) return;
      } catch (_) {
        // Try the next mode.
      }
    }
  }

  unawaited(attempt());
}

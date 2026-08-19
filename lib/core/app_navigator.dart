import 'package:flutter/widgets.dart';

/// Key for the app's single root [Navigator], handed to `MaterialApp`.
///
/// Needed because of the upload tray. The tray is mounted ABOVE the Navigator
/// (see `main.dart`), so it is a SIBLING of it inside a Stack: `Navigator.of`
/// finds nothing, because the Navigator is not an ancestor, and walking the
/// element tree downward from the tray finds nothing either, because it is not
/// a descendant. A key given to MaterialApp is the only handle that resolves
/// from outside the routed subtree.
///
/// Anything mounted below a route should keep using `Navigator.of(context)`:
/// that respects nested navigators, this deliberately does not.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

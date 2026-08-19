import 'package:flutter/material.dart';

/// The monospace face bundled in pubspec.yaml. Referenced through a constant
/// so a typo can't silently fall back to the platform font - Flutter emits no
/// warning when a `fontFamily` fails to resolve, which is how a sibling app
/// ended up rendering its "monospace" app bars in Roboto for six releases.
const String kMonoFont = 'JetBrains Mono';

/// Semantic colours that don't map onto Material [ColorScheme] roles.
/// Both themes provide a mapping so widgets never hardcode hex values.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  /// Positive state: uploaded, synced, repo verified
  final Color success;

  /// Cautionary state: waiting for a connection, repo nearing its size budget
  final Color warning;

  /// Informational accent: neutral tags and counts
  final Color info;

  /// The chip on the grid tile whose basename is "0". Tertiary-toned so it
  /// reads as "special", not "interactive".
  final Color coverBadge;

  /// Play badge on video tiles, so video is separable from image at a glance
  /// in a dense grid - paired with a glyph, never colour alone.
  final Color videoTint;

  const AppColors({
    required this.success,
    required this.warning,
    required this.info,
    required this.coverBadge,
    required this.videoTint,
  });

  static const dark = AppColors(
    success: Color(0xFF4ADE80), // 11.0:1 on surface
    // Amber, deliberately not the blue primary: a warning that looks identical
    // to every ordinary accent isn't a warning.
    warning: Color(0xFFFBBF24), // 11.5:1
    info: Color(0xFF8E9AAE),
    coverBadge: Color(0xFFC9D4E8),
    videoTint: Color(0xFF8E9AAE),
  );

  static const light = AppColors(
    success: Color(0xFF16803C),
    warning: Color(0xFFB45309),
    info: Color(0xFF4A5464),
    coverBadge: Color(0xFF3F4855),
    videoTint: Color(0xFF4A5464),
  );

  @override
  AppColors copyWith({
    Color? success,
    Color? warning,
    Color? info,
    Color? coverBadge,
    Color? videoTint,
  }) {
    return AppColors(
      success: success ?? this.success,
      warning: warning ?? this.warning,
      info: info ?? this.info,
      coverBadge: coverBadge ?? this.coverBadge,
      videoTint: videoTint ?? this.videoTint,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      info: Color.lerp(info, other.info, t)!,
      coverBadge: Color.lerp(coverBadge, other.coverBadge, t)!,
      videoTint: Color.lerp(videoTint, other.videoTint, t)!,
    );
  }
}

/// Shorthand theme lookups so widgets read `context.colorScheme.primary`
/// instead of `Theme.of(context).colorScheme.primary`.
extension AppThemeContext on BuildContext {
  ColorScheme get colorScheme => Theme.of(this).colorScheme;
  TextTheme get textTheme => Theme.of(this).textTheme;
  AppColors get appColors =>
      Theme.of(this).extension<AppColors>() ?? AppColors.dark;

  /// Collapse a duration to zero when the platform asks for reduced motion.
  ///
  /// Every animated duration in the app routes through this, so "Remove
  /// animations" genuinely removes them instead of leaving the staggered
  /// grid, the shimmer and the hero flights running.
  Duration motion(Duration d) =>
      MediaQuery.disableAnimationsOf(this) ? Duration.zero : d;

  /// True when a screen reader is driving navigation. Used to suppress
  /// velocity-based gestures (drag-to-dismiss) that a screen-reader user
  /// cannot perform, in favour of the explicit control.
  bool get accessibleNavigation => MediaQuery.accessibleNavigationOf(this);
}

class AppTheme {
  // ------------------------------------------------------------- SCHEMES

  /// "Ink": near-neutral surfaces and a single blue accent.
  ///
  /// The surfaces are deliberately almost colourless. Every pixel of chrome in
  /// this app sits next to a photograph, and a tinted surface casts its hue
  /// over the user's own images - which is backwards for an app whose whole
  /// job is showing them. Colour is spent on one accent and nothing else.
  ///
  /// Checked against WCAG 2.x relative luminance: onSurface on surface is
  /// 17.1:1, onPrimary on primary 5.9:1, and the lowest text pair in the
  /// scheme is 5.4:1. See tool/check_contrast.py.
  static const ColorScheme _darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xFF4C8DFF),
    onPrimary: Color(0xFF06121F),
    primaryContainer: Color(0xFF17325C),
    onPrimaryContainer: Color(0xFFDCE8FF),
    secondary: Color(0xFF8E9AAE),
    onSecondary: Color(0xFF0E0F11),
    secondaryContainer: Color(0xFF2A2F38),
    onSecondaryContainer: Color(0xFFE4E8EF),
    tertiary: Color(0xFFB7C2D4),
    onTertiary: Color(0xFF0E0F11),
    error: Color(0xFFFF6B6B),
    // Near-black, not white: white on this red is 2.9:1 and fails AA. This
    // pairing is 6.6:1.
    onError: Color(0xFF2A0A0A),
    surface: Color(0xFF0E0F11),
    onSurface: Color(0xFFF0F2F6),
    onSurfaceVariant: Color(0xFFA9B0BC),
    surfaceContainerLowest: Color(0xFF0A0B0D),
    surfaceContainerLow: Color(0xFF16181C),
    surfaceContainer: Color(0xFF191B1F),
    surfaceContainerHigh: Color(0xFF202329),
    surfaceContainerHighest: Color(0xFF2A2E36),
    // outline is a boundary you are meant to perceive (3.07:1 on surface);
    // outlineVariant is the decorative divider. Collapsing the two into one
    // near-surface value - the usual mistake - makes every card edge invisible.
    outline: Color(0xFF59616E),
    outlineVariant: Color(0xFF2A2E36),
    scrim: Color(0xFF000000),
  );

  /// Light equivalent: white paper, near-black text, the blue primary
  /// darkened to hold 5.5:1 against white.
  static const ColorScheme _lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: Color(0xFF1F63D6),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFD8E4FB),
    onPrimaryContainer: Color(0xFF0B2A5E),
    secondary: Color(0xFF4A5464),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFE2E6EC),
    onSecondaryContainer: Color(0xFF1E242D),
    tertiary: Color(0xFF3F4855),
    onTertiary: Color(0xFFFFFFFF),
    error: Color(0xFFC62828),
    onError: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    onSurface: Color(0xFF14161A),
    onSurfaceVariant: Color(0xFF4A515C),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFF7F8FA),
    surfaceContainer: Color(0xFFF3F4F7),
    surfaceContainerHigh: Color(0xFFECEEF2),
    surfaceContainerHighest: Color(0xFFE1E4EA),
    outline: Color(0xFF8A93A1),
    outlineVariant: Color(0xFFD3D8E0),
    scrim: Color(0xFF000000),
  );

  static ThemeData get darkTheme => _build(_darkScheme, AppColors.dark);
  static ThemeData get lightTheme => _build(_lightScheme, AppColors.light);

  // -------------------------------------------------------------- THEMES

  static TextTheme _textTheme(ColorScheme scheme) {
    return TextTheme(
      displayLarge: TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.w700,
        color: scheme.onSurface,
        letterSpacing: -1,
      ),
      headlineMedium: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
        letterSpacing: -0.5,
      ),
      titleLarge: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: scheme.onSurface,
      ),
      titleSmall: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      bodyLarge: TextStyle(fontSize: 16, color: scheme.onSurface, height: 1.5),
      bodyMedium: TextStyle(
        fontSize: 14,
        color: scheme.onSurfaceVariant,
        height: 1.5,
      ),
      bodySmall: TextStyle(
        fontSize: 12,
        color: scheme.onSurfaceVariant,
        height: 1.4,
      ),
      labelLarge: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      labelMedium: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: scheme.onSurfaceVariant,
      ),
      labelSmall: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: scheme.onSurfaceVariant,
      ),
    );
  }

  /// Monospace style for the data the app is really about: repo paths,
  /// filenames, commit shas, byte counts. Tabular figures keep those columns
  /// from jittering as they update.
  static TextStyle mono(
    BuildContext context, {
    double size = 13,
    FontWeight weight = FontWeight.w400,
    Color? color,
    double letterSpacing = 0,
  }) {
    return TextStyle(
      fontFamily: kMonoFont,
      fontSize: size,
      fontWeight: weight,
      color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
      letterSpacing: letterSpacing,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
  }

  static ThemeData _build(ColorScheme scheme, AppColors colors) {
    final textTheme = _textTheme(scheme);

    return ThemeData(
      useMaterial3: true,
      brightness: scheme.brightness,
      colorScheme: scheme,
      extensions: [colors],
      scaffoldBackgroundColor: scheme.surface,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: scheme.onSurfaceVariant),
        titleTextStyle: TextStyle(
          fontFamily: kMonoFont,
          fontSize: 19,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
          letterSpacing: -0.5,
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainer,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outline.withValues(alpha: 0.4)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        modalBackgroundColor: scheme.surfaceContainerHigh,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: textTheme.labelLarge,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainer,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.outline.withValues(alpha: 0.35)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: scheme.error),
        ),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
        hintStyle: TextStyle(
          color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
          fontSize: 14,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.primary,
          side: BorderSide(color: scheme.primary),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          textStyle: WidgetStatePropertyAll(
            textTheme.labelLarge?.copyWith(fontSize: 13),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.surfaceContainerHighest,
        contentTextStyle: TextStyle(color: scheme.onSurface, fontSize: 14),
        actionTextColor: scheme.primary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainer,
        labelStyle: TextStyle(fontSize: 12.5, color: scheme.onSurface),
        side: BorderSide(color: scheme.outline.withValues(alpha: 0.35)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 2,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.primary,
        textColor: scheme.onSurface,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
        circularTrackColor: scheme.surfaceContainerHighest,
      ),
      iconTheme: IconThemeData(color: scheme.onSurfaceVariant),
    );
  }

  // ----------------------------------------------------------- DECOR

  /// Full-screen gradient background derived from the active scheme.
  static BoxDecoration backgroundGradient(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          scheme.surface,
          scheme.surfaceContainerLowest,
          scheme.surface,
        ],
        stops: const [0.0, 0.5, 1.0],
      ),
    );
  }

  /// The scrim that guarantees white text stays legible over an arbitrary
  /// photograph. Contrast over user content is otherwise undefined - a white
  /// sky and a black night shot are both plausible covers.
  static BoxDecoration photoScrim({double stop = 0.55}) {
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.transparent, Colors.black.withValues(alpha: 0.75)],
        stops: [stop, 1.0],
      ),
    );
  }

  /// Text shadow paired with [photoScrim] for titles laid over photos.
  static const List<Shadow> photoTextShadow = [
    Shadow(color: Colors.black54, blurRadius: 4, offset: Offset(0, 1)),
  ];
}

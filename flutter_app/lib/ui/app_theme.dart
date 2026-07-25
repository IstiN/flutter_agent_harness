import 'package:flutter/material.dart';
import 'package:flutter_chat_core/flutter_chat_core.dart';

/// The demo app's dark palette, mirroring the landing page
/// (`site/styles.css`): near-black background, flat panels with subtle
/// borders, and the indigo → teal brand gradient. Terminal-inspired.
abstract final class FahPalette {
  /// Page background (`--bg`).
  static const Color bg = Color(0xFF070A10);

  /// Secondary background (`#0b0f16`, the demo-frame backdrop).
  static const Color bgAlt = Color(0xFF0B0F16);

  /// Panel/card background (`--panel`).
  static const Color panel = Color(0xFF0D1420);

  /// Raised panel / terminal card top (`--panel-2`).
  static const Color panelAlt = Color(0xFF101928);

  /// Card borders (`--border`).
  static const Color border = Color(0xFF1C2637);

  /// Hover/bright borders (`--border-bright`).
  static const Color borderBright = Color(0xFF2B3A52);

  /// Primary text (`--text`).
  static const Color text = Color(0xFFE8EEF7);

  /// Dimmed text (`--dim`).
  static const Color dim = Color(0xFF93A1B5);

  /// Teal accent (`--accent`): success states, links, prompts.
  static const Color teal = Color(0xFF5EEAD4);

  /// Indigo accent (`--accent-2`): primary actions, tool names.
  static const Color indigo = Color(0xFF818CF8);

  /// Text/icons on top of the brand gradient (`.btn-primary` text).
  static const Color onAccent = Color(0xFF06121A);

  /// Errors (terminal red, lightened for AA contrast on dark panels).
  static const Color error = Color(0xFFFF8A80);

  /// Error banner/snackbar background.
  static const Color errorContainer = Color(0xFF3B1C20);

  /// Pending/warning states (terminal yellow dot).
  static const Color pending = Color(0xFFFEBC2E);

  /// User chat bubble: indigo tint, like the landing's indigo glow.
  static const Color userBubble = Color(0x2E818CF8);

  /// User chat bubble border.
  static const Color userBubbleBorder = Color(0x66818CF8);

  /// Inline-code background (the landing's `code` chip).
  static const Color codeBg = Color(0x1F93A1B5);

  /// Brand gradient (`--grad`: indigo → teal) for key accents.
  static const LinearGradient brandGradient = LinearGradient(
    colors: [indigo, teal],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  /// Monospace stack matching the landing's `--mono`.
  static const List<String> monoFallback = [
    'SF Mono',
    'Menlo',
    'Consolas',
    'Roboto Mono',
    'Courier',
  ];

  /// Monospace text style for terminal-ish content (tool rows, code).
  static TextStyle mono({
    Color color = text,
    double fontSize = 12.5,
    FontWeight? fontWeight,
  }) {
    return TextStyle(
      fontFamily: 'JetBrainsMono',
      fontFamilyFallback: monoFallback,
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
      height: 1.55,
    );
  }
}

/// The light counterpart of [FahPalette]: soft gray page, white panels with
/// subtle borders, the same indigo → teal brand accents darkened to keep AA
/// contrast on light surfaces.
abstract final class FahLightPalette {
  /// Page background.
  static const Color bg = Color(0xFFF2F5FA);

  /// Secondary background (drawers, sunken areas).
  static const Color bgAlt = Color(0xFFFAFBFD);

  /// Panel/card background.
  static const Color panel = Color(0xFFFFFFFF);

  /// Raised panel / input fill.
  static const Color panelAlt = Color(0xFFEEF1F7);

  /// Card borders.
  static const Color border = Color(0xFFDCE2EC);

  /// Hover/bright borders.
  static const Color borderBright = Color(0xFFC2CDDD);

  /// Primary text.
  static const Color text = Color(0xFF18202E);

  /// Dimmed text.
  static const Color dim = Color(0xFF5B6676);

  /// Teal accent, darkened for AA contrast on white.
  static const Color teal = Color(0xFF0F766E);

  /// Indigo accent, darkened for AA contrast on white.
  static const Color indigo = Color(0xFF4F5BC0);

  /// Text/icons on top of the brand gradient.
  static const Color onAccent = Color(0xFFFFFFFF);

  /// Errors (darkened red for AA contrast on light panels).
  static const Color error = Color(0xFFB3261E);

  /// Error banner/snackbar background.
  static const Color errorContainer = Color(0xFFF9DEDC);

  /// Pending/warning states.
  static const Color pending = Color(0xFF9A6E00);

  /// User chat bubble: indigo tint.
  static const Color userBubble = Color(0x1F4F5BC0);

  /// User chat bubble border.
  static const Color userBubbleBorder = Color(0x664F5BC0);

  /// Inline-code background.
  static const Color codeBg = Color(0x145B6676);

  /// Brand gradient (indigo → teal) for key accents.
  static const LinearGradient brandGradient = LinearGradient(
    colors: [indigo, teal],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );

  /// Monospace text style for terminal-ish content (tool rows, code).
  static TextStyle mono({
    Color color = text,
    double fontSize = 12.5,
    FontWeight? fontWeight,
  }) {
    return TextStyle(
      fontFamily: 'JetBrainsMono',
      fontFamilyFallback: FahPalette.monoFallback,
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
      height: 1.55,
    );
  }
}

/// Every per-brightness color the shared theme builder needs. The dark and
/// light themes differ only in these values; the widget-level theme
/// structure is written once in [_buildFahTheme].
final class _FahThemeColors {
  const _FahThemeColors({
    required this.bg,
    required this.bgAlt,
    required this.panel,
    required this.panelAlt,
    required this.border,
    required this.borderBright,
    required this.text,
    required this.dim,
    required this.teal,
    required this.indigo,
    required this.onAccent,
    required this.error,
    required this.errorContainer,
    required this.primaryContainer,
    required this.onPrimaryContainer,
    required this.secondaryContainer,
    required this.onSecondaryContainer,
    required this.onError,
    required this.onErrorContainer,
    required this.surfaceLow,
    required this.surfaceHighest,
    required this.outlineVariant,
    required this.onInverseSurface,
    required this.inversePrimary,
    required this.selection,
    required this.segmentedSelected,
    required this.elevatedBg,
    required this.snackbarBg,
    required this.snackbarText,
    required this.snackbarAction,
    required this.snackbarBorder,
    required this.tooltipBg,
    required this.tooltipText,
    required this.tooltipBorder,
  });

  final Color bg;
  final Color bgAlt;
  final Color panel;
  final Color panelAlt;
  final Color border;
  final Color borderBright;
  final Color text;
  final Color dim;
  final Color teal;
  final Color indigo;
  final Color onAccent;
  final Color error;
  final Color errorContainer;
  final Color primaryContainer;
  final Color onPrimaryContainer;
  final Color secondaryContainer;
  final Color onSecondaryContainer;
  final Color onError;
  final Color onErrorContainer;

  /// `surfaceContainerLow`; doubles as the drawer background.
  final Color surfaceLow;
  final Color surfaceHighest;

  /// Doubles as the disabled input border.
  final Color outlineVariant;
  final Color onInverseSurface;
  final Color inversePrimary;
  final Color selection;
  final Color segmentedSelected;

  /// Elevated-button background.
  final Color elevatedBg;
  final Color snackbarBg;
  final Color snackbarText;
  final Color snackbarAction;
  final Color snackbarBorder;
  final Color tooltipBg;
  final Color tooltipText;
  final Color tooltipBorder;
}

const _darkColors = _FahThemeColors(
  bg: FahPalette.bg,
  bgAlt: FahPalette.bgAlt,
  panel: FahPalette.panel,
  panelAlt: FahPalette.panelAlt,
  border: FahPalette.border,
  borderBright: FahPalette.borderBright,
  text: FahPalette.text,
  dim: FahPalette.dim,
  teal: FahPalette.teal,
  indigo: FahPalette.indigo,
  onAccent: FahPalette.onAccent,
  error: FahPalette.error,
  errorContainer: FahPalette.errorContainer,
  primaryContainer: Color(0xFF232B47),
  onPrimaryContainer: Color(0xFFE0E4FF),
  secondaryContainer: Color(0xFF14332D),
  onSecondaryContainer: Color(0xFFBCFFF3),
  onError: Color(0xFF3A0B06),
  onErrorContainer: Color(0xFFFFDAD4),
  surfaceLow: Color(0xFF0A0F18),
  surfaceHighest: Color(0xFF152033),
  outlineVariant: Color(0xFF141C2B),
  onInverseSurface: Color(0xFF1A2130),
  inversePrimary: Color(0xFF4F5BC0),
  selection: Color(0x55818CF8),
  segmentedSelected: Color(0x33818CF8),
  elevatedBg: FahPalette.panelAlt,
  snackbarBg: FahPalette.panelAlt,
  snackbarText: FahPalette.text,
  snackbarAction: FahPalette.teal,
  snackbarBorder: FahPalette.borderBright,
  tooltipBg: FahPalette.panelAlt,
  tooltipText: FahPalette.text,
  tooltipBorder: FahPalette.borderBright,
);

const _lightColors = _FahThemeColors(
  bg: FahLightPalette.bg,
  bgAlt: FahLightPalette.bgAlt,
  panel: FahLightPalette.panel,
  panelAlt: FahLightPalette.panelAlt,
  border: FahLightPalette.border,
  borderBright: FahLightPalette.borderBright,
  text: FahLightPalette.text,
  dim: FahLightPalette.dim,
  teal: FahLightPalette.teal,
  indigo: FahLightPalette.indigo,
  onAccent: FahLightPalette.onAccent,
  error: FahLightPalette.error,
  errorContainer: FahLightPalette.errorContainer,
  primaryContainer: Color(0xFFE0E4FF),
  onPrimaryContainer: Color(0xFF232B47),
  secondaryContainer: Color(0xFFCCF2E9),
  onSecondaryContainer: Color(0xFF14332D),
  onError: Color(0xFFFFFFFF),
  onErrorContainer: Color(0xFF5F1410),
  surfaceLow: FahLightPalette.bgAlt,
  surfaceHighest: Color(0xFFE6EAF2),
  outlineVariant: Color(0xFFE8ECF3),
  onInverseSurface: FahLightPalette.bg,
  inversePrimary: Color(0xFFA5B4FC),
  selection: Color(0x554F5BC0),
  segmentedSelected: Color(0x334F5BC0),
  elevatedBg: FahLightPalette.panel,
  // Snackbars and tooltips stay dark on the light theme (standard M3
  // inverse-surface look).
  snackbarBg: Color(0xFF1E2430),
  snackbarText: Color(0xFFE8EEF7),
  snackbarAction: Color(0xFF5EEAD4),
  snackbarBorder: Color(0xFF2B3A52),
  tooltipBg: Color(0xFF1E2430),
  tooltipText: Color(0xFFE8EEF7),
  tooltipBorder: Color(0xFF2B3A52),
);

/// The app's dark [ThemeData]: Material 3, landing palette. Everything
/// (scaffold, surfaces, inputs, buttons, snackbars, dialogs, progress
/// indicators) derives from [FahPalette].
ThemeData buildFahTheme() => _buildFahTheme(_darkColors, Brightness.dark);

/// The light counterpart of [buildFahTheme], derived from
/// [FahLightPalette]: same structure, same brand accents, AA-readable
/// grays on white surfaces.
ThemeData buildFahThemeLight() =>
    _buildFahTheme(_lightColors, Brightness.light);

ThemeData _buildFahTheme(_FahThemeColors c, Brightness brightness) {
  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.indigo,
    onPrimary: c.onAccent,
    primaryContainer: c.primaryContainer,
    onPrimaryContainer: c.onPrimaryContainer,
    secondary: c.teal,
    onSecondary: c.onAccent,
    secondaryContainer: c.secondaryContainer,
    onSecondaryContainer: c.onSecondaryContainer,
    tertiary: c.teal,
    onTertiary: c.onAccent,
    tertiaryContainer: c.secondaryContainer,
    onTertiaryContainer: c.onSecondaryContainer,
    error: c.error,
    onError: c.onError,
    errorContainer: c.errorContainer,
    onErrorContainer: c.onErrorContainer,
    surface: c.bgAlt,
    onSurface: c.text,
    onSurfaceVariant: c.dim,
    surfaceContainerLowest: c.bg,
    surfaceContainerLow: c.surfaceLow,
    surfaceContainer: c.panel,
    surfaceContainerHigh: c.panelAlt,
    surfaceContainerHighest: c.surfaceHighest,
    outline: c.border,
    outlineVariant: c.outlineVariant,
    inverseSurface: c.text,
    onInverseSurface: c.onInverseSurface,
    inversePrimary: c.inversePrimary,
    surfaceTint: Colors.transparent, // flat — no M3 tint overlays
  );

  final textTheme =
      (brightness == Brightness.dark
              ? ThemeData.dark(useMaterial3: true)
              : ThemeData.light(useMaterial3: true))
          .textTheme
          .apply(bodyColor: c.text, displayColor: c.text)
          // Inter is bundled (see pubspec fonts): one UI typeface on every
          // platform — consistent brand look and host-deterministic goldens.
          .apply(fontFamily: 'Inter');

  final inputBorder = OutlineInputBorder(
    borderRadius: const BorderRadius.all(Radius.circular(10)),
    borderSide: BorderSide(color: c.border),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.bg,
    canvasColor: c.bgAlt,
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    dividerColor: c.border,
    hintColor: c.dim,
    focusColor: c.indigo.withValues(alpha: 0.12),
    splashColor: c.teal.withValues(alpha: 0.08),
    highlightColor: Colors.transparent,
    appBarTheme: AppBarTheme(
      backgroundColor: c.bg,
      foregroundColor: c.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: Border(bottom: BorderSide(color: c.border)),
      titleTextStyle: textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
      ),
      iconTheme: IconThemeData(color: c.dim),
      actionsIconTheme: IconThemeData(color: c.dim),
    ),
    cardTheme: CardThemeData(
      color: c.panel,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: c.border),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: c.border),
      ),
      titleTextStyle: textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.panel,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: c.surfaceLow,
      surfaceTintColor: Colors.transparent,
    ),
    dividerTheme: DividerThemeData(color: c.border, thickness: 1, space: 1),
    iconTheme: IconThemeData(color: c.dim),
    listTileTheme: ListTileThemeData(iconColor: c.dim, textColor: c.text),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.teal,
      selectionColor: c.selection,
      selectionHandleColor: c.teal,
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: c.panelAlt,
      hintStyle: TextStyle(color: c.dim),
      labelStyle: TextStyle(color: c.dim),
      helperStyle: TextStyle(color: c.dim),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: inputBorder,
      enabledBorder: inputBorder,
      disabledBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide(color: c.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide(color: c.teal, width: 1.2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide(color: c.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide(color: c.error, width: 1.2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.indigo,
        foregroundColor: c.onAccent,
        disabledBackgroundColor: c.panelAlt,
        disabledForegroundColor: c.dim,
        // fontFamily is required: styleFrom replaces labelLarge outright,
        // so a family-less style would fall back to the platform font.
        textStyle: const TextStyle(
          fontFamily: 'Inter',
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: c.elevatedBg,
        foregroundColor: c.text,
        // fontFamily is required: styleFrom replaces labelLarge outright,
        // so a family-less style would fall back to the platform font.
        textStyle: const TextStyle(
          fontFamily: 'Inter',
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: c.borderBright),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: c.teal),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.text,
        side: BorderSide(color: c.borderBright),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.snackbarBg,
      contentTextStyle: TextStyle(color: c.snackbarText),
      actionTextColor: c.snackbarAction,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: c.snackbarBorder),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.teal,
      linearTrackColor: c.border,
      circularTrackColor: c.border,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? c.text : c.dim,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? c.segmentedSelected
              : Colors.transparent,
        ),
        side: WidgetStateProperty.all(BorderSide(color: c.border)),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(c.panelAlt),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        side: WidgetStatePropertyAll(BorderSide(color: c.border)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.panelAlt,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: c.border),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: c.tooltipBg,
        border: Border.all(color: c.tooltipBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: TextStyle(color: c.tooltipText, fontSize: 12),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(c.borderBright),
      radius: const Radius.circular(8),
    ),
  );
}

/// The `flutter_chat_ui` theme matching [buildFahTheme]: chat surface is the
/// page background, bubbles/panels come from [FahPalette].
ChatTheme buildFahChatTheme() => ChatTheme(
  colors: const ChatColors(
    primary: FahPalette.indigo,
    onPrimary: FahPalette.onAccent,
    surface: FahPalette.bg,
    onSurface: FahPalette.text,
    surfaceContainerLow: Color(0xFF0A0F18),
    surfaceContainer: FahPalette.panel,
    surfaceContainerHigh: FahPalette.panelAlt,
  ),
  typography: ChatTypography.standard(),
  shape: const BorderRadius.all(Radius.circular(12)),
);

/// The light counterpart of [buildFahChatTheme], matching
/// [buildFahThemeLight].
ChatTheme buildFahChatThemeLight() => ChatTheme(
  colors: const ChatColors(
    primary: FahLightPalette.indigo,
    onPrimary: FahLightPalette.onAccent,
    surface: FahLightPalette.bg,
    onSurface: FahLightPalette.text,
    surfaceContainerLow: FahLightPalette.bgAlt,
    surfaceContainer: FahLightPalette.panel,
    surfaceContainerHigh: FahLightPalette.panelAlt,
  ),
  typography: ChatTypography.standard(),
  shape: const BorderRadius.all(Radius.circular(12)),
);

/// A brightness-resolved view of the two palettes, for widgets that read
/// palette colors directly instead of going through [ThemeData] (chat
/// bubbles, tool rows, the composer). Resolve once per build with
/// [FahColors.of] and the values follow the ambient theme's brightness;
/// [FahColors.dark] is exactly [FahPalette].
final class FahColors {
  const FahColors._({
    required this.bg,
    required this.bgAlt,
    required this.panel,
    required this.panelAlt,
    required this.border,
    required this.borderBright,
    required this.text,
    required this.dim,
    required this.teal,
    required this.indigo,
    required this.onAccent,
    required this.error,
    required this.errorContainer,
    required this.pending,
    required this.userBubble,
    required this.userBubbleBorder,
    required this.codeBg,
    required this.brandGradient,
  });

  /// The dark values ([FahPalette]).
  static const dark = FahColors._(
    bg: FahPalette.bg,
    bgAlt: FahPalette.bgAlt,
    panel: FahPalette.panel,
    panelAlt: FahPalette.panelAlt,
    border: FahPalette.border,
    borderBright: FahPalette.borderBright,
    text: FahPalette.text,
    dim: FahPalette.dim,
    teal: FahPalette.teal,
    indigo: FahPalette.indigo,
    onAccent: FahPalette.onAccent,
    error: FahPalette.error,
    errorContainer: FahPalette.errorContainer,
    pending: FahPalette.pending,
    userBubble: FahPalette.userBubble,
    userBubbleBorder: FahPalette.userBubbleBorder,
    codeBg: FahPalette.codeBg,
    brandGradient: FahPalette.brandGradient,
  );

  /// The light values ([FahLightPalette]).
  static const light = FahColors._(
    bg: FahLightPalette.bg,
    bgAlt: FahLightPalette.bgAlt,
    panel: FahLightPalette.panel,
    panelAlt: FahLightPalette.panelAlt,
    border: FahLightPalette.border,
    borderBright: FahLightPalette.borderBright,
    text: FahLightPalette.text,
    dim: FahLightPalette.dim,
    teal: FahLightPalette.teal,
    indigo: FahLightPalette.indigo,
    onAccent: FahLightPalette.onAccent,
    error: FahLightPalette.error,
    errorContainer: FahLightPalette.errorContainer,
    pending: FahLightPalette.pending,
    userBubble: FahLightPalette.userBubble,
    userBubbleBorder: FahLightPalette.userBubbleBorder,
    codeBg: FahLightPalette.codeBg,
    brandGradient: FahLightPalette.brandGradient,
  );

  /// Resolves the palette matching the ambient theme's brightness.
  static FahColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.light ? light : dark;

  final Color bg;
  final Color bgAlt;
  final Color panel;
  final Color panelAlt;
  final Color border;
  final Color borderBright;
  final Color text;
  final Color dim;
  final Color teal;
  final Color indigo;
  final Color onAccent;
  final Color error;
  final Color errorContainer;
  final Color pending;
  final Color userBubble;
  final Color userBubbleBorder;
  final Color codeBg;
  final LinearGradient brandGradient;

  /// Monospace text style for terminal-ish content (see [FahPalette.mono]),
  /// defaulting to this palette's [text] color.
  TextStyle mono({
    Color? color,
    double fontSize = 12.5,
    FontWeight? fontWeight,
  }) {
    return TextStyle(
      fontFamily: 'JetBrainsMono',
      fontFamilyFallback: FahPalette.monoFallback,
      color: color ?? text,
      fontSize: fontSize,
      fontWeight: fontWeight,
      height: 1.55,
    );
  }
}

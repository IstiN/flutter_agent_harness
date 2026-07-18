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
      fontFamily: 'monospace',
      fontFamilyFallback: monoFallback,
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
      height: 1.55,
    );
  }
}

/// The app's single [ThemeData]: Material 3, brightness dark, landing
/// palette. Everything (scaffold, surfaces, inputs, buttons, snackbars,
/// dialogs, progress indicators) derives from [FahPalette].
ThemeData buildFahTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: FahPalette.indigo,
    onPrimary: FahPalette.onAccent,
    primaryContainer: Color(0xFF232B47),
    onPrimaryContainer: Color(0xFFE0E4FF),
    secondary: FahPalette.teal,
    onSecondary: FahPalette.onAccent,
    secondaryContainer: Color(0xFF14332D),
    onSecondaryContainer: Color(0xFFBCFFF3),
    tertiary: FahPalette.teal,
    onTertiary: FahPalette.onAccent,
    tertiaryContainer: Color(0xFF14332D),
    onTertiaryContainer: Color(0xFFBCFFF3),
    error: FahPalette.error,
    onError: Color(0xFF3A0B06),
    errorContainer: FahPalette.errorContainer,
    onErrorContainer: Color(0xFFFFDAD4),
    surface: FahPalette.bgAlt,
    onSurface: FahPalette.text,
    onSurfaceVariant: FahPalette.dim,
    surfaceContainerLowest: FahPalette.bg,
    surfaceContainerLow: Color(0xFF0A0F18),
    surfaceContainer: FahPalette.panel,
    surfaceContainerHigh: FahPalette.panelAlt,
    surfaceContainerHighest: Color(0xFF152033),
    outline: FahPalette.border,
    outlineVariant: Color(0xFF141C2B),
    inverseSurface: FahPalette.text,
    onInverseSurface: Color(0xFF1A2130),
    inversePrimary: Color(0xFF4F5BC0),
    surfaceTint: Colors.transparent, // flat — no M3 tint overlays
  );

  final textTheme = ThemeData.dark(
    useMaterial3: true,
  ).textTheme.apply(bodyColor: FahPalette.text, displayColor: FahPalette.text);

  const inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(10)),
    borderSide: BorderSide(color: FahPalette.border),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: FahPalette.bg,
    canvasColor: FahPalette.bgAlt,
    textTheme: textTheme,
    primaryTextTheme: textTheme,
    dividerColor: FahPalette.border,
    hintColor: FahPalette.dim,
    focusColor: FahPalette.indigo.withValues(alpha: 0.12),
    splashColor: FahPalette.teal.withValues(alpha: 0.08),
    highlightColor: Colors.transparent,
    appBarTheme: AppBarTheme(
      backgroundColor: FahPalette.bg,
      foregroundColor: FahPalette.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: const Border(bottom: BorderSide(color: FahPalette.border)),
      titleTextStyle: textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
      ),
      iconTheme: const IconThemeData(color: FahPalette.dim),
      actionsIconTheme: const IconThemeData(color: FahPalette.dim),
    ),
    cardTheme: CardThemeData(
      color: FahPalette.panel,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: FahPalette.border),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: FahPalette.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: FahPalette.border),
      ),
      titleTextStyle: textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w700,
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: FahPalette.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
    ),
    drawerTheme: const DrawerThemeData(
      backgroundColor: Color(0xFF0A0F18),
      surfaceTintColor: Colors.transparent,
    ),
    dividerTheme: const DividerThemeData(
      color: FahPalette.border,
      thickness: 1,
      space: 1,
    ),
    iconTheme: const IconThemeData(color: FahPalette.dim),
    listTileTheme: const ListTileThemeData(
      iconColor: FahPalette.dim,
      textColor: FahPalette.text,
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: FahPalette.teal,
      selectionColor: Color(0x55818CF8),
      selectionHandleColor: FahPalette.teal,
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: FahPalette.panelAlt,
      hintStyle: const TextStyle(color: FahPalette.dim),
      labelStyle: const TextStyle(color: FahPalette.dim),
      helperStyle: const TextStyle(color: FahPalette.dim),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: inputBorder,
      enabledBorder: inputBorder,
      disabledBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide(color: Color(0xFF141C2B)),
      ),
      focusedBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide(color: FahPalette.teal, width: 1.2),
      ),
      errorBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide(color: FahPalette.error),
      ),
      focusedErrorBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(10)),
        borderSide: BorderSide(color: FahPalette.error, width: 1.2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: FahPalette.indigo,
        foregroundColor: FahPalette.onAccent,
        disabledBackgroundColor: FahPalette.panelAlt,
        disabledForegroundColor: FahPalette.dim,
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: FahPalette.panelAlt,
        foregroundColor: FahPalette.text,
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: FahPalette.borderBright),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: FahPalette.teal),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: FahPalette.text,
        side: const BorderSide(color: FahPalette.borderBright),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: FahPalette.panelAlt,
      contentTextStyle: const TextStyle(color: FahPalette.text),
      actionTextColor: FahPalette.teal,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: FahPalette.borderBright),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: FahPalette.teal,
      linearTrackColor: FahPalette.border,
      circularTrackColor: FahPalette.border,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? FahPalette.text
              : FahPalette.dim,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? const Color(0x33818CF8)
              : Colors.transparent,
        ),
        side: WidgetStateProperty.all(
          const BorderSide(color: FahPalette.border),
        ),
      ),
    ),
    dropdownMenuTheme: const DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(FahPalette.panelAlt),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        side: WidgetStatePropertyAll(BorderSide(color: FahPalette.border)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: FahPalette.panelAlt,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: FahPalette.border),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: FahPalette.panelAlt,
        border: Border.all(color: FahPalette.borderBright),
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: const TextStyle(color: FahPalette.text, fontSize: 12),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(FahPalette.borderBright),
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

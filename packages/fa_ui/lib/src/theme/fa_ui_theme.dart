// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:fa_ui/src/theme/app_theme.dart';

/// The host-app customization layer over the Fa brand theme.
///
/// Every field is optional; a null field keeps the brand default, so
/// `const FaUiTheme()` reproduces the stock look exactly. Wrap the app in a
/// [FaUiThemeProvider] and build the material themes with
/// [FaUiThemeProvider.darkThemeOf] / [FaUiThemeProvider.lightThemeOf] (or
/// pass the data to [buildFahTheme] / [buildFahThemeLight] directly) to
/// re-skin every fa_ui widget — and any host widget reading
/// [FahColors.of] — at once.
final class FaUiTheme {
  /// Creates a customization set; all-null is the stock Fa look.
  const FaUiTheme({
    this.indigo,
    this.teal,
    this.fontFamily,
    this.cardRadius,
    this.inputRadius,
    this.buttonRadius,
    this.background,
    this.surface,
  });

  /// Primary accent (buttons, marks, selections); null keeps the brand
  /// indigo of the active brightness. Applied to both brightnesses — pick a
  /// value that reads on dark and light surfaces, or wrap the two
  /// brightness subtrees in different providers.
  final Color? indigo;

  /// Secondary accent (success states, links, cursors); null keeps the
  /// brand teal.
  final Color? teal;

  /// UI typeface replacing the bundled `Inter` (the host must bundle the
  /// family itself); null keeps `Inter`.
  final String? fontFamily;

  /// Corner radius of cards and dialogs; null keeps 14.
  final double? cardRadius;

  /// Corner radius of text input borders; null keeps 10.
  final double? inputRadius;

  /// Corner radius of filled/elevated/outlined buttons and snackbars; null
  /// keeps 10.
  final double? buttonRadius;

  /// Chat transcript background (`ChatColors.surface` in the chat theme
  /// builders); null keeps the brand page background. Lets a host whose own
  /// surface palette differs from the Fa one (e.g. YoClip Studio) seat the
  /// chat on its exact background.
  final Color? background;

  /// Chat raised-surface color (`ChatColors.surfaceContainer`); null keeps
  /// the brand panel color.
  final Color? surface;

  /// The effective accent colors for a palette built on [baseIndigo] /
  /// [baseTeal].
  (Color indigo, Color teal) accentsFor(Color baseIndigo, Color baseTeal) =>
      (indigo ?? baseIndigo, teal ?? baseTeal);
}

/// Exposes a [FaUiTheme] to the widget tree. Host apps wrap their
/// `MaterialApp` (or just the Fa subtree) in this provider; fa_ui widgets
/// and [FahColors.of] pick the customization up automatically.
class FaUiThemeProvider extends InheritedWidget {
  /// Creates a provider exposing [data].
  const FaUiThemeProvider({
    super.key,
    required this.data,
    required super.child,
  });

  /// The customization data.
  final FaUiTheme data;

  /// The nearest [FaUiTheme], or null when no provider is installed (the
  /// stock brand look).
  static FaUiTheme? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FaUiThemeProvider>()?.data;

  /// The nearest [FaUiTheme], or the all-default instance.
  static FaUiTheme of(BuildContext context) =>
      maybeOf(context) ?? const FaUiTheme();

  /// The dark Fa [ThemeData] derived from the nearest [FaUiTheme].
  static ThemeData darkThemeOf(BuildContext context) =>
      buildFahTheme(uiTheme: of(context));

  /// The light Fa [ThemeData] derived from the nearest [FaUiTheme].
  static ThemeData lightThemeOf(BuildContext context) =>
      buildFahThemeLight(uiTheme: of(context));

  @override
  bool updateShouldNotify(FaUiThemeProvider oldWidget) =>
      data != oldWidget.data;
}

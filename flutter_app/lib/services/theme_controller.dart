// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The app's appearance choices, shown in the settings theme dropdown.
enum FahThemeMode {
  /// Follow the platform brightness.
  system,

  /// Always the light theme ([buildFahThemeLight]).
  light,

  /// Always the dark theme ([buildFahTheme]).
  dark;

  /// Parses [value] written by [ThemeController]; unknown values fall back
  /// to [FahThemeMode.system] (corrupt files must never crash boot).
  static FahThemeMode parse(String? value) => switch (value) {
    'light' => FahThemeMode.light,
    'dark' => FahThemeMode.dark,
    _ => FahThemeMode.system,
  };
}

/// Holds the selected [FahThemeMode] and persists it as JSON at
/// `theme.json` in the root of the sandbox filesystem ([ExecutionEnv.cwd]) —
/// on web that file rides the IndexedDB snapshot of the persistent env, on
/// IO it is a plain file in the sandbox/app-documents directory (same
/// pattern as [ProviderRegistry] / [LastConnectionStore]).
///
/// Written on every [setMode]; read once at boot. A missing, unreadable, or
/// corrupt file yields the default ([FahThemeMode.system]). Non-secret by
/// design.
class ThemeController extends ChangeNotifier {
  ThemeController._(this._env);

  /// A controller without persistence (tests, widget fallbacks): [setMode]
  /// notifies listeners but nothing is written anywhere.
  ThemeController.inMemory([this._mode = FahThemeMode.system]) : _env = null;

  /// File name (under [ExecutionEnv.cwd]) the controller persists to.
  static const fileName = 'theme.json';

  /// Schema version of the JSON envelope; other versions load as default.
  static const _version = 1;

  final ExecutionEnv? _env;
  FahThemeMode _mode = FahThemeMode.system;

  /// Loads the mode persisted in [env]; a missing, unreadable, or corrupt
  /// file yields the default mode.
  static Future<ThemeController> load(ExecutionEnv env) async {
    final controller = ThemeController._(env);
    await controller._load();
    return controller;
  }

  /// The selected appearance choice.
  FahThemeMode get mode => _mode;

  /// The [ThemeMode] handed to `MaterialApp.themeMode`.
  ThemeMode get themeMode => switch (_mode) {
    FahThemeMode.system => ThemeMode.system,
    FahThemeMode.light => ThemeMode.light,
    FahThemeMode.dark => ThemeMode.dark,
  };

  /// Selects [mode] and persists it. Persistence is best effort: a failed
  /// write must not break the settings UI.
  Future<void> setMode(FahThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    final env = _env;
    if (env == null) return;
    try {
      await env.writeFile(
        '${env.cwd}/$fileName',
        jsonEncode({'version': _version, 'mode': mode.name}),
      );
    } on Object {
      // Best effort: persistence must never block the theme switch.
    }
  }

  Future<void> _load() async {
    final env = _env;
    if (env == null) return;
    try {
      final text = (await env.readTextFile('${env.cwd}/$fileName')).valueOrNull;
      if (text == null) return;
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return;
      if (decoded['version'] != _version) return;
      _mode = FahThemeMode.parse(decoded['mode'] as String?);
    } on Object {
      // Corrupt or incompatible file → default mode, never crash boot.
    }
  }
}

/// Provides the app's [ThemeController] to the widget tree (settings theme
/// dropdown) without threading it through every intermediate widget.
class FahThemeScope extends InheritedNotifier<ThemeController> {
  /// Creates a scope exposing [controller].
  const FahThemeScope({
    super.key,
    required ThemeController controller,
    required super.child,
  }) : super(notifier: controller);

  /// The nearest controller, or `null` outside the app shell (tests).
  static ThemeController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FahThemeScope>()?.notifier;
}

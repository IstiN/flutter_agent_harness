// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/widgets.dart';

/// Resolves a secure-store key NAME (e.g. `OPENROUTER_API_KEY`) to its
/// current value. The host installs this once at startup to teach fa_ui
/// about its own key-resolution chain (compile-time defines, dotenv files,
/// platform secure storage).
typedef FaUiKeyResolver = String Function(String keyName);

/// Builds the host's brand avatar tile (gh-2391 addendum 9 item 1): the
/// branded product mark instead of the stock `>Fa` logo in fa_ui's
/// assistant avatar and session tiles. Installed once at startup by the
/// app host (the widget consults the product scope itself); null keeps the
/// stock [FaLogo] rendering.
typedef FaBrandAvatarBuilder =
    Widget Function({required double size, bool? dark});

/// Process-wide host hooks for fa_ui.
///
/// Everything here is optional: without a resolver the widgets fall back to
/// the nearest [SessionKeysStore] (see `SessionKeysScope`), which matches
/// the "saved keys only" behavior. A host with additional key sources
/// (dart-defines, `.env`, its own secure store) installs a [keyResolver]
/// once at startup so the preset editors and model pages resolve keys
/// exactly like the rest of the host app.
abstract final class FaUiHost {
  /// The host's key-resolution chain, consulted before the saved-keys store
  /// when a provider key is needed. Null means "saved-keys store only".
  static FaUiKeyResolver? keyResolver;

  /// The agent's display identity (gh-2391 addendum 9 item 1), installed
  /// once at startup from the product profile's `agentName`. Drives the
  /// typing indicator and the app-side system prompt; null keeps "Fa".
  static String? agentName;

  /// The host's brand avatar tile, consulted by fa_ui's assistant avatar
  /// (and any session tile riding it) before the stock logo. Null = stock.
  static FaBrandAvatarBuilder? brandAvatarBuilder;

  /// The display identity with the stock fallback applied.
  static String get agentNameOrStock => agentName ?? 'Fa';

  /// Resolves [keyName] through the host hook, then [fallback] (typically
  /// the saved-keys store lookup). Never returns null.
  static String resolveKey(String keyName, String Function() fallback) {
    final resolved = keyResolver?.call(keyName);
    if (resolved != null && resolved.isNotEmpty) return resolved;
    return fallback();
  }
}

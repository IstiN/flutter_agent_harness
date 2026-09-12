// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/theme_controller.dart';
import 'package:fa/services/theme_pack_store.dart';

/// The host side of `jsr.fa.theme.*` (issue #169): reads the installed
/// packs and the active choice, and turns every `apply` into a user
/// consent prompt before the app-wide theme moves (the "secured" half of
/// the secured declarative-only API — an app can PROPOSE a pack, only the
/// user can apply one).
///
/// Prompts serialize through a future chain: a burst of `apply` calls
/// queues its dialogs one after another (E3) instead of stacking them.
final class FaThemeBridgeHost implements FaThemeBridge {
  FaThemeBridgeHost({
    required ThemePackStore store,
    required ThemeController controller,
    required this.prompt,
    // Private fields can't take initializing formals; one ignore covers
    // the initializer list below.
    // ignore: prefer_initializing_formals
  }) : _store = store,
       // ignore: prefer_initializing_formals
       _controller = controller;

  final ThemePackStore _store;
  final ThemeController _controller;

  /// Renders the consent dialog (app name + pack + contrast warnings) and
  /// resolves granted/denied. Injected by the hosting widget so the bridge
  /// stays context-free.
  final Future<bool> Function(InstalledThemePack pack) prompt;

  /// Serializes consent prompts (E3): a queued prompt runs only after the
  /// previous one resolved.
  Future<void> _gate = Future.value();

  /// The bridge descriptor of one installed pack — declarative data only.
  static Map<String, Object?> descriptorOf(InstalledThemePack pack) => {
    'id': pack.id,
    'name': pack.name,
    'version': pack.version,
    'hasWallpaper': pack.spec.wallpaper != null,
    'contrastWarnings': pack.spec.contrastWarnings,
  };

  @override
  Future<List<Map<String, Object?>>> listPacks() async =>
      _store.packs.map(descriptorOf).toList();

  @override
  Future<Map<String, Object?>?> currentPack() async {
    final pack = _store.byId(_controller.packId);
    return pack == null ? null : descriptorOf(pack);
  }

  @override
  Future<Map<String, Object?>> applyPack(String id) async {
    final pack = _store.byId(id);
    if (pack == null) {
      throw StateError(
        'unknown theme pack "$id" — call jsr.fa.theme.list() for the '
        'installed ids',
      );
    }
    // Queue this pack's prompt behind any in-flight one.
    final granted = await _gate.then((_) => prompt(pack));
    // Keep the chain alive even when a prompt throws (a dead host widget
    // must not wedge the next apply).
    _gate = _gate.then((_) {}, onError: (_) {});
    if (!granted) return {'applied': false, 'reason': 'denied'};
    await _controller.setPack(
      id,
      hasWallpaper: pack.spec.wallpaper != null,
    );
    return {'applied': true, 'pack': descriptorOf(pack)};
  }
}

/// The consent dialog every `jsr.fa.theme.apply` shows: which app proposes
/// which pack (with its low-contrast warnings), Apply / Keep current.
Future<bool> showThemePackConsent(
  BuildContext context, {
  required String appName,
  required InstalledThemePack pack,
}) async {
  final l10n = context.l10n;
  final granted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.themeConsentTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.themeConsentBody(appName, pack.name)),
          if (pack.spec.contrastWarnings.isNotEmpty) ...[
            const SizedBox(height: 12),
            Icon(
              Icons.warning_amber_rounded,
              size: 20,
              color: Theme.of(dialogContext).colorScheme.error,
            ),
            const SizedBox(height: 4),
            Text(
              l10n.themeConsentContrast,
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(l10n.themeConsentDeny),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.themeConsentApply),
        ),
      ],
    ),
  );
  return granted == true;
}

// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import 'package:fa/services/theme_controller.dart';
import 'package:fa/services/theme_pack_store.dart';

/// The active theme pack's wallpaper layer: paints the pack's bundled image
/// at its declared fit/opacity, filling whatever surface it is seated on
/// (the chat transcript, the apps grid). Renders nothing without an active
/// pack/wallpaper — or when the asset went missing after install (E2), in
/// which case the themed color background simply shows through.
///
/// E4: a colors-only pack keeps the previous wallpaper, so the layer
/// resolves through [ThemeController.wallpaperPackId] (the last pack that
/// DID ship one) instead of only the active pack.
///
/// Re-builds on both the theme controller (active pack choice) and the pack
/// store (install/update/remove), so an apply or a revert is instant.
class FahWallpaper extends StatelessWidget {
  const FahWallpaper({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = FahThemeScope.maybeOf(context);
    final store = ThemePackScope.maybeOf(context);
    if (controller == null || store == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([controller, store]),
      builder: (context, _) {
        final active = store.byId(controller.packId);
        // E4: the wallpaper outlives a switch to a colors-only pack —
        // fall back to the last pack that shipped one.
        final pack =
            active?.spec.wallpaper != null
            ? active
            : store.byId(controller.wallpaperPackId) ?? active;
        final wallpaper = pack?.spec.wallpaper;
        final bytes = pack?.wallpaperBytes;
        if (pack == null || wallpaper == null || bytes == null) {
          return const SizedBox.shrink();
        }
        return Opacity(
          opacity: wallpaper.opacity,
          child: Image.memory(bytes, fit: wallpaper.fit),
        );
      },
    );
  }
}

// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';

import '../theme/fa2_tokens.dart';

/// Presents [page] modally, adapting to the available canvas: a centered,
/// width/height-constrained dialog when there is room (desktop / tablet,
/// where a full-screen editor stretches into an unreadable strip), and a
/// classic full-screen [MaterialPageRoute] on narrow (phone) canvases.
///
/// The result contract is identical in both modes: the page pops its
/// navigator with the result, which is returned to the caller.
/// [dialogMaxWidth] defaults to the compact 560pt editor width; dense pages
/// such as Settings can opt into a wider desktop platter without changing
/// every other dialog.
///
/// In the glass visual direction the wide dialog goes transparent (no
/// elevation/tint either) and marks the subtree with [FaGlassDialogScope],
/// so a page hosting a glass platter can make its own chrome transparent
/// and let the platter sample the app behind the dialog. Opaque
/// directions keep the stock opaque dialog, byte for byte.
Future<T?> pushFaPage<T>(
  BuildContext context,
  Widget page, {
  double dialogMaxWidth = 560,
}) {
  final size = MediaQuery.sizeOf(context);
  if (size.width >= 840) {
    // Desktop/tablet: a centered dialog, constrained so it doesn't stretch
    // into an unreadable full-height strip. Height caps at 84% of the
    // window so it never feels like a mobile full-screen page.
    // A full scrim keeps every underlying surface visually subordinate.
    // Only a REAL glass-direction theme opts in — a plain MaterialApp
    // without the token extension keeps the legacy opaque dialog.
    final glass =
        Theme.of(context).extension<FaDesignTokens>()?.direction ==
        FaVisualDirection.glass;
    return showDialog<T>(
      context: context,
      barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: .60),
      builder: (dialogContext) {
        // Read the DIALOG's live media: a desktop window can be resized
        // after the route opens. Capturing the launcher's original height
        // here would let an old cap turn the page into a full-height strip.
        final dialogSize = MediaQuery.sizeOf(dialogContext);
        final scopedPage = FaDialogScope(child: page);
        return Dialog(
          insetPadding: const EdgeInsets.all(24),
          backgroundColor: glass ? Colors.transparent : null,
          surfaceTintColor: glass ? Colors.transparent : null,
          elevation: glass ? 0 : null,
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: dialogMaxWidth,
              maxHeight: dialogSize.height * 0.84,
            ),
            child: glass ? FaGlassDialogScope(child: scopedPage) : scopedPage,
          ),
        );
      },
    );
  }
  return Navigator.of(context).push<T>(MaterialPageRoute(builder: (_) => page));
}

/// Marks any page hosted by the centered dialog branch of [pushFaPage].
/// Desktop chrome reads this to avoid reserving floating-window traffic-light
/// space inside an already-centered modal platter. Full-screen routes never
/// see the marker.
class FaDialogScope extends InheritedWidget {
  const FaDialogScope({super.key, required super.child});

  /// Whether the nearest presentation is a centered Fa dialog.
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FaDialogScope>() != null;

  @override
  bool updateShouldNotify(FaDialogScope oldWidget) => false;
}

/// Marks a page presented inside the transparent glass-direction dialog
/// of [pushFaPage]. A page hosting a glass platter (e.g. Settings) reads
/// this to make its own Scaffold/AppBar transparent so the platter
/// samples the app behind the dialog; standalone routes never see the
/// marker and keep their opaque chrome.
class FaGlassDialogScope extends InheritedWidget {
  const FaGlassDialogScope({super.key, required super.child});

  /// Whether the nearest presentation is the transparent glass dialog.
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FaGlassDialogScope>() != null;

  @override
  bool updateShouldNotify(FaGlassDialogScope oldWidget) => false;
}

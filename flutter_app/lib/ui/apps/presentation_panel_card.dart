// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';

/// The single desktop substrate for docked Apps and Files presentations.
///
/// Eight-point floating margins, a token hairline and clipped glass match the
/// messenger's sidebar/card language. Phone presentations bypass this widget
/// entirely; their app canvas remains full-bleed.
final class FaPresentationPanelCard extends StatelessWidget {
  const FaPresentationPanelCard({
    super.key,
    required this.cardKey,
    required this.child,
    this.contentPadding = EdgeInsets.zero,
  });

  /// Key retained on the real surface/decorated card for geometry tests.
  final Key cardKey;
  final Widget child;
  final EdgeInsetsGeometry contentPadding;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    final realGlass = tokens.direction == FaVisualDirection.glass;
    final card = FaSurface(
      key: realGlass ? null : cardKey,
      glass: true,
      useBackdropGroup: true,
      color: tokens.surface1,
      tintAmount: .4,
      tintOpacity: .78,
      borderRadius: BorderRadius.circular(realGlass ? 17 : 18),
      padding: contentPadding,
      child: child,
    );
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: realGlass
            ? DecoratedBox(
                key: cardKey,
                decoration: BoxDecoration(
                  color: tokens.surface1,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: tokens.hairline),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(1),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(17),
                    child: card,
                  ),
                ),
              )
            : card,
      ),
    );
  }
}

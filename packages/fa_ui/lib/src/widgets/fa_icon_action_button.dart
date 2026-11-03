// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../chat/fa_adaptive_header.dart';
import '../theme/fa2_tokens.dart';
import 'fa2_controls.dart'
    show faGlassSettings, kFaGlassFrost, kFaGlassTintAlpha;

/// The ONE circular icon action for headers, bands and panel chrome.
///
/// Every circular icon control — the sidebar collapse/expand toggle, the
/// chat header's trajectory/copy/files actions, the Files band's ✕/⋮, the
/// path-bar and preview-bar chrome — renders through this component (or
/// through [FaHeaderCircularAction], the child-taking chrome primitive it
/// is built on), so no call site pixel-aligns its own circle anymore.
///
/// The component owns the whole contract:
/// - **diameter** — [defaultDiameter] (36, the composer's control scale)
///   via [diameter]; the chat bar's 40pt chrome passes `diameter: 40`;
/// - **glyph ratio** — the glyph draws at [glyphSizeFor] (half the
///   circle's edge: 18px at 36), a ~0.38 painted-ink share for
///   MaterialIcons, so no circle carries an oversized or starved glyph;
/// - **ink** — one token ([FaDesignTokens.ink1]) via the chrome's
///   [IconTheme]; call sites never pick a glyph gray;
/// - **fill + border** — token-driven ([FaDesignTokens.surface2] +
///   [FaDesignTokens.hairline]) — ONE style for every direction and
///   brightness, no per-call-site surface variants;
/// - **interaction** — hover/pressed/focus overlays, tooltip and
///   accessibility semantics from the inner [IconButton]; the tap target
///   is the full [diameter] and [diameter] may not drop under 32pt;
/// - **keys** — [buttonKey] lands on the inner button (a single finder
///   match inside the chrome), mirroring the pre-band header's keyed bar
///   buttons.
///
/// A non-[IconData] glyph (a custom painter, a popup menu) passes
/// [child] instead of [icon] — it rides the same chrome, ink and sizing.
class FaIconActionButton extends StatelessWidget {
  const FaIconActionButton({
    super.key,
    this.icon,
    this.child,
    required this.onPressed,
    this.tooltip,
    this.diameter = defaultDiameter,
    this.glyphSize,
    this.buttonKey,
    this.glass = false,
    this.focusNode,
  }) : assert(
         (icon == null) != (child == null),
         'Provide exactly one of icon or child',
       ),
       assert(
         diameter >= minHitTarget,
         'FaIconActionButton keeps a >= $minHitTarget pt hit target',
       );

  /// The control-scale circle (the composer's send/mic scale), one step
  /// down from the chat bar's 40pt chrome.
  static const double defaultDiameter = 36;

  /// The smallest allowed tap target — the styleguide's minimum hit area.
  static const double minHitTarget = 32;

  /// The glyph's share of the circle's edge: half the circle nominal
  /// (18px at the 36 default), which paints a ~0.38 ink share for
  /// MaterialIcons (glyphs draw ≈0.75 of their em box).
  static const double glyphRatio = 0.5;

  /// The glyph size for a [diameter] — [glyphRatio] of the circle's edge.
  static double glyphSizeFor(double diameter) => diameter * glyphRatio;

  /// The Material glyph; null only in [child] mode.
  final IconData? icon;

  /// A custom glyph (painter, popup trigger) replacing [icon]; it inherits
  /// the chrome's [IconTheme] (ink1) and is expected to size itself at
  /// [glyphSize].
  final Widget? child;

  /// Invoked on tap; null disables (the chrome stays, semantics report
  /// the disabled state).
  final VoidCallback? onPressed;

  /// Tooltip AND accessibility name.
  final String? tooltip;

  /// The circle's edge length (≥ [minHitTarget]).
  final double diameter;

  /// The glyph's edge; null resolves to [glyphSizeFor] of [diameter].
  final double? glyphSize;

  /// The effective glyph size for this button.
  double get effectiveGlyphSize => glyphSize ?? glyphSizeFor(diameter);

  /// The key for the inner button (a single finder match inside the
  /// chrome — never ambiguous with its wrapper).
  final Key? buttonKey;

  /// State-conditional glass underlay (owner rule): false (default) when
  /// the circle sits on a parent surface (Files band, panel slabs — flat
  /// token surface); true when it floats on the chat header's backdrop.
  /// In the glass direction true renders the kit's [GlassIconButton] — the
  /// jelly squash-press, the token-derived press glow and the Fa-tuned
  /// glass material come from the kit, not an imitation; every other
  /// direction keeps the flat [FaHeaderCircularAction] chrome (styleguide
  /// rule: real glass only in the glass direction).
  final bool glass;

  /// Focus node for the kit button (glass mode); null keeps the kit's
  /// internal focus handling.
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final tokens = FaDesignTokens.of(context);
    if (glass && tokens.direction == FaVisualDirection.glass) {
      final enabled = onPressed != null;
      final kitButton = GlassIconButton(
        key: buttonKey,
        icon: IconTheme.merge(
          data: IconThemeData(
            size: effectiveGlyphSize,
            color: enabled ? tokens.ink1 : tokens.ink3,
          ),
          child:
              child ?? Icon(icon, size: effectiveGlyphSize, color: tokens.ink1),
        ),
        onPressed: onPressed,
        // OUR control scale, not the kit's 44pt phone target: the circle
        // keeps the 36pt composer diameter, glyph at half the edge.
        size: diameter,
        iconSize: effectiveGlyphSize,
        interactionScale: 0.95,
        glowColor: tokens.ink1.withValues(alpha: .2),
        glowRadius: diameter * .5,
        settings: faGlassSettings(
          tint: tokens.surface1.withValues(alpha: kFaGlassTintAlpha),
          frost: kFaGlassFrost,
        ),
        focusNode: focusNode,
        semanticLabel: tooltip,
      );
      return tooltip == null
          ? kitButton
          : Tooltip(message: tooltip, child: kitButton);
    }
    return FaHeaderCircularAction(
      dimension: diameter,
      glass: glass,
      child: IconButton(
        key: buttonKey,
        onPressed: onPressed,
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        constraints: BoxConstraints.tightFor(width: diameter, height: diameter),
        style: IconButton.styleFrom(
          minimumSize: Size.square(diameter),
          maximumSize: Size.square(diameter),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        icon: child ?? Icon(icon, size: effectiveGlyphSize),
      ),
    );
  }
}

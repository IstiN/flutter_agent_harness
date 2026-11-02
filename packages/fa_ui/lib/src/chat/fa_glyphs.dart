// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/fa2_theme.dart';
import '../theme/fa2_tokens.dart';
import '../widgets/fa_logo.dart';

/// Shared chat glyphs drawn as inline SVG (crisp at any density, no icon
/// font dependency): the composer's attach affordance and the assistant's
/// brand avatar.

/// The attach affordance: a rounded-cap plus inside a rounded square
/// (owner-approved variant B3) — the modern "add content" mark, its 2px
/// stroke rhyming with the mic circle in the one-action trailing slot.
/// Replaces the stock paperclip.
class FaAttachGlyph extends StatelessWidget {
  const FaAttachGlyph({super.key, required this.color, this.size = 24});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hex =
        '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';
    return SizedBox(
      width: size,
      height: size,
      child: SvgPicture.string(
        // Owner-approved variant B3 (2026-09-16), ported verbatim: a
        // 2px-stroke rounded square with a plus, round caps/joins.
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" '
        'fill="none" stroke="$hex" stroke-width="2" stroke-linecap="round" '
        'stroke-linejoin="round">'
        '<rect x="3.5" y="3.5" width="17" height="17" rx="5"/>'
        '<path d="M12 8.5v7M8.5 12h7"/>'
        '</svg>',
        fit: BoxFit.contain,
      ),
    );
  }
}

/// The model affordance (provider editor's model row): an AI chip — a
/// rounded silicon package with edge pins and a four-point spark at the
/// core. Monochrome, tinted by [color], so it sits in any row style.
class FaModelGlyph extends StatelessWidget {
  const FaModelGlyph({super.key, required this.color, this.size = 24});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hex =
        '#${color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';
    return SizedBox(
      width: size,
      height: size,
      child: SvgPicture.string(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
        // Edge pins (top/right/bottom/left pairs).
        '<path d="M8.9 1.7v2.3M15.1 1.7v2.3M8.9 20v2.3M15.1 20v2.3'
        'M1.7 8.9h2.3M1.7 15.1h2.3M20 8.9h2.3M20 15.1h2.3" fill="none" '
        'stroke="$hex" stroke-width="1.5" stroke-linecap="round"/>'
        // The package body.
        '<rect x="5.1" y="5.1" width="13.8" height="13.8" rx="3.9" '
        'fill="none" stroke="$hex" stroke-width="1.6"/>'
        // The spark at the core.
        '<path d="M12 8.6C12.38 10.62 13.32 11.56 15.4 12 13.32 12.44 '
        '12.38 13.38 12 15.4 11.62 13.38 10.68 12.44 8.6 12 10.68 11.56 '
        '11.62 10.62 12 8.6Z" fill="$hex"/>'
        '</svg>',
        fit: BoxFit.contain,
      ),
    );
  }
}

/// The assistant's transcript avatar: the shared B3-square-accent [FaLogo].
/// [dark] defaults to the theme brightness.
class FaAiAvatar extends StatelessWidget {
  const FaAiAvatar({super.key, this.size = 28, this.dark});

  final double size;

  /// Forces the dark/light form; null follows the theme brightness.
  final bool? dark;

  @override
  Widget build(BuildContext context) {
    final forced = dark;
    if (forced == null) return FaLogo(size: size);
    return Theme(
      data: buildFaTheme(
        direction: FaDesignTokens.of(context).direction,
        brightness: forced ? Brightness.dark : Brightness.light,
      ),
      child: FaLogo(size: size),
    );
  }
}

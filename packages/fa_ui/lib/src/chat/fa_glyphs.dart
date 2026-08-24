// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Shared chat glyphs drawn as inline SVG (crisp at any density, no icon
/// font dependency): the composer's attach affordance and the assistant's
/// brand avatar.

/// The attach affordance: a rounded-cap plus inside a hairline circle —
/// the modern "add content" mark (iMessage-style), rhyming with the mic
/// circle in the one-action trailing slot. Replaces the stock paperclip.
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
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
        '<circle cx="12" cy="12" r="9.2" fill="none" stroke="$hex" '
        'stroke-width="1.5"/>'
        '<path d="M12 8.1v7.8M8.1 12h7.8" fill="none" stroke="$hex" '
        'stroke-width="1.7" stroke-linecap="round"/>'
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

/// The assistant's transcript avatar: the Fa brand `>_` glyph on a rounded
/// tile — the same artwork language as the launcher brand tile. [dark]
/// defaults to the theme brightness.
class FaAiAvatar extends StatelessWidget {
  const FaAiAvatar({super.key, this.size = 28, this.dark});

  final double size;

  /// Forces the dark/light form; null follows the theme brightness.
  final bool? dark;

  @override
  Widget build(BuildContext context) {
    final isDark = dark ?? Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      width: size,
      height: size,
      child: SvgPicture.string(
        isDark ? _kFaAiAvatarDarkSvg : _kFaAiAvatarLightSvg,
        fit: BoxFit.contain,
      ),
    );
  }
}

/// 24×24 rendering of the brand tile geometry (see `icon/icon.svg`): the
/// indigo chevron + teal underscore on a dark squircle.
const String _kFaAiAvatarDarkSvg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <defs>
    <linearGradient id="faAvChev" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#5B61F6"/>
      <stop offset="1" stop-color="#3566FF"/>
    </linearGradient>
    <linearGradient id="faAvUnder" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#2EBD9E"/>
      <stop offset="1" stop-color="#48C7E8"/>
    </linearGradient>
  </defs>
  <rect width="24" height="24" rx="6.5" fill="#0b0f16"/>
  <rect x="0.6" y="0.6" width="22.8" height="22.8" rx="5.9" fill="none" stroke="#1c2637" stroke-width="1.1"/>
  <path d="M 7 8.4 L 11.9 11.8 L 7 15.2" fill="none" stroke="url(#faAvChev)" stroke-width="2" stroke-linecap="butt" stroke-linejoin="miter"/>
  <rect x="12.9" y="15.7" width="5.1" height="1.5" fill="url(#faAvUnder)"/>
</svg>
''';

/// Light form (see `icon/icon_light.svg`).
const String _kFaAiAvatarLightSvg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <defs>
    <linearGradient id="faAvChevL" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#5B61F6"/>
      <stop offset="1" stop-color="#3566FF"/>
    </linearGradient>
    <linearGradient id="faAvUnderL" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#2EBD9E"/>
      <stop offset="1" stop-color="#48C7E8"/>
    </linearGradient>
  </defs>
  <rect width="24" height="24" rx="6.5" fill="#fafbfe"/>
  <rect x="0.6" y="0.6" width="22.8" height="22.8" rx="5.9" fill="none" stroke="#e5eaf2" stroke-width="1.1"/>
  <path d="M 7 8.4 L 11.9 11.8 L 7 15.2" fill="none" stroke="url(#faAvChevL)" stroke-width="2" stroke-linecap="butt" stroke-linejoin="miter"/>
  <rect x="12.9" y="15.7" width="5.1" height="1.5" fill="url(#faAvUnderL)"/>
</svg>
''';

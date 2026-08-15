// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The Fa brand mark: a four-pointed "magic" sparkle with a companion star,
/// gradient indigo → teal. Used anywhere the plain `Fa` text chip appeared
/// (floating app button, in-app work bar).
class FaMark extends StatelessWidget {
  const FaMark({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: SvgPicture.string(kFaMarkSvg, fit: BoxFit.contain),
    );
  }
}

/// The Fa brand app tile: rounded square with the gradient `>_` glyph —
/// the same artwork as the platform launcher icons. Light and dark forms
/// match the brand icons; [dark] defaults to the theme brightness.
class FaBrandTile extends StatelessWidget {
  const FaBrandTile({super.key, this.size = 28, this.dark});

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
        isDark ? kFaBrandTileDarkSvg : kFaBrandTileLightSvg,
        fit: BoxFit.contain,
      ),
    );
  }
}

/// Brand tile artwork (1024 viewBox, same geometry as `icon/icon.svg`).
const String kFaBrandTileDarkSvg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="chev" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#5B61F6"/>
      <stop offset="1" stop-color="#3566FF"/>
    </linearGradient>
    <linearGradient id="under" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#2EBD9E"/>
      <stop offset="1" stop-color="#48C7E8"/>
    </linearGradient>
  </defs>
  <rect width="1024" height="1024" rx="224" fill="#0b0f16"/>
  <rect x="16" y="16" width="992" height="992" rx="208" fill="none" stroke="#1c2637" stroke-width="32"/>
  <g transform="translate(520 512) scale(1.15) translate(-520 -592)">
    <path d="M 280 434 L 492 541 L 280 648" fill="none" stroke="url(#chev)" stroke-width="48" stroke-linecap="butt" stroke-linejoin="miter"/>
    <rect x="512" y="712" width="248" height="38" fill="url(#under)"/>
  </g>
</svg>
''';

/// Light form (same geometry as `icon/icon_light.svg`).
const String kFaBrandTileLightSvg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="chev" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#5B61F6"/>
      <stop offset="1" stop-color="#3566FF"/>
    </linearGradient>
    <linearGradient id="under" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0" stop-color="#2EBD9E"/>
      <stop offset="1" stop-color="#48C7E8"/>
    </linearGradient>
  </defs>
  <rect width="1024" height="1024" rx="224" fill="#fafbfe"/>
  <rect x="16" y="16" width="992" height="992" rx="208" fill="none" stroke="#e5eaf2" stroke-width="32"/>
  <g transform="translate(520 512) scale(1.15) translate(-520 -592)">
    <path d="M 280 434 L 492 541 L 280 648" fill="none" stroke="url(#chev)" stroke-width="48" stroke-linecap="butt" stroke-linejoin="miter"/>
    <rect x="512" y="712" width="248" height="38" fill="url(#under)"/>
  </g>
</svg>
''';

/// Inline markup for the Fa sparkle (24×24).
const String kFaMarkSvg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <defs>
    <linearGradient id="fa-g" x1="2" y1="22" x2="22" y2="2" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#818cf8"/>
      <stop offset="1" stop-color="#2dd4bf"/>
    </linearGradient>
  </defs>
  <path fill="url(#fa-g)" d="M12 1.6c.6 0 1 .3 1.2.8l1.8 5.3c.1.3.4.6.7.7l5.3 1.8c.5.2.8.6.8 1.2s-.3 1-.8 1.2l-5.3 1.8c-.3.1-.6.4-.7.7l-1.8 5.3c-.2.5-.6.8-1.2.8s-1-.3-1.2-.8l-1.8-5.3c-.1-.3-.4-.6-.7-.7l-5.3-1.8c-.5-.2-.8-.6-.8-1.2s.3-1 .8-1.2l5.3-1.8c.3-.1.6-.4.7-.7l1.8-5.3c.2-.5.6-.8 1.2-.8z"/>
  <path fill="#2dd4bf" d="M19.5 12.4c.3 0 .5.2.6.4l.8 2.3c0 .2.2.3.3.3l2.3.8c.2.1.4.3.4.6s-.2.5-.4.6l-2.3.8c-.1 0-.3.2-.3.3l-.8 2.3c-.1.2-.3.4-.6.4s-.5-.2-.6-.4l-.8-2.3c0-.1-.2-.3-.3-.3l-2.3-.8c-.2-.1-.4-.3-.4-.6s.2-.5.4-.6l2.3-.8c.1 0 .3-.2.3-.3l.8-2.3c.1-.2.3-.4.6-.4z" opacity=".9"/>
  <circle cx="5" cy="19" r="1.6" fill="#818cf8" opacity=".9"/>
</svg>
''';

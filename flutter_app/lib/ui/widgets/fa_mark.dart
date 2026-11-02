// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart' show FaDesignTokens, FaLogo, buildFaTheme;
import 'package:flutter/material.dart';

/// The canonical B3-square-accent mark used by compact brand actions.
class FaMark extends StatelessWidget {
  const FaMark({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) => FaLogo(size: size);
}

/// The canonical brand app tile, sharing its geometry with the platform
/// launcher icons. [dark] defaults to the ambient theme brightness.
class FaBrandTile extends StatelessWidget {
  const FaBrandTile({super.key, this.size = 28, this.dark});

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

/// Glass dark/light SVG forms of the B3-square-accent geometry in [FaLogo].
const String kFaBrandTileDarkSvg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 68 68">
 <rect x="4" y="4" width="60" height="60" rx="18" fill="#1C1C1E" stroke="#3F8FF7" stroke-width="2"/>
  <path d="M15 28 L22 34 L15 40" fill="none" stroke="#3F8FF7" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M27 42 V26 H38.5" fill="none" stroke="#F5F5F7" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M27 33.5 H35.5" fill="none" stroke="#F5F5F7" stroke-width="2.8" stroke-linecap="round"/>
  <circle cx="43" cy="36" r="5" fill="none" stroke="#F5F5F7" stroke-width="2.6"/>
  <path d="M48 31 V42" fill="none" stroke="#F5F5F7" stroke-width="2.6" stroke-linecap="round"/>
  <circle cx="48" cy="22" r="3.2" fill="#818CF8"/>
</svg>
''';

/// Light form of the canonical mark.
const String kFaBrandTileLightSvg = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 68 68">
 <rect x="4" y="4" width="60" height="60" rx="18" fill="#FFFFFF" stroke="#3F8FF7" stroke-width="2"/>
  <path d="M15 28 L22 34 L15 40" fill="none" stroke="#3F8FF7" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M27 42 V26 H38.5" fill="none" stroke="#1D1D1F" stroke-width="2.8" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M27 33.5 H35.5" fill="none" stroke="#1D1D1F" stroke-width="2.8" stroke-linecap="round"/>
  <circle cx="43" cy="36" r="5" fill="none" stroke="#1D1D1F" stroke-width="2.6"/>
  <path d="M48 31 V42" fill="none" stroke="#1D1D1F" stroke-width="2.6" stroke-linecap="round"/>
  <circle cx="48" cy="22" r="3.2" fill="#4F46E5"/>
</svg>
''';

/// Historical name for the compact mark; now the same canonical artwork.
const String kFaMarkSvg = kFaBrandTileDarkSvg;

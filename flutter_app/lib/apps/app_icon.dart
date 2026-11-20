// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:fa/apps/apps_store.dart';

/// Deterministic colors shared by launcher icons, live widgets and catalog
/// tiles. Artwork supplies the accent when possible; otherwise a stable hash
/// of the app id picks one (never the process-dependent String.hashCode).
abstract final class AppIconPalette {
  static const _accents = [
    Color(0xFF5B7CFA),
    Color(0xFF8B5CF6),
    Color(0xFFEC4899),
    Color(0xFFF97316),
    Color(0xFFF59E0B),
    Color(0xFF22C55E),
    Color(0xFF14B8A6),
    Color(0xFF06B6D4),
  ];

  static final _hexColor = RegExp(
    r'#([0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3})(?![0-9a-fA-F])',
  );

  static Color accentFor(String seed, [String? artwork]) {
    for (final match in _hexColor.allMatches(artwork ?? '')) {
      final hex = match.group(1)!;
      // White/near-white glyph paths are artwork, not the app's accent.
      final rgb = hex.length == 3
          ? hex.split('').map((c) => '$c$c').join()
          : hex.substring(hex.length - 6);
      final red = int.parse(rgb.substring(0, 2), radix: 16);
      final green = int.parse(rgb.substring(2, 4), radix: 16);
      final blue = int.parse(rgb.substring(4, 6), radix: 16);
      if (red > 238 && green > 238 && blue > 238) continue;
      if (red < 14 && green < 14 && blue < 14) continue;
      return Color(0xFF000000 | (red << 16) | (green << 8) | blue);
    }
    var hash = 0x811C9DC5;
    for (final unit in seed.codeUnits) {
      hash = (hash ^ unit) * 0x01000193 & 0xFFFFFFFF;
    }
    return _accents[hash % _accents.length];
  }

  static List<Color> gradientFor(Color accent, Brightness brightness) {
    final hsl = HSLColor.fromColor(accent);
    // Apple-like tinted glass: preserve the artwork's hue, but remove the
    // neon saturation before mixing the gradient. Light tiles are genuine
    // pastels (dark foreground); dark tiles stay deep and desaturated.
    final muted = hsl
        .withSaturation((hsl.saturation * .42).clamp(.12, .38))
        .toColor();
    final light = brightness == Brightness.light;
    return [
      light
          ? Color.lerp(muted, const Color(0xFFFFFFFF), .68)!
          : Color.lerp(muted, const Color(0xFF000000), .20)!,
      light
          ? Color.lerp(muted, const Color(0xFFFFFFFF), .54)!
          : Color.lerp(muted, const Color(0xFF000000), .38)!,
      light
          ? Color.lerp(muted, const Color(0xFF000000), .04)!
          : Color.lerp(muted, const Color(0xFF000000), .52)!,
    ];
  }

  static Color foregroundFor(Brightness brightness) =>
      brightness == Brightness.light
      ? const Color(0xFF2D3748)
      : const Color(0xFFFFFFFF);

  /// SVGs commonly paint their own saturated background over the badge
  /// gradient. Filter the artwork too, preserving whites/darks and hue while
  /// removing the acid-green/hot-pink cast called out in visual review.
  static const artworkFilter = ColorFilter.matrix(<double>[
    .64585,
    .32175,
    .0324,
    0,
    0,
    .09585,
    .87175,
    .0324,
    0,
    0,
    .09585,
    .32175,
    .5824,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]);

  static ShapeDecoration decoration({
    required String seed,
    required Brightness brightness,
    required double size,
    String? artwork,
    Color? accent,
  }) {
    final color = accent ?? accentFor(seed, artwork);
    return ShapeDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: gradientFor(color, brightness),
      ),
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(size * .22),
        side: BorderSide(
          color: brightness == Brightness.light
              ? const Color(0xFF000000).withValues(alpha: .06)
              : const Color(0xFFFFFFFF).withValues(alpha: .12),
        ),
      ),
      shadows: [
        BoxShadow(
          color: const Color(
            0xFF000000,
          ).withValues(alpha: brightness == Brightness.light ? .10 : .18),
          blurRadius: size * .16,
          offset: Offset(0, size * .045),
        ),
      ],
    );
  }
}

/// A continuous-corner, muted-color tile used by Launchpad-style surfaces.
/// [child] is normally the app artwork or an adaptive system glyph.
class AppIconBadge extends StatelessWidget {
  const AppIconBadge({
    super.key,
    required this.seed,
    required this.size,
    required this.child,
    this.artwork,
    this.accent,
  });

  final String seed;
  final double size;
  final Widget child;
  final String? artwork;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(size * .22);
    return Container(
      width: size,
      height: size,
      decoration: AppIconPalette.decoration(
        seed: seed,
        artwork: artwork,
        accent: accent,
        brightness: Theme.of(context).brightness,
        size: size,
      ),
      child: ClipRSuperellipse(
        borderRadius: radius,
        child: ColorFiltered(
          colorFilter: AppIconPalette.artworkFilter,
          child: SizedBox.expand(child: child),
        ),
      ),
    );
  }
}

/// Curated vector artwork for built-in/catalog apps whose original manifest
/// icons were placeholder-quality. The good manifest assets (2048, Fa Craft,
/// Calculator, Calendar, Stocks, …) still load from the shared env unchanged.
///
/// Every override uses the same 64pt keyline, 6–10pt optical inset, restrained
/// two-stop materials, and fine highlight strokes. Keeping the artwork here
/// also upgrades existing installs; it does not require rewriting user files.
abstract final class AppIconArtwork {
  static String? svgFor(String appId) => switch (appId) {
    'settings' || 'system:settings' => _settings,
    'files' || 'system:files' => _files,
    'networks' || 'system:networks' => _networks,
    'contacts' => _contacts,
    'reminders' => _reminders,
    'adaptive-dashboard' => _dashboard,
    'm3-showcase' => _componentShowcase,
    '3d-viewer' => _modelViewer,
    '3d-game' => _dodgeGame,
    'neon-breakout-3d' => _breakout,
    'voxel-sandbox' => _voxelSandbox,
    _ => null,
  };

  static Color? accentFor(String appId) => switch (appId) {
    'settings' || 'system:settings' => const Color(0xFF626672),
    'files' || 'system:files' => const Color(0xFF4C6A8A),
    'networks' || 'system:networks' => const Color(0xFF43766F),
    'contacts' => const Color(0xFF73859B),
    'reminders' => const Color(0xFFB68A4A),
    'adaptive-dashboard' => const Color(0xFF4B5B70),
    'm3-showcase' => const Color(0xFF6B5F7E),
    '3d-viewer' => const Color(0xFF59677F),
    '3d-game' => const Color(0xFF35677A),
    'neon-breakout-3d' => const Color(0xFF252D49),
    'voxel-sandbox' => const Color(0xFF596B62),
    _ => null,
  };

  static const _settings = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <defs>
    <linearGradient id="metal" x1="12" y1="8" x2="52" y2="56" gradientUnits="userSpaceOnUse">
      <stop stop-color="#F0F3F6"/><stop offset=".46" stop-color="#AAB2BD"/><stop offset="1" stop-color="#68717E"/>
    </linearGradient>
    <linearGradient id="hub" x1="24" y1="22" x2="42" y2="44" gradientUnits="userSpaceOnUse">
      <stop stop-color="#596270"/><stop offset="1" stop-color="#252C36"/>
    </linearGradient>
  </defs>
  <g fill="url(#metal)" stroke="#FFFFFF" stroke-opacity=".2" stroke-width=".7">
    <rect x="28.5" y="4" width="7" height="16" rx="2.2"/>
    <rect x="28.5" y="4" width="7" height="16" rx="2.2" transform="rotate(45 32 32)"/>
    <rect x="28.5" y="4" width="7" height="16" rx="2.2" transform="rotate(90 32 32)"/>
    <rect x="28.5" y="4" width="7" height="16" rx="2.2" transform="rotate(135 32 32)"/>
    <rect x="28.5" y="4" width="7" height="16" rx="2.2" transform="rotate(180 32 32)"/>
    <rect x="28.5" y="4" width="7" height="16" rx="2.2" transform="rotate(225 32 32)"/>
    <rect x="28.5" y="4" width="7" height="16" rx="2.2" transform="rotate(270 32 32)"/>
    <rect x="28.5" y="4" width="7" height="16" rx="2.2" transform="rotate(315 32 32)"/>
    <circle cx="32" cy="32" r="21"/>
  </g>
  <circle cx="32" cy="32" r="12.5" fill="url(#hub)" stroke="#F8FAFC" stroke-opacity=".55"/>
  <circle cx="32" cy="32" r="7.2" fill="#AAB4C0" stroke="#1F2937" stroke-opacity=".55"/>
  <path d="M18 20A20 20 0 0 1 39 13" fill="none" stroke="#FFFFFF" stroke-opacity=".48" stroke-width="1.4" stroke-linecap="round"/>
</svg>''';

  static const _files = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <defs><linearGradient id="folder" x1="10" y1="12" x2="52" y2="54" gradientUnits="userSpaceOnUse"><stop stop-color="#C9DCF0"/><stop offset=".52" stop-color="#82A7C9"/><stop offset="1" stop-color="#52749A"/></linearGradient></defs>
  <path d="M8 18a6 6 0 0 1 6-6h12l6 6h18a6 6 0 0 1 6 6v25a6 6 0 0 1-6 6H14a6 6 0 0 1-6-6Z" fill="#33465D" opacity=".24" transform="translate(0 1)"/>
  <path d="M8 17a6 6 0 0 1 6-6h12l6 6h18a6 6 0 0 1 6 6v25a6 6 0 0 1-6 6H14a6 6 0 0 1-6-6Z" fill="url(#folder)" stroke="#EAF3FC" stroke-opacity=".55"/>
  <path d="M9 28h46l-4 21a6 6 0 0 1-6 5H13a5 5 0 0 1-5-5Z" fill="#A9C5DF" fill-opacity=".48"/>
  <path d="M13 29h38" stroke="#FFFFFF" stroke-opacity=".55" stroke-linecap="round"/>
</svg>''';

  static const _networks = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <defs><linearGradient id="node" x1="18" y1="12" x2="46" y2="52" gradientUnits="userSpaceOnUse"><stop stop-color="#D9EAE6"/><stop offset="1" stop-color="#719B93"/></linearGradient></defs>
  <g fill="none" stroke="#C4DAD5" stroke-width="3" stroke-linecap="round"><path d="M32 22v12M18 42l14-8 14 8"/></g>
  <g fill="url(#node)" stroke="#F4FAF8" stroke-opacity=".65"><circle cx="32" cy="15" r="8"/><circle cx="14" cy="47" r="8"/><circle cx="50" cy="47" r="8"/></g>
  <circle cx="32" cy="32" r="5" fill="#4F7D74" stroke="#DDF0EB"/>
  <g fill="#527E76"><circle cx="32" cy="15" r="2.5"/><circle cx="14" cy="47" r="2.5"/><circle cx="50" cy="47" r="2.5"/></g>
</svg>''';

  static const _contacts = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <defs>
    <linearGradient id="paper" x1="15" y1="7" x2="50" y2="57" gradientUnits="userSpaceOnUse"><stop stop-color="#FFFFFF"/><stop offset="1" stop-color="#D8E0E8"/></linearGradient>
    <linearGradient id="spine" x1="10" y1="8" x2="23" y2="56" gradientUnits="userSpaceOnUse"><stop stop-color="#91A2B8"/><stop offset="1" stop-color="#53657D"/></linearGradient>
    <linearGradient id="person" x1="31" y1="18" x2="43" y2="46" gradientUnits="userSpaceOnUse"><stop stop-color="#98A8BA"/><stop offset="1" stop-color="#617188"/></linearGradient>
  </defs>
  <rect x="11" y="7" width="44" height="52" rx="8" fill="#263445" opacity=".2"/>
  <rect x="10" y="5" width="44" height="52" rx="8" fill="url(#paper)" stroke="#FFFFFF" stroke-opacity=".8"/>
  <path d="M18 5h7v52h-7a8 8 0 0 1-8-8V13a8 8 0 0 1 8-8Z" fill="url(#spine)"/>
  <g fill="#DDE5EC" stroke="#53657D" stroke-opacity=".55"><rect x="12" y="14" width="11" height="4" rx="2"/><rect x="12" y="29" width="11" height="4" rx="2"/><rect x="12" y="44" width="11" height="4" rx="2"/></g>
  <circle cx="39" cy="24" r="7.5" fill="url(#person)"/>
  <path d="M27 46c.7-8 5.1-12 12-12s11.3 4 12 12c.1 1.8-1.1 3-3 3H30c-1.9 0-3.1-1.2-3-3Z" fill="url(#person)"/>
  <path d="M29 11h17" stroke="#FFFFFF" stroke-opacity=".85" stroke-linecap="round"/>
</svg>''';

  static const _reminders = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <defs><linearGradient id="list" x1="14" y1="7" x2="48" y2="57" gradientUnits="userSpaceOnUse"><stop stop-color="#FFFFFF"/><stop offset="1" stop-color="#E3E7EB"/></linearGradient></defs>
  <rect x="10" y="7" width="45" height="52" rx="9" fill="#493B2A" opacity=".16"/>
  <rect x="9" y="5" width="45" height="52" rx="9" fill="url(#list)" stroke="#FFFFFF" stroke-opacity=".8"/>
  <g stroke="#98A2AE" stroke-width="3" stroke-linecap="round"><path d="M26 20h18"/><path d="M26 33h18"/><path d="M26 46h13"/></g>
  <g><circle cx="18" cy="20" r="3.5" fill="#D89042"/><circle cx="18" cy="33" r="3.5" fill="#6C8EAE"/><circle cx="18" cy="46" r="3.5" fill="#72A184"/></g>
  <path d="M16 10h30" stroke="#FFFFFF" stroke-linecap="round" stroke-opacity=".9"/>
</svg>''';

  static const _dashboard = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <defs><linearGradient id="window" x1="10" y1="8" x2="54" y2="56" gradientUnits="userSpaceOnUse"><stop stop-color="#43536A"/><stop offset="1" stop-color="#202C3C"/></linearGradient><linearGradient id="bars" x1="18" y1="28" x2="43" y2="48" gradientUnits="userSpaceOnUse"><stop stop-color="#B6D4D0"/><stop offset="1" stop-color="#65988F"/></linearGradient></defs>
  <rect x="6" y="8" width="52" height="49" rx="9" fill="url(#window)" stroke="#C6D2E0" stroke-opacity=".45"/>
  <path d="M6 19h52" stroke="#A7B6C8" stroke-opacity=".5"/>
  <g fill="#AAB7C6"><circle cx="12" cy="13.5" r="1.5"/><circle cx="17" cy="13.5" r="1.5"/><circle cx="22" cy="13.5" r="1.5"/></g>
  <path d="M13 48h38" stroke="#8291A4" stroke-opacity=".65"/>
  <g fill="url(#bars)"><rect x="15" y="35" width="6" height="13" rx="2"/><rect x="25" y="28" width="6" height="20" rx="2"/><rect x="35" y="32" width="6" height="16" rx="2"/></g>
  <path d="m15 29 9-6 9 4 15-9" fill="none" stroke="#E4EEF2" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M43 18h5v5" fill="none" stroke="#E4EEF2" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
</svg>''';

  static const _componentShowcase = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <defs><linearGradient id="panel" x1="10" y1="8" x2="54" y2="56" gradientUnits="userSpaceOnUse"><stop stop-color="#544C64"/><stop offset="1" stop-color="#292533"/></linearGradient></defs>
  <rect x="7" y="7" width="50" height="50" rx="11" fill="url(#panel)" stroke="#DCD4E8" stroke-opacity=".45"/>
  <g fill="none" stroke="#DCD5E7" stroke-width="2"><rect x="14" y="14" width="15" height="15" rx="4"/><circle cx="43" cy="21.5" r="7.5"/><rect x="14" y="36" width="15" height="14" rx="7"/></g>
  <path d="M36 43h14M43 36v14" stroke="#AC9ABC" stroke-width="3" stroke-linecap="round"/>
  <path d="M17 18h8" stroke="#FFFFFF" stroke-opacity=".55" stroke-linecap="round"/>
</svg>''';

  static const _modelViewer = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <defs><linearGradient id="top" x1="18" y1="12" x2="46" y2="31" gradientUnits="userSpaceOnUse"><stop stop-color="#E5EBF2"/><stop offset="1" stop-color="#A6B5C8"/></linearGradient><linearGradient id="left" x1="12" y1="25" x2="34" y2="54" gradientUnits="userSpaceOnUse"><stop stop-color="#94A7BE"/><stop offset="1" stop-color="#566B86"/></linearGradient><linearGradient id="right" x1="34" y1="28" x2="52" y2="52" gradientUnits="userSpaceOnUse"><stop stop-color="#7288A4"/><stop offset="1" stop-color="#364A63"/></linearGradient></defs>
  <ellipse cx="32" cy="52" rx="23" ry="6" fill="none" stroke="#AFC0D2" stroke-opacity=".45"/>
  <path d="m32 7 23 13-23 13-23-13Z" fill="url(#top)" stroke="#F4F7FA" stroke-opacity=".7"/>
  <path d="m9 20 23 13v25L9 45Z" fill="url(#left)" stroke="#D8E2EC" stroke-opacity=".5"/>
  <path d="m32 33 23-13v25L32 58Z" fill="url(#right)" stroke="#C4D2E0" stroke-opacity=".45"/>
  <path d="M32 33v25M9 20l23 13 23-13" fill="none" stroke="#EDF3F8" stroke-opacity=".4"/>
  <circle cx="51" cy="49" r="3" fill="#C3D2DF" stroke="#536A82"/>
</svg>''';

  static const _dodgeGame = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <defs><linearGradient id="cubeTop" x1="18" y1="10" x2="46" y2="30" gradientUnits="userSpaceOnUse"><stop stop-color="#B9D9E2"/><stop offset="1" stop-color="#6E9CAD"/></linearGradient><linearGradient id="cubeSide" x1="14" y1="26" x2="49" y2="54" gradientUnits="userSpaceOnUse"><stop stop-color="#56869B"/><stop offset="1" stop-color="#263F57"/></linearGradient></defs>
  <path d="M7 50h14M43 50h14M11 55h9M44 55h9" stroke="#A7C6D2" stroke-opacity=".55" stroke-width="2" stroke-linecap="round"/>
  <path d="m32 7 21 12-21 12-21-12Z" fill="url(#cubeTop)" stroke="#E0F0F4" stroke-opacity=".65"/>
  <path d="m11 19 21 12v24L11 43Z" fill="url(#cubeSide)" stroke="#C0D9E2" stroke-opacity=".45"/>
  <path d="m32 31 21-12v24L32 55Z" fill="#345A72" stroke="#ABC9D5" stroke-opacity=".4"/>
  <path d="m25 39 7 4 7-4" fill="none" stroke="#D7E9ED" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M32 31v24" stroke="#D9E8ED" stroke-opacity=".35"/>
</svg>''';

  static const _breakout = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <defs><linearGradient id="glass" x1="10" y1="7" x2="54" y2="57" gradientUnits="userSpaceOnUse"><stop stop-color="#303C59"/><stop offset="1" stop-color="#121A2C"/></linearGradient><linearGradient id="paddle" x1="20" y1="49" x2="44" y2="53" gradientUnits="userSpaceOnUse"><stop stop-color="#B4D9DF"/><stop offset="1" stop-color="#659CAA"/></linearGradient></defs>
  <rect x="6" y="5" width="52" height="54" rx="11" fill="url(#glass)" stroke="#7FA7BA" stroke-opacity=".55"/>
  <g stroke="#E4EEF5" stroke-opacity=".28" stroke-width=".7"><rect x="13" y="13" width="10" height="7" rx="2" fill="#8B7C9E"/><rect x="27" y="13" width="10" height="7" rx="2" fill="#718FA9"/><rect x="41" y="13" width="10" height="7" rx="2" fill="#6D9A9C"/><rect x="13" y="24" width="10" height="7" rx="2" fill="#718FA9"/><rect x="27" y="24" width="10" height="7" rx="2" fill="#6D9A9C"/><rect x="41" y="24" width="10" height="7" rx="2" fill="#8B7C9E"/></g>
  <circle cx="41" cy="39" r="4" fill="#E4F0F2"/><circle cx="40" cy="38" r="1.4" fill="#FFFFFF"/>
  <path d="m37 42-7 6" stroke="#83ADB9" stroke-width="1.5" stroke-linecap="round"/>
  <rect x="18" y="49" width="28" height="5" rx="2.5" fill="url(#paddle)"/>
</svg>''';

  static const _voxelSandbox = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
  <defs><linearGradient id="grass" x1="15" y1="10" x2="47" y2="34" gradientUnits="userSpaceOnUse"><stop stop-color="#B7C9B6"/><stop offset="1" stop-color="#728F78"/></linearGradient><linearGradient id="earth" x1="13" y1="28" x2="49" y2="55" gradientUnits="userSpaceOnUse"><stop stop-color="#8C8376"/><stop offset="1" stop-color="#4E5150"/></linearGradient></defs>
  <path d="m32 6 24 14-24 14-24-14Z" fill="url(#grass)" stroke="#E2EBDF" stroke-opacity=".55"/>
  <path d="m8 20 24 14v24L8 44Z" fill="url(#earth)" stroke="#CCD6CE" stroke-opacity=".35"/>
  <path d="m32 34 24-14v24L32 58Z" fill="#59645F" stroke="#C1CEC5" stroke-opacity=".35"/>
  <path d="m32 20 10 6-10 6-10-6Z" fill="#7D7468"/><path d="m22 26 10 6v10l-10-6Z" fill="#665E55"/><path d="m32 32 10-6v10l-10 6Z" fill="#4E4A46"/>
  <path d="M8 20l24 14 24-14M32 34v24" fill="none" stroke="#E3EAE2" stroke-opacity=".3"/>
</svg>''';
}

/// Renders a JS app's manifest icon: an emoji (the common case), inline SVG
/// markup (`"icon": "<svg …>"`), or an SVG file inside the app folder
/// (`"icon": "icon.svg"`, resolved as `apps/<id>/icon.svg` through the
/// shared env so the agent can drop icons next to the manifest).
///
/// [framed] opts into the colorful continuous-corner Launchpad treatment.
/// The default remains the bare artwork for small toolbar/dock affordances.
class AppIcon extends StatelessWidget {
  const AppIcon({
    super.key,
    required this.app,
    required this.env,
    this.size = 24,
    this.framed = false,
  });

  final JsAppInfo app;
  final ExecutionEnv env;
  final double size;
  final bool framed;

  static const String _fallbackIcon = '📦';

  bool get _isInlineSvg => app.icon.trimLeft().startsWith('<svg');
  bool get _isSvgFile => app.icon.toLowerCase().endsWith('.svg');

  @override
  Widget build(BuildContext context) {
    final curated = AppIconArtwork.svgFor(app.id);
    if (curated != null) {
      return _maybeFramed(
        _svg(curated),
        artwork: curated,
        accent: AppIconArtwork.accentFor(app.id),
      );
    }
    if (_isInlineSvg) return _maybeFramed(_svg(app.icon));
    if (_isSvgFile) {
      return FutureBuilder<String>(
        future: _loadSvgFile(),
        builder: (context, snapshot) => _maybeFramed(_svg(snapshot.data ?? '')),
      );
    }
    final text = Text(
      app.icon.isEmpty ? _fallbackIcon : app.icon,
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: size * (framed ? .46 : .9), height: 1),
    );
    return framed ? _maybeFramed(Center(child: text)) : text;
  }

  Widget _maybeFramed(Widget child, {String? artwork, Color? accent}) {
    if (!framed) return child;
    return AppIconBadge(
      seed: app.id,
      artwork: artwork ?? app.icon,
      size: size,
      accent: accent,
      child: child,
    );
  }

  Future<String> _loadSvgFile() async {
    final result = await env.readTextFile('${app.dir}/${app.icon}');
    return result.valueOrNull ?? '';
  }

  Widget _svg(String markup) {
    if (markup.trim().isEmpty) {
      final fallback = Text(
        _fallbackIcon,
        style: TextStyle(fontSize: size * (framed ? .46 : .9), height: 1),
      );
      return framed ? Center(child: fallback) : fallback;
    }
    return SizedBox(
      width: size,
      height: size,
      child: SvgPicture.string(markup, fit: BoxFit.contain),
    );
  }
}

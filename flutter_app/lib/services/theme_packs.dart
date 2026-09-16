// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:math' show pow;
import 'dart:typed_data' show Uint8List;

import 'package:flutter/material.dart';

import 'package:fa/ui/app_theme.dart';

/// A validated theme pack: declarative DATA only (issue #169). The security
/// model is structural — a pack is schema-validated JSON plus at most one
/// wallpaper image, never code, never remote URLs, never anything else.
///
/// Everything a pack can change rides through the fa_ui theme layer:
/// [packFaUiTheme] maps a spec onto [FaUiTheme] palettes, so the whole app
/// (Material theme + every [FahColors.of] consumer) re-skins at once.
final class ThemePackSpec {
  const ThemePackSpec({
    required this.id,
    required this.name,
    required this.version,
    this.dark,
    this.light,
    this.fontFamily,
    this.wallpaper,
    this.contrastWarnings = const [],
  });

  /// Stable install id (the `themes/<id>/` directory): the slug of [name].
  final String id;

  /// Human-readable pack name (shown in settings and consent prompts).
  final String name;

  /// Pack version, `major.minor.patch`.
  final String version;

  /// The dark-variant colors; null keeps the stock light look (a pack that
  /// ships only one variant themes only that brightness).
  final ThemePackColors? dark;

  /// The light-variant colors; null keeps the stock dark look.
  final ThemePackColors? light;

  /// Optional UI typeface override (the host must bundle the family).
  final String? fontFamily;

  /// The declared wallpaper; null = colors-only pack (E4: the previous
  /// wallpaper stays untouched).
  final ThemePackWallpaper? wallpaper;

  /// Non-blocking WCAG contrast warnings computed at validation time
  /// (shown before applying, never silently ignored).
  final List<String> contrastWarnings;

  /// The [FaUiTheme] that applies this pack app-wide.
  FaUiTheme toFaUiTheme() => FaUiTheme(
    darkPalette: dark?.toFahColors(FahColors.dark),
    lightPalette: light?.toFahColors(FahColors.light),
    fontFamily: fontFamily,
  );
}

/// One brightness variant of pack colors. Null slots keep the stock value
/// for that brightness; the 14 slot names mirror the `jsr.theme` map keys
/// (see `js_theme.dart`) so JS apps and packs speak one color vocabulary.
final class ThemePackColors {
  const ThemePackColors({
    this.background,
    this.surface,
    this.surfaceAlt,
    this.border,
    this.borderBright,
    this.text,
    this.muted,
    this.accent,
    this.accent2,
    this.onAccent,
    this.error,
    this.userBubble,
    this.userBubbleBorder,
    this.codeBg,
  });

  final Color? background;
  final Color? surface;
  final Color? surfaceAlt;
  final Color? border;
  final Color? borderBright;
  final Color? text;
  final Color? muted;
  final Color? accent;
  final Color? accent2;
  final Color? onAccent;
  final Color? error;
  final Color? userBubble;
  final Color? userBubbleBorder;
  final Color? codeBg;

  /// Maps the variant onto the stock palette of its brightness: explicit
  /// slots override, accents re-derive the gradient and (unless the pack
  /// sets them explicitly) the bubble tints — exactly the stock derivation.
  FahColors toFahColors(FahColors stock) => stock
      .override(
        bg: background,
        panel: surface,
        panelAlt: surfaceAlt,
        border: border,
        borderBright: borderBright,
        text: text,
        dim: muted,
        onAccent: onAccent,
        error: error,
        codeBg: codeBg,
      )
      .withAccents(indigo: accent2, teal: accent)
      .withUserBubble(color: userBubble, border: userBubbleBorder);
}

/// The declared wallpaper: a bundled image file (validated at install —
/// png/jpg/webp, ≤ [maxWallpaperBytes], no remote URLs, no traversal) drawn
/// behind the chat transcript and the apps grid at [fit] and [opacity].
final class ThemePackWallpaper {
  const ThemePackWallpaper({
    required this.asset,
    this.fit = BoxFit.cover,
    this.opacity = 1,
  });

  /// File name of the image inside the installed pack directory (flat name,
  /// no path segments).
  final String asset;

  /// How the image scales to the surface.
  final BoxFit fit;

  /// The image's opacity over the themed background, 0..1.
  final double opacity;

  /// Parses the schema's fit token (unknown or missing → cover).
  static BoxFit fitFor(String? token) => fitModes[token] ?? BoxFit.cover;
}

/// Outcome of validating one pack import: either a ready [spec], or the
/// human-readable rejection [reasons] (shown verbatim to the user).
typedef ThemePackValidation = ({
  ThemePackSpec? spec,
  List<String> reasons,
  List<String> warnings,
});

/// The single wallpaper asset may be at most 8 MB.
const int maxWallpaperBytes = 8 * 1024 * 1024;

/// The only file extensions a pack image asset may use.
const Set<String> wallpaperExtensions = {'png', 'jpg', 'jpeg', 'webp'};

/// The 14 color slots a variant may set (the `jsr.theme` vocabulary).
const Set<String> packColorKeys = {
  'background',
  'surface',
  'surfaceAlt',
  'border',
  'borderBright',
  'text',
  'muted',
  'accent',
  'accent2',
  'onAccent',
  'error',
  'userBubble',
  'userBubbleBorder',
  'codeBg',
};

final RegExp _hexColor = RegExp(r'^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$');
final RegExp _semver = RegExp(r'^\d+\.\d+\.\d+$');
final RegExp _fontFamily = RegExp(r'^[A-Za-z0-9][A-Za-z0-9 _-]{0,47}$');

/// A flat, trusted file table handed to validation: name → bytes. Install
/// paths build it from a zip (entries pre-checked for traversal/symlinks)
/// or from an already-sandboxed directory listing.
typedef ThemePackFiles = Map<String, Uint8List>;

/// One declarative validation rule (issue #484): a single schema or
/// security check over the accumulating [ThemePackDraft]. A rule appends
/// rejection reasons and stages its parse; it never throws and never
/// stops the fold — staging is [validateThemePack]'s job. A new or
/// changed rule is one entry in [themePackRules].
typedef ThemePackRule = void Function(ThemePackDraft draft);

/// The validation accumulator: the raw pack input plus everything the
/// rules staged so far. Rules run in [themePackRules] order, so a rule
/// may read an earlier rule's output (the wallpaper build rule reads the
/// asset name the asset rule vetted, for instance).
final class ThemePackDraft {
  ThemePackDraft(this.json, this.files);

  /// The decoded `theme.json`.
  final Map<String, Object?> json;

  /// The sibling files (name → bytes).
  final ThemePackFiles files;

  /// Rejection reasons accumulated so far — non-empty rejects the pack.
  final List<String> reasons = [];

  /// The `colors` section, only when it is a non-empty object.
  Map<String, Object?>? colorsSection;

  /// The `typography.fontFamily`, only after the family name check.
  String? fontFamily;

  /// The `wallpaper` section, only when it is an object.
  Map<String, Object?>? wallpaperSection;

  /// The wallpaper asset name, only after the name/file screens passed.
  String? wallpaperAsset;

  /// Parsed pack parts, valid when [reasons] stays empty.
  ThemePackColors? dark;
  ThemePackColors? light;
  ThemePackWallpaper? wallpaper;
}

/// The identity gate: unknown keys, name, version. These reject before
/// the body rules run, so their reasons are never buried by noise.
const List<ThemePackRule> _gateRules = [
  _unknownTopKeysRule,
  _packNameRule,
  _packVersionRule,
];

/// The body rules: colors, typography, wallpaper, the file table.
const List<ThemePackRule> _bodyRules = [
  _colorsShapeRule,
  _colorsVariantsRule,
  _typographyRule,
  _wallpaperShapeRule,
  _wallpaperAssetRule,
  _wallpaperFitRule,
  _wallpaperOpacityRule,
  _wallpaperBuildRule,
  _packFilesRule,
];

/// Every validation rule in run order (gate, then body). Public so the
/// per-rule suite enumerates the full list — a rule without a firing
/// fixture fails the tests (issue #484 AC3).
const List<ThemePackRule> themePackRules = [..._gateRules, ..._bodyRules];

void _unknownTopKeysRule(ThemePackDraft d) {
  _rejectUnknownKeys(
    d.json,
    const {'name', 'version', 'colors', 'typography', 'wallpaper'},
    'unknown theme.json keys',
    d.reasons,
  );
}

void _packNameRule(ThemePackDraft d) {
  final name = d.json['name'];
  if (name is! String || name.trim().isEmpty || name.length > 64) {
    d.reasons.add('name must be a non-empty string (≤ 64 chars)');
  }
}

void _packVersionRule(ThemePackDraft d) {
  final version = d.json['version'];
  if (version is! String || !_semver.hasMatch(version)) {
    d.reasons.add('version must be major.minor.patch (e.g. 1.0.0)');
  }
}

void _colorsShapeRule(ThemePackDraft d) {
  final colors = d.json['colors'];
  if (colors == null) return;
  if (colors is! Map<String, Object?> || colors.isEmpty) {
    d.reasons.add('colors must be an object with dark and/or light variants');
    return;
  }
  d.colorsSection = colors;
  _rejectUnknownKeys(
    colors,
    const {'dark', 'light'},
    'unknown color variants',
    d.reasons,
  );
}

void _colorsVariantsRule(ThemePackDraft d) {
  final colors = d.colorsSection;
  if (colors == null) return;
  d.dark = _parseVariant(colors, 'dark', d.reasons);
  d.light = _parseVariant(colors, 'light', d.reasons);
  if (d.dark == null && d.light == null && d.reasons.isEmpty) {
    d.reasons.add('colors needs at least one of dark or light');
  }
}

void _typographyRule(ThemePackDraft d) {
  final typography = d.json['typography'];
  if (typography == null) return;
  if (typography is! Map<String, Object?>) {
    d.reasons.add('typography must be an object');
    return;
  }
  _rejectUnknownKeys(
    typography,
    const {'fontFamily'},
    'unknown typography keys',
    d.reasons,
  );
  final family = typography['fontFamily'];
  if (family is! String || !_fontFamily.hasMatch(family)) {
    d.reasons.add('typography.fontFamily must be a plain font name');
  } else {
    d.fontFamily = family;
  }
}

void _wallpaperShapeRule(ThemePackDraft d) {
  final wp = d.json['wallpaper'];
  if (wp == null) return;
  if (wp is! Map<String, Object?>) {
    d.reasons.add('wallpaper must be an object');
    return;
  }
  d.wallpaperSection = wp;
  _rejectUnknownKeys(
    wp,
    const {'asset', 'fit', 'opacity'},
    'unknown wallpaper keys',
    d.reasons,
  );
}

void _wallpaperAssetRule(ThemePackDraft d) {
  final wp = d.wallpaperSection;
  if (wp == null) return;
  final asset = wp['asset'];
  if (asset is! String || !_isSafeAssetName(asset)) {
    d.reasons.add(
      'wallpaper.asset must be a bundled file name (no paths, no URLs)',
    );
    return;
  }
  d.wallpaperAsset = asset;
  final bytes = d.files[asset];
  if (bytes == null) {
    d.reasons.add('wallpaper asset missing from the pack: $asset');
    return;
  }
  // Defense in depth: the name screen already pinned the extension, so
  // this only fires if the two screens ever drift apart.
  if (!wallpaperExtensions.contains(assetExtension(asset))) {
    d.reasons.add(
      'wallpaper asset must be png, jpg or webp (got .${assetExtension(asset)})',
    );
  }
  if (bytes.length > maxWallpaperBytes) {
    d.reasons.add(
      'wallpaper asset is ${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB '
      '(max 8 MB)',
    );
  }
}

void _wallpaperFitRule(ThemePackDraft d) {
  // Null asset ⇒ the asset rule rejected (or never ran a section): the
  // fit/opacity checks live inside its pass, exactly as before.
  if (d.wallpaperAsset == null) return;
  final fit = d.wallpaperSection!['fit'];
  if (fit != null && (fit is! String || !fitModes.containsKey(fit))) {
    d.reasons.add('wallpaper.fit must be one of: ${fitModes.keys.join(', ')}');
  }
}

void _wallpaperOpacityRule(ThemePackDraft d) {
  if (d.wallpaperAsset == null) return;
  final opacity = d.wallpaperSection!['opacity'];
  if (opacity != null && (opacity is! num || opacity < 0 || opacity > 1)) {
    d.reasons.add('wallpaper.opacity must be a number between 0 and 1');
  }
}

void _wallpaperBuildRule(ThemePackDraft d) {
  final asset = d.wallpaperAsset;
  if (asset == null) return;
  final fit = d.wallpaperSection!['fit'];
  final opacity = d.wallpaperSection!['opacity'];
  d.wallpaper = ThemePackWallpaper(
    asset: asset,
    fit: ThemePackWallpaper.fitFor(fit is String ? fit : null),
    opacity: opacity is num ? opacity.toDouble() : kWallpaperOpacityDefault,
  );
}

void _packFilesRule(ThemePackDraft d) {
  final expected = <String>{if (d.wallpaper != null) d.wallpaper!.asset};
  for (final entry in d.files.entries) {
    if (!expected.contains(entry.key)) {
      d.reasons.add(
        'unexpected file in pack (only theme.json and the declared wallpaper '
        'are allowed): $entry.key',
      );
    }
  }
}

/// Appends the shared unknown-key rejection (sorted key list after a
/// `label: ` prefix) and returns the unknown keys.
List<String> _rejectUnknownKeys(
  Map<String, Object?> section,
  Set<String> allowed,
  String label,
  List<String> reasons,
) {
  final unknown = section.keys.where((k) => !allowed.contains(k)).toList()
    ..sort();
  if (unknown.isNotEmpty) {
    reasons.add('$label: ${unknown.join(', ')}');
  }
  return unknown;
}

bool _foldRules(ThemePackDraft d, List<ThemePackRule> rules) {
  for (final rule in rules) {
    rule(d);
  }
  return d.reasons.isNotEmpty;
}

ThemePackValidation _rejected(ThemePackDraft d) =>
    (spec: null, reasons: d.reasons, warnings: const []);

/// Validates a candidate pack end to end — schema AND security — as a
/// fold over the staged rule list [themePackRules] (issue #484):
///
/// - unknown keys anywhere REJECT the pack (pinned decision: strict — a
///   theme channel must never grow unreviewed fields);
/// - colors must be `#RRGGBB` / `#RRGGBBAA`;
/// - the wallpaper asset must be a flat image file name (no path segments,
///   no `..`, no scheme), ≤ [maxWallpaperBytes], png/jpg/jpeg/webp;
/// - the pack may contain exactly `theme.json` + the declared asset — any
///   other file (code, scripts, second image, anything) rejects the whole
///   install, so nothing executable ever enters the themes directory;
/// - contrast pairs below WCAG AA (4.5:1) produce [ThemePackValidation]
///   warnings — the pack still installs, but the user sees them before
///   applying (AC6).
///
/// The identity gate (unknown keys, name, version) rejects before the
/// body rules run; any reason rejects the pack, and only a clean fold
/// builds the [ThemePackSpec].
///
/// [json] is the decoded `theme.json`; [files] the sibling files.
ThemePackValidation validateThemePack(
  Map<String, Object?> json,
  ThemePackFiles files,
) {
  final d = ThemePackDraft(json, files);
  if (_foldRules(d, _gateRules)) return _rejected(d);
  if (_foldRules(d, _bodyRules)) return _rejected(d);
  final warnings = <String>[];
  if (d.dark != null) _contrastWarnings(d.dark!, 'dark', warnings);
  if (d.light != null) _contrastWarnings(d.light!, 'light', warnings);
  return (
    spec: ThemePackSpec(
      id: themePackIdFor(d.json['name'] as String),
      name: d.json['name'] as String,
      version: d.json['version'] as String,
      dark: d.dark,
      light: d.light,
      fontFamily: d.fontFamily,
      wallpaper: d.wallpaper,
      contrastWarnings: List.unmodifiable(warnings),
    ),
    reasons: const [],
    warnings: warnings,
  );
}

/// The schema's `wallpaper.fit` tokens → BoxFit, in declaration order
/// (the fit rule's rejection message lists the keys in this order).
const Map<String, BoxFit> fitModes = {
  'cover': BoxFit.cover,
  'contain': BoxFit.contain,
  'fill': BoxFit.fill,
  'fitWidth': BoxFit.fitWidth,
  'fitHeight': BoxFit.fitHeight,
  'none': BoxFit.none,
  'scaleDown': BoxFit.scaleDown,
};

/// Default wallpaper opacity when the pack does not declare one.
const double kWallpaperOpacityDefault = 1;

/// The install id for a pack [name]: lowercase slug, ASCII letters/digits
/// and dashes. Non-ASCII names collapse to their mapped chars.
String themePackIdFor(String name) {
  final slug = name
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return slug.isEmpty ? 'theme' : slug;
}

ThemePackColors? _parseVariant(
  Map<String, Object?> colors,
  String variant,
  List<String> reasons,
) {
  final value = colors[variant];
  if (value == null) return null;
  if (value is! Map<String, Object?>) {
    reasons.add('colors.$variant must be an object');
    return null;
  }
  final unknown = _rejectUnknownKeys(
    value,
    packColorKeys,
    'unknown colors.$variant keys',
    reasons,
  );
  final parsed = _parseColorSlots(value, variant, reasons);
  if (parsed.isEmpty && unknown.isEmpty) {
    reasons.add('colors.$variant sets no colors');
    return null;
  }
  if (reasons.isNotEmpty) return null;
  return ThemePackColors(
    background: parsed['background'],
    surface: parsed['surface'],
    surfaceAlt: parsed['surfaceAlt'],
    border: parsed['border'],
    borderBright: parsed['borderBright'],
    text: parsed['text'],
    muted: parsed['muted'],
    accent: parsed['accent'],
    accent2: parsed['accent2'],
    onAccent: parsed['onAccent'],
    error: parsed['error'],
    userBubble: parsed['userBubble'],
    userBubbleBorder: parsed['userBubbleBorder'],
    codeBg: parsed['codeBg'],
  );
}

/// The variant's known, well-formed color slots: `#RRGGBB`/`#RRGGBBAA`
/// strings parse into the slot map, anything else appends a reason.
Map<String, Color?> _parseColorSlots(
  Map<String, Object?> value,
  String variant,
  List<String> reasons,
) {
  final parsed = <String, Color?>{};
  for (final entry in value.entries) {
    if (!packColorKeys.contains(entry.key)) continue;
    if (entry.value == null) continue;
    if (entry.value is! String || !_hexColor.hasMatch(entry.value as String)) {
      reasons.add('colors.$variant.${entry.key} must be #RRGGBB or #RRGGBBAA');
      continue;
    }
    parsed[entry.key] = _parseHex(entry.value as String);
  }
  return parsed;
}

Color _parseHex(String hex) {
  final rgb = hex.replaceFirst('#', '');
  // The schema documents #RRGGBBAA — honor the alpha byte instead of
  // silently discarding it (a strict validator never loses data).
  if (rgb.length == 8) {
    final alpha = int.parse(rgb.substring(6), radix: 16);
    return Color(alpha << 24 | int.parse(rgb.substring(0, 6), radix: 16));
  }
  return Color(0xFF000000 | int.parse(rgb, radix: 16));
}

/// A flat image file name: one segment, a known extension shape, no
/// traversal, no scheme, no drive letter — anything path- or URL-shaped
/// rejects the pack.
bool _isSafeAssetName(String name) {
  if (name.isEmpty || name.length > 128 || _looksLikePathOrUrl(name)) {
    return false;
  }
  return wallpaperExtensions.contains(assetExtension(name));
}

bool _looksLikePathOrUrl(String name) =>
    name.contains('/') ||
    name.contains('\\') ||
    name.contains('..') ||
    name.startsWith('.') ||
    name.contains(':');

/// Lowercased extension of a flat file name ('' when it has no dot).
String assetExtension(String name) =>
    name.contains('.') ? name.split('.').last.toLowerCase() : '';

/// WCAG relative luminance contrast warnings for the readable text pairs.
void _contrastWarnings(
  ThemePackColors c,
  String variant,
  List<String> warnings,
) {
  void check(String label, Color? fg, Color? bg) {
    if (fg == null || bg == null) return;
    final ratio = contrastRatio(fg, bg);
    if (ratio < 4.5) {
      warnings.add(
        '$variant: $label contrast ${ratio.toStringAsFixed(1)}:1 is below '
        'WCAG AA (4.5:1)',
      );
    }
  }

  final background = c.background;
  final surface = c.surface;
  check('text on background', c.text, background);
  check('text on surface', c.text, surface);
  check('muted on background', c.muted, background);
  check('onAccent on accent', c.onAccent, c.accent);
  check('onAccent on accent2', c.onAccent, c.accent2);
}

/// WCAG 2.x relative-luminance contrast ratio of two colors.
double contrastRatio(Color a, Color b) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4).toDouble();

  double lum(Color c) =>
      0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);

  final la = lum(a);
  final lb = lum(b);
  final lighter = la > lb ? la : lb;
  final darker = la > lb ? lb : la;
  return (lighter + 0.05) / (darker + 0.05);
}

/// The session-current TUI theme (issue #279): built-in palettes, ports of
/// oh-my-pi's `dark`/`light` and pi's `dark`, user themes from
/// `~/.fah/themes/<name>.json`, runtime switching via `/theme`, and
/// persistence via the `tui.theme` config key.
///
/// Every color the CLI TUI emits flows through [FaThemeController.current]
/// at render time, so a switch repaints the whole surface with the next
/// frame (the differential renderer keeps the swap frame-atomic and only
/// repaints palette-dependent cells). The default theme reproduces the
/// historical site palette BYTE-IDENTICALLY in truecolor — nothing changes
/// visually until the user switches.
///
/// Role mapping from the oh-my-pi/pi JSON formats (documented in PR #279):
///
/// | our role       | their key              |
/// |----------------|------------------------|
/// | accent         | accent                 |
/// | accent2/2Soft  | customMessageLabel     |
/// | muted          | dim (+ faint)          |
/// | highlight      | selectedBg             |
/// | border         | border                 |
/// | focusBorder    | borderAccent           |
/// | success        | success                |
/// | warning        | warning                |
/// | error          | error                  |
/// | userMessageBg  | userMessageBg          |
///
/// Their remaining roles (md*, syntax*, statusLine*, thinking*, tool*Bg,
/// scrollbar*, search*) have no rendering surface here — user themes use
/// OUR role schema, so nothing silently drops.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:dart_tui/dart_tui.dart'
    show ColorProfile, RgbColor, Style, Theme;

/// The boot default: the historical site palette (site/styles.css teal +
/// indigo). Truecolor output is byte-identical to the pre-theming CLI.
const Theme kDefaultTuiTheme = Theme(
  name: 'default',
  base: Style(),
  muted: Style(isDim: true),
  accent: Style(
    foregroundRgb: RgbColor(94, 234, 212), // #5EEAD4 site teal
    isBold: true,
  ),
  highlight: Style(backgroundRgb: RgbColor(49, 50, 68)),
  success: Style(foregroundRgb: RgbColor(74, 222, 128)), // #4ADE80
  warning: Style(foregroundRgb: RgbColor(250, 204, 21)), // #FACC15
  error: Style(foregroundRgb: RgbColor(248, 113, 113)), // #F87171
  border: Style(isDim: true),
  focusBorder: Style(
    foregroundRgb: RgbColor(94, 234, 212), // #5EEAD4
  ),
  accent2: Style(
    foregroundRgb: RgbColor(129, 140, 248), // #818CF8 site indigo
    isBold: true,
  ),
  accent2Soft: Style(foregroundRgb: RgbColor(129, 140, 248)), // #818CF8
  userMessageBg: Style(backgroundRgb: RgbColor(30, 34, 42)), // #1E222A
);

/// The built-in catalog, keyed by config name. `default` wins the
/// `default` alias; every other name resolves literally.
const Map<String, Theme> kBuiltInTuiThemes = {
  'default': kDefaultTuiTheme,
  'catppuccin': Theme.catppuccin,
  'nord': Theme.nord,
  'dracula': Theme.dracula,
  'ohmypi-dark': _ohmypiDark,
  'ohmypi-light': _ohmypiLight,
  'pi': _piDark,
};

/// oh-my-pi `dark.json` port (vars resolved; see the library-docs mapping).
const Theme _ohmypiDark = Theme(
  name: 'ohmypi-dark',
  base: Style(),
  muted: Style(foregroundRgb: RgbColor(0x5f, 0x66, 0x73), isDim: true),
  accent: Style(foregroundRgb: RgbColor(0xfe, 0xbc, 0x38), isBold: true),
  highlight: Style(backgroundRgb: RgbColor(0x31, 0x36, 0x3f)),
  success: Style(foregroundRgb: RgbColor(0x89, 0xd2, 0x81)),
  warning: Style(foregroundRgb: RgbColor(0xe4, 0xc0, 0x0f)),
  error: Style(foregroundRgb: RgbColor(0xfc, 0x3a, 0x4b)),
  border: Style(foregroundRgb: RgbColor(0x17, 0x8f, 0xb9)),
  focusBorder: Style(foregroundRgb: RgbColor(0x00, 0x88, 0xfa)),
  accent2: Style(foregroundRgb: RgbColor(0xb2, 0x81, 0xd6), isBold: true),
  accent2Soft: Style(foregroundRgb: RgbColor(0xb2, 0x81, 0xd6)),
  userMessageBg: Style(backgroundRgb: RgbColor(0x22, 0x1d, 0x1a)),
);

/// oh-my-pi `light.json` port.
const Theme _ohmypiLight = Theme(
  name: 'ohmypi-light',
  base: Style(),
  muted: Style(foregroundRgb: RgbColor(0x76, 0x76, 0x76), isDim: true),
  accent: Style(foregroundRgb: RgbColor(0x5a, 0x80, 0x80), isBold: true),
  highlight: Style(backgroundRgb: RgbColor(0xd0, 0xd0, 0xe0)),
  success: Style(foregroundRgb: RgbColor(0x58, 0x84, 0x58)),
  warning: Style(foregroundRgb: RgbColor(0x9a, 0x73, 0x26)),
  error: Style(foregroundRgb: RgbColor(0xaa, 0x55, 0x55)),
  border: Style(foregroundRgb: RgbColor(0x54, 0x7d, 0xa7)),
  focusBorder: Style(foregroundRgb: RgbColor(0x5a, 0x80, 0x80)),
  accent2Soft: Style(foregroundRgb: RgbColor(0x7e, 0x57, 0xc2)),
  userMessageBg: Style(backgroundRgb: RgbColor(0xe8, 0xe8, 0xe8)),
);

/// pi's interactive-mode dark palette (`theme/dark.json`) port.
const Theme _piDark = Theme(
  name: 'pi',
  base: Style(foregroundRgb: RgbColor(0xd4, 0xd4, 0xd4)),
  muted: Style(foregroundRgb: RgbColor(0x66, 0x66, 0x66), isDim: true),
  accent: Style(foregroundRgb: RgbColor(0x8a, 0xbe, 0xb7), isBold: true),
  highlight: Style(backgroundRgb: RgbColor(0x3a, 0x3a, 0x4a)),
  success: Style(foregroundRgb: RgbColor(0xb5, 0xbd, 0x68)),
  warning: Style(foregroundRgb: RgbColor(0xff, 0xff, 0x00)),
  error: Style(foregroundRgb: RgbColor(0xcc, 0x66, 0x66)),
  border: Style(foregroundRgb: RgbColor(0x5f, 0x87, 0xff)),
  focusBorder: Style(foregroundRgb: RgbColor(0x00, 0xd7, 0xff)),
  accent2: Style(foregroundRgb: RgbColor(0x95, 0x75, 0xcd), isBold: true),
  accent2Soft: Style(foregroundRgb: RgbColor(0x95, 0x75, 0xcd)),
  userMessageBg: Style(backgroundRgb: RgbColor(0x34, 0x35, 0x41)),
);

/// The roles a user theme JSON may set (values: `#rgb`/`#rrggbb`).
const Set<String> kThemeRoleNames = {
  'accent',
  'accent2',
  'muted',
  'highlight',
  'success',
  'warning',
  'error',
  'border',
  'focusBorder',
  'userMessageBg',
};

/// A user-theme parse failure naming every problem with its role and line.
final class ThemeParseException implements Exception {
  ThemeParseException(this.problems);
  final List<String> problems;

  @override
  String toString() =>
      'invalid theme: ${problems.join('; ')}';
}

/// Parses one `#rgb`/`#rrggbb` color, returning null on anything else.
RgbColor? _parseHexColor(String value) {
  final hex = value.startsWith('#') ? value.substring(1) : value;
  final digits = int.tryParse(hex, radix: 16);
  if (digits == null) return null;
  switch (hex.length) {
    case 3:
      return RgbColor(
        (digits >> 8 & 0xf) * 17,
        (digits >> 4 & 0xf) * 17,
        (digits & 0xf) * 17,
      );
    case 6:
      return RgbColor(digits >> 16 & 0xff, digits >> 8 & 0xff, digits & 0xff);
    default:
      return null;
  }
}

/// The 1-based line of `"role"` in [text], or 0 when absent (used by named
/// parse errors).
int _roleLine(String text, String role) {
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].contains('"$role"')) return i + 1;
  }
  return 0;
}

/// Parses a user theme JSON document ([text], named [fileName]): tolerant of
/// missing roles (they inherit the default theme) and naming every problem
/// with its role and line — never a raw crash.
Theme parseUserTheme(String text, String fileName) {
  final Object? doc;
  try {
    doc = jsonDecode(text);
  } on FormatException catch (error) {
    final line = error.offset == null
        ? 0
        : '\n'.allMatches(error.source.substring(0, error.offset)).length + 1;
    throw ThemeParseException(['$fileName: not valid JSON at line $line']);
  }
  if (doc is! Map) {
    throw ThemeParseException(['$fileName: top level must be a JSON object']);
  }
  final rolesNode = doc['roles'] ?? doc['colors'];
  if (rolesNode is! Map) {
    throw ThemeParseException([
      '$fileName: missing "roles" object (${kThemeRoleNames.length} roles: '
          '${kThemeRoleNames.join(', ')})',
    ]);
  }
  final problems = <String>[];
  final resolved = <String, RgbColor>{};
  for (final entry in rolesNode.entries) {
    final role = '${entry.key}';
    if (!kThemeRoleNames.contains(role)) {
      problems.add(
        '$fileName:${_roleLine(text, role)}: unknown role "$role"',
      );
      continue;
    }
    final color = _parseHexColor('${entry.value}');
    if (color == null) {
      problems.add(
        '$fileName:${_roleLine(text, role)}: role "$role" must be '
            '"#rgb" or "#rrggbb", got "${entry.value}"',
      );
      continue;
    }
    resolved[role] = color;
  }
  if (problems.isNotEmpty) throw ThemeParseException(problems);

  Style fg(String role, {bool bold = false, bool dim = false}) {
    final color = resolved[role];
    if (color == null) return Style(isBold: bold ? true : null, isDim: dim);
    return Style(
      foregroundRgb: color,
      isBold: bold ? true : null,
      isDim: dim ? true : null,
    );
  }

  return Theme(
    name: fileName,
    base: const Style(),
    accent: fg('accent', bold: true),
    accent2: fg('accent2', bold: true),
    accent2Soft: fg('accent2'),
    muted: fg('muted', dim: true),
    highlight: resolved['highlight'] == null
        ? const Style()
        : Style(backgroundRgb: resolved['highlight']!),
    success: fg('success'),
    warning: fg('warning'),
    error: fg('error'),
    border: fg('border'),
    focusBorder: fg('focusBorder'),
    userMessageBg: resolved['userMessageBg'] == null
        ? const Style()
        : Style(backgroundRgb: resolved['userMessageBg']!),
  );
}

/// Loads user themes from `<home>/.fah/themes/*.json`. Filenames that
/// shadow a built-in are skipped (user themes can never shadow built-ins);
/// unparseable files are collected into [errors] instead of failing the
/// boot.
({Map<String, Theme> themes, List<String> errors}) loadUserThemes(
  String? homeDir,
  List<String> Function(String dir) listJsonFiles,
  String Function(String path) readFile,
) {
  final themes = <String, Theme>{};
  final errors = <String>[];
  if (homeDir == null || homeDir.isEmpty) return (themes: themes, errors: errors);
  final dir = '$homeDir/.fah/themes';
  for (final path in listJsonFiles(dir)) {
    final name = path.split('/').last.replaceAll(RegExp(r'\.json$'), '');
    if (kBuiltInTuiThemes.containsKey(name)) {
      errors.add(
        '$name: user theme ignored — cannot shadow a built-in theme name',
      );
      continue;
    }
    try {
      themes[name] = parseUserTheme(readFile(path), name);
    } on ThemeParseException catch (error) {
      errors.add(error.toString());
    }
  }
  return (themes: themes, errors: errors);
}

/// Detects the color profile the theme emitters render with. `null` means
/// no styling at all (pipes, `NO_COLOR`, `TERM=dumb`).
ColorProfile? detectThemeProfile({
  required bool ansiSupported,
  Map<String, String> environment = const {},
}) {
  if (!ansiSupported) return null;
  if (environment.containsKey('NO_COLOR')) return null;
  if (environment['TERM'] == 'dumb') return null;
  final colorTerm = environment['COLORTERM'] ?? '';
  if (colorTerm == 'truecolor' || colorTerm == '24bit') {
    return ColorProfile.trueColor;
  }
  if (environment.containsKey('WT_SESSION')) return ColorProfile.trueColor;
  // tmux/screen advertise 256 colors only — degrade instead of guessing.
  if ((environment['TERM'] ?? '').contains('256color')) {
    return ColorProfile.ansi256;
  }
  // Modern default: assume truecolor (matches the pre-theming behavior).
  return ColorProfile.trueColor;
}

/// Owns the session-current theme and renders the TUI color helpers
/// through it. One instance per process ([instance]); tests drive it
/// directly.
final class FaThemeController {
  FaThemeController._();

  /// The process-wide controller the color helpers read.
  static final FaThemeController instance = FaThemeController._();

  Theme _current = kDefaultTuiTheme;
  String _currentName = kDefaultTuiTheme.name;
  final Map<String, Theme> _userThemes = {};

  /// The color profile emitters render with (null = no styling).
  ColorProfile? profile = ColorProfile.trueColor;

  /// The current theme.
  Theme get current => _current;

  /// The current theme's config name.
  String get currentName => _currentName;

  /// All available themes: built-ins first, then user themes (which can
  /// never shadow a built-in name).
  Map<String, Theme> available() => {...kBuiltInTuiThemes, ..._userThemes};

  /// Installs user themes (boot-time; see [loadUserThemes]).
  void addUserThemes(Map<String, Theme> themes) => _userThemes.addAll(themes);

  /// Applies [name] if known; returns whether it resolved. Does not
  /// persist (that is `/theme`'s job).
  bool switchTo(String name) {
    final theme = available()[name];
    if (theme == null) return false;
    _current = theme;
    _currentName = name;
    return true;
  }

  /// Restores the boot default.
  void reset() => switchTo(kDefaultTuiTheme.name);

  Style _p(Style style) =>
      profile == null ? style : style.withProfile(profile);

  /// Renders [text] in the current theme's [role], honoring the profile;
  /// no-op (raw text) when styling is off.
  String _render(Style style, String text) =>
      profile == null ? text : _p(style).render(text);

  String accent(String text) => _render(_current.accent, text);

  String accent2(String text) => _render(_current.accent2, text);

  String accent2Soft(String text) => _render(_current.accent2Soft, text);

  String dim(String text) => _render(_current.muted, text);

  String warning(String text) => _render(_current.warning, text);

  String error(String text) => _render(_current.error, text);

  /// Backgrounds the echoed user-message lines.
  String userMessageBg(String text) =>
      _render(_current.userMessageBg, text);
}

// ── Emitters ──────────────────────────────────────────────────────────────
// Drop-in replacements for the old hardwired palette helpers. Byte-identity
// in the truecolor default: bold+fg / fg / faint exactly as before.

/// Bold first accent (headers, titles, active markers).
String tuiAccent(String s) => FaThemeController.instance.accent(s);

/// Bold second accent (tool-call markers, sub-headers).
String tuiAccent2(String s) => FaThemeController.instance.accent2(s);

/// Second accent without bold (dense spans, scroll indicator).
String tuiAccent2Soft(String s) => FaThemeController.instance.accent2Soft(s);

/// Faint secondary text (rules, hints, separators).
String tuiDim(String s) => FaThemeController.instance.dim(s);

/// Warning foreground (approval cautions, retry notices).
String tuiWarning(String s) => FaThemeController.instance.warning(s);

/// Error foreground (denials, failures).
String tuiError(String s) => FaThemeController.instance.error(s);

/// User-message echo background.
String tuiUserMessageBg(String s) =>
    FaThemeController.instance.userMessageBg(s);


// ── Swatch/table rendering ────────────────────────────────────────────────

/// One `███` run in [style]'s foreground; plain text when styling is off.
String _swatch(Style style, String label) =>
    FaThemeController.instance.profile == null
        ? label
        : style
            .withProfile(FaThemeController.instance.profile)
            .render(label);

/// A live-preview swatch row for [theme]: colored blocks sampling the
/// palette's load-bearing roles. Plain blocks when styling is off.
String themeSwatchRow(Theme theme) {
  String block(Style style) => _swatch(style, '███');

  return [
    block(theme.accent),
    block(theme.accent2),
    block(theme.success),
    block(theme.warning),
    block(theme.error),
    block(theme.userMessageBg),
  ].join();
}

/// The `/theme` listing lines: name + swatch + `(current)` marker.
List<String> themeTableLines({String? current}) {
  final available = {...kBuiltInTuiThemes};
  return [
    for (final entry in available.entries)
      '${entry.key == current ? '›' : ' '} '
          '${entry.key.padRight(13)} '
          '${themeSwatchRow(entry.value)}',
  ];
}

/// WCAG-ish sanity floor for E2: base fg must stay readable against the
/// message background in the same palette (contrast ratio ≥ 2.5).
double themeContrast(Theme theme) {
  final fg = theme.base.foregroundRgb ?? RgbColor(204, 204, 204);
  final bg = theme.userMessageBg.backgroundRgb ?? const RgbColor(0, 0, 0);
  return _contrastRatio(fg, bg);
}

double _relativeLuminance(RgbColor c) {
  double channel(int v) {
    final s = v / 255;
    return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * channel(c.r) +
      0.7152 * channel(c.g) +
      0.0722 * channel(c.b);
}

double _contrastRatio(RgbColor a, RgbColor b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  final lighter = math.max(la, lb);
  final darker = math.min(la, lb);
  return (lighter + 0.05) / (darker + 0.05);
}

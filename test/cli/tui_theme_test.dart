// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Unit tests for the session TUI theme (issue #279): byte-identity with
/// the historical palette under the default theme (AC1), port fidelity of
/// the oh-my-pi/pi palettes (AC2), user-theme parsing discipline (AC4/E3),
/// 256-color degrade + contrast floor (E2), and the swatch/table surface.
library;

import 'dart:io' as io;

import 'package:dart_tui/style.dart' show ColorProfile, RgbColor, Theme;
import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:flutter_agent_harness/src/cli/tui_theme.dart';
import 'package:test/test.dart';

/// The historical hardwired escapes (pre-#279): the default theme must
/// reproduce them byte-identically in truecolor.
const _legacyAccent = '\x1b[1m\x1b[38;2;94;234;212m';
const _legacyAccent2 = '\x1b[1m\x1b[38;2;129;140;248m';
const _legacyAccentPlain = '\x1b[38;2;94;234;212m';
const _legacyAccent2Plain = '\x1b[38;2;129;140;248m';
const _legacyDim = '\x1b[2m';
const _legacyWarning = '\x1b[38;2;250;204;21m';
const _legacyError = '\x1b[38;2;248;113;113m';
const _legacyUserBg = '\x1b[48;2;30;34;42m';

void main() {
  setUp(() {
    FaThemeController.instance
      ..reset()
      ..profile = ColorProfile.trueColor;
  });

  group('default theme byte-identity (AC1)', () {
    test('emitters reproduce the legacy site palette escapes', () {
      expect(tuiAccent('x'), '${_legacyAccent}x\x1b[0m');
      expect(tuiAccent2('x'), '${_legacyAccent2}x\x1b[0m');
      expect(tuiAccentSoft('x'), '${_legacyAccentPlain}x\x1b[0m');
      expect(tuiAccent2Soft('x'), '${_legacyAccent2Plain}x\x1b[0m');
      expect(tuiDim('x'), '${_legacyDim}x\x1b[0m');
      expect(tuiWarning('x'), '${_legacyWarning}x\x1b[0m');
      expect(tuiError('x'), '${_legacyError}x\x1b[0m');
      expect(
        FaThemeController.instance.userMessageBg('x'),
        '${_legacyUserBg}x\x1b[0m',
      );
    });

    test('raw SGR prefixes match the legacy fragments', () {
      expect(tuiAccentSoftSgr(), _legacyAccentPlain);
      expect(tuiAccent2SoftSgr(), _legacyAccent2Plain);
      expect(tuiDimSgr(), _legacyDim);
      expect(tuiUserMessageBgSgr(), _legacyUserBg);
    });

    test('default markdown render keeps the legacy heading color', () {
      final out = AnsiMarkdown(width: 60).formatAll(const ['# Title']);
      expect(out.join('\n'), contains('$_legacyAccent2Plain\x1b[1m'));
    });
  });

  group('profile degrade (AC7/E2)', () {
    test('a null profile emits raw text only', () {
      FaThemeController.instance.profile = null;
      expect(tuiAccent('x'), 'x');
      expect(tuiDim('x'), 'x');
      expect(tuiUserMessageBgSgr(), '');
      // Blocks stay (layout), color goes.
      expect(themeSwatchRow(kBuiltInTuiThemes['pi']!), contains('█'));
      expect(themeSwatchRow(kBuiltInTuiThemes['pi']!), isNot(contains('\x1b[')));
    });

    test('detectThemeProfile honors NO_COLOR, dumb terms and COLORTERM', () {
      expect(
        detectThemeProfile(ansiSupported: false),
        isNull,
        reason: 'pipes never get styling',
      );
      expect(
        detectThemeProfile(
          ansiSupported: true,
          environment: {'NO_COLOR': '1'},
        ),
        isNull,
      );
      expect(
        detectThemeProfile(ansiSupported: true, environment: {'TERM': 'dumb'}),
        isNull,
      );
      expect(
        detectThemeProfile(
          ansiSupported: true,
          environment: {'COLORTERM': 'truecolor'},
        ),
        ColorProfile.trueColor,
      );
      expect(
        detectThemeProfile(
          ansiSupported: true,
          environment: {'COLORTERM': '24bit'},
        ),
        ColorProfile.trueColor,
      );
      expect(
        detectThemeProfile(
          ansiSupported: true,
          environment: {'TERM': 'xterm-256color'},
        ),
        ColorProfile.ansi256,
        reason: 'tmux/screen advertise 256 colors — degrade, never guess',
      );
    });

    test('256-color output quantizes: no truecolor sequences survive', () {
      FaThemeController.instance.profile = ColorProfile.ansi256;
      FaThemeController.instance.switchTo('ohmypi-dark');
      final truecolor = RegExp(r'\x1b\[38;2;\d+;\d+;\d+m');
      expect(truecolor.hasMatch(tuiAccent('x')), isFalse);
      expect(tuiAccent('x'), matches(RegExp(r'\x1b\[38;5;\d+m')));
    });

    test('every built-in keeps base text readable on the message bg (E2)', () {
      for (final theme in kBuiltInTuiThemes.values) {
        expect(
          themeContrast(theme),
          greaterThanOrEqualTo(2.5),
          reason: '${theme.name}: base/must-read contrast floor',
        );
      }
    });
  });

  group('runtime switching (AC1/E1)', () {
    test('switchTo repaints the emitters with the new palette only', () {
      expect(FaThemeController.instance.switchTo('ohmypi-dark'), isTrue);
      // Same structure (bold accent, dim muted), different color.
      expect(tuiAccent('x'), '\x1b[1m\x1b[38;2;254;188;56mx\x1b[0m');
      expect(tuiDim('x'), contains('\x1b[38;2;95;102;115m'));
      // The reset alias returns to the boot default.
      FaThemeController.instance.reset();
      expect(tuiAccent('x'), '${_legacyAccent}x\x1b[0m');
    });

    test('a formatter built before the switch never tears mid-pass (E1)', () {
      final staleFormatter = AnsiMarkdown(width: 60)
        ..formatAll(const ['# warmup']);
      expect(FaThemeController.instance.switchTo('pi'), isTrue);
      // The cached pass still renders its starting palette…
      final stale = staleFormatter.formatAll(const ['# still stale']).join();
      expect(stale, contains('129;140;248'));
      // …while the NEXT pass (fresh formatter, next frame) uses the new one.
      final fresh = AnsiMarkdown(width: 60).formatAll(const ['# fresh']);
      expect(fresh.join(), contains('\x1b[38;2;149;117;205m'));
    });

    test('switchTo rejects unknown names without touching the session', () {
      expect(FaThemeController.instance.switchTo('nope'), isFalse);
      expect(FaThemeController.instance.currentName, 'default');
    });
  });

  group('built-in ports (AC2)', () {
    void expectRole(
      Theme theme,
      String role,
      RgbColor color, {
      bool bold = false,
      bool dim = false,
    }) {
      final style = switch (role) {
        'highlight' => theme.highlight,
        'userMessageBg' => theme.userMessageBg,
        'accent' => theme.accent,
        'accent2' => theme.accent2,
        'muted' => theme.muted,
        'success' => theme.success,
        'warning' => theme.warning,
        'error' => theme.error,
        'border' => theme.border,
        'focusBorder' => theme.focusBorder,
        _ => throw StateError(role),
      };
      expect(style.foregroundRgb ?? style.backgroundRgb, color,
          reason: '${theme.name}.$role');
      expect(style.isBold ?? false, bold, reason: '${theme.name}.$role bold');
      expect(style.isDim ?? false, dim, reason: '${theme.name}.$role dim');
    }

    test('ohmypi-dark equals its dark.json values, role by role', () {
      final theme = kBuiltInTuiThemes['ohmypi-dark']!;
      // Generated from oh-my-pi packages/coding-agent/src/modes/theme/dark.json.
      expectRole(theme, 'accent', const RgbColor(0xfe, 0xbc, 0x38), bold: true);
      expectRole(theme, 'accent2', const RgbColor(0xb2, 0x81, 0xd6), bold: true);
      expectRole(theme, 'muted', const RgbColor(0x5f, 0x66, 0x73), dim: true);
      expectRole(theme, 'highlight', const RgbColor(0x31, 0x36, 0x3f));
      expectRole(theme, 'success', const RgbColor(0x89, 0xd2, 0x81));
      expectRole(theme, 'warning', const RgbColor(0xe4, 0xc0, 0x0f));
      expectRole(theme, 'error', const RgbColor(0xfc, 0x3a, 0x4b));
      expectRole(theme, 'border', const RgbColor(0x17, 0x8f, 0xb9));
      expectRole(theme, 'focusBorder', const RgbColor(0x00, 0x88, 0xfa));
      expectRole(theme, 'userMessageBg', const RgbColor(0x22, 0x1d, 0x1a));
    });

    test('ohmypi-light equals its light.json values', () {
      final theme = kBuiltInTuiThemes['ohmypi-light']!;
      expectRole(theme, 'accent', const RgbColor(0x5a, 0x80, 0x80), bold: true);
      expectRole(theme, 'muted', const RgbColor(0x76, 0x76, 0x76), dim: true);
      expectRole(theme, 'error', const RgbColor(0xaa, 0x55, 0x55));
      expectRole(theme, 'userMessageBg', const RgbColor(0xe8, 0xe8, 0xe8));
    });

    test('pi matches the extracted interactive-mode dark palette', () {
      final theme = kBuiltInTuiThemes['pi']!;
      expectRole(theme, 'accent', const RgbColor(0x8a, 0xbe, 0xb7), bold: true);
      expectRole(theme, 'accent2', const RgbColor(0x95, 0x75, 0xcd), bold: true);
      expectRole(theme, 'error', const RgbColor(0xcc, 0x66, 0x66));
      expectRole(theme, 'userMessageBg', const RgbColor(0x34, 0x35, 0x41));
    });

    test('the catalog keeps the vendor themes and the default alias', () {
      expect(
        kBuiltInTuiThemes.keys,
        containsAll(const [
          'default',
          'catppuccin',
          'nord',
          'dracula',
          'ohmypi-dark',
          'ohmypi-light',
          'pi',
        ]),
      );
      expect(kBuiltInTuiThemes['default'], same(kDefaultTuiTheme));
    });
  });

  group('user themes (AC4/E3)', () {
    const warm = '{"roles": {"accent": "#f97316", "error": "#ef4444"}}';

    test('valid json loads; missing roles inherit the default (E3)', () {
      final theme = parseUserTheme(warm, 'warm');
      expect(theme.accent.foregroundRgb, const RgbColor(0xf9, 0x73, 0x16));
      // No `muted` role: inherits the default theme's dim style.
      expect(theme.muted.isDim ?? false, isTrue);
      expect(theme.muted.foregroundRgb, kDefaultTuiTheme.muted.foregroundRgb);
      // EVERY unspecified role inherits the default palette — not just
      // muted: warning/success/focusBorder keep their colors, border keeps
      // its dim flag, and the background roles keep the default surfaces
      // (E3: a partial theme overrides only what it names).
      expect(theme.warning.foregroundRgb, kDefaultTuiTheme.warning.foregroundRgb);
      expect(theme.success.foregroundRgb, kDefaultTuiTheme.success.foregroundRgb);
      expect(theme.focusBorder.foregroundRgb, kDefaultTuiTheme.focusBorder.foregroundRgb);
      expect(theme.border.isDim ?? false, isTrue);
      expect(
        theme.userMessageBg.backgroundRgb,
        kDefaultTuiTheme.userMessageBg.backgroundRgb,
      );
      expect(theme.highlight.backgroundRgb, kDefaultTuiTheme.highlight.backgroundRgb);
      // The named accent2 keeps its default bold; the soft variant
      // follows the same color with bold off.
      expect(theme.accent2.isBold ?? false, isTrue);
      expect(
        theme.accent2.foregroundRgb,
        theme.accent2Soft.foregroundRgb,
      );
    });

    test('a fully-specified theme overrides every role it names', () {
      const text =
          '{"roles": {"accent": "#010203", "warning": "#040506", '
          '"userMessageBg": "#070809"}}';
      final theme = parseUserTheme(text, 'full');
      expect(theme.accent.foregroundRgb, const RgbColor(1, 2, 3));
      expect(theme.warning.foregroundRgb, const RgbColor(4, 5, 6));
      expect(theme.userMessageBg.backgroundRgb, const RgbColor(7, 8, 9));
    });

    test('invalid values and unknown roles are named with their line', () {
      const text = '{\n  "roles": {"accent": "orange", "glow": "#fff"}}';
      final problems = _problemsOf(text);
      expect(problems, hasLength(2));
      expect(problems[0], contains(':2: role "accent" must be'));
      expect(problems[1], contains('unknown role "glow"'));
    });

    test('broken json names the file and the line', () {
      const text = '{"roles": {\n  "accent": #fff}}';
      expect(
        () => parseUserTheme(text, 'broken.json'),
        throwsA(
          predicate(
            (e) =>
                e is ThemeParseException &&
                e.problems.single.startsWith('broken.json: not valid JSON'),
          ),
        ),
      );
    });

    test('a non-object document is rejected, never crashed on', () {
      expect(
        () => parseUserTheme('[1, 2]', 'list.json'),
        throwsA(
          predicate(
            (e) =>
                e is ThemeParseException &&
                e.problems.single.contains('top level must be a JSON object'),
          ),
        ),
      );
    });

    test('loadUserThemes collects errors and never shadows built-ins', () {
      final loaded = loadUserThemes(
        '/home',
        (dir) => const [
          '/home/.fah/themes/warm.json',
          '/home/.fah/themes/catppuccin.json',
          '/home/.fah/themes/bad.json',
        ],
        (path) => path.endsWith('bad.json')
            ? '{"roles": {"accent": "nope"}}'
            : path.endsWith('catppuccin.json')
                ? '{"roles": {"accent": "#000000"}}'
                : warm,
      );
      expect(loaded.themes.keys, const ['warm']);
      expect(
        loaded.themes['warm']!.accent.foregroundRgb,
        const RgbColor(0xf9, 0x73, 0x16),
      );
      expect(loaded.errors, hasLength(2));
      expect(
        loaded.errors.where((e) => e.contains('cannot shadow a built-in')),
        hasLength(1),
      );
      // The built-in catalog still wins the name.
      expect(
        {...kBuiltInTuiThemes, ...loaded.themes}['catppuccin'],
        same(Theme.catppuccin),
      );
    });
  });

  group('swatches and the /theme table', () {
    test('themeSwatchRow paints palette blocks under a profile', () {
      final row = themeSwatchRow(kBuiltInTuiThemes['pi']!);
      expect(row, contains('███'));
      expect(row, contains('\x1b[38;2;'));
    });

    test('themeTableLines lists everything and marks the current', () {
      FaThemeController.instance.switchTo('pi');
      final lines = themeTableLines(current: 'pi');
      expect(lines.length, kBuiltInTuiThemes.length);
      final current = lines.where((l) => l.startsWith('› ')).toList();
      expect(current, hasLength(1));
      expect(current.single, startsWith('› pi'));
      expect(
        lines.singleWhere((l) => l.trim().startsWith('ohmypi-dark ')),
        isNot(startsWith('›')),
      );
    });

    test('themeTableLines lists user themes with the source mark', () {
      FaThemeController.instance.addUserThemes({
        'moss': parseUserTheme(
          '{"roles": {"accent": "#00ff88"}}',
          'moss',
        ),
      });
      final lines = themeTableLines();
      expect(lines.length, kBuiltInTuiThemes.length + 1);
      expect(
        lines.singleWhere((l) => l.trim().startsWith('moss ')),
        contains('(user)'),
      );
      // Built-ins carry no mark.
      expect(
        lines.singleWhere((l) => l.trim().startsWith('pi ')),
        isNot(contains('(user)')),
      );
    });
  });

  group('theme goldens (AC6)', () {
    // Regenerate with: FA_UPDATE_THEME_GOLDENS=1 dart test test/cli/tui_theme_test.dart
    final update = io.Platform.environment.containsKey('FA_UPDATE_THEME_GOLDENS');
    const themes = [
      'default',
      'catppuccin',
      'ohmypi-dark',
      'ohmypi-light',
      'pi',
    ];

    /// The same screen under every palette: title, tool line, markdown
    /// answer, user echo, status line, picker row.
    List<String> sampleScreen() {
      final markdown = AnsiMarkdown(width: 60).formatAll(const [
          '# Deployment finished',
          '- 12 tests **passed**, 0 failed',
          '- artifact: `build/app.apk`',
          '```',
          'fa deploy --verify',
          '```',
        ]);
      return [
        '${tuiAccent('fa')}${tuiDim(' · flutter_agent_harness — ready')}',
        '${tuiAccent2('● bash')}${tuiDim(' deploy --verify · 3.2s')}',
        ...markdown,
        FaThemeController.instance.userMessageBg(
          ' switch the theme to ohmypi ',
        ),
        '${tuiWarning('retrying in 2s')} ${tuiError('denied: write outside workspace')}',
        themeTableLines(current: FaThemeController.instance.currentName).first,
      ];
    }

    for (final name in themes) {
      test('golden: $name', () {
        FaThemeController.instance.reset();
        FaThemeController.instance.switchTo(name);
        final rendered = sampleScreen().join('\n');
        final file = io.File('test/cli/goldens/tui_theme_$name.ans');
        if (update) {
          file.writeAsStringSync('$rendered\n');
          return;
        }
        expect(
          rendered,
          file.readAsStringSync().trim(),
          reason:
              'palette drift in $name; regenerate with '
              'FA_UPDATE_THEME_GOLDENS=1',
        );
      });
    }
  });
}

/// Parses [text] expecting a ThemeParseException and returns its problems.
List<String> _problemsOf(String text) {
  try {
    parseUserTheme(text, 'ugly.json');
  } on ThemeParseException catch (error) {
    return error.problems;
  }
  fail('expected a ThemeParseException');
}

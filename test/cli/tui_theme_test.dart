// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Unit tests for the session TUI theme (issue #279): byte-identity with
/// the historical palette under the default theme (AC1), port fidelity of
/// the oh-my-pi/pi palettes (AC2), user-theme parsing discipline (AC4/E3),
/// 256-color degrade + contrast floor (E2), and the swatch/table surface.
library;

import 'dart:convert';
import 'dart:io' as io;

import 'package:dart_tui/src/bubbles/style.dart' show RgbColor, Style;
import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:flutter_agent_harness/src/cli/tool_rows.dart';
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
      expect(
        themeSwatchRow(kBuiltInTuiThemes['pi']!),
        isNot(contains('\x1b[')),
      );
    });

    test('detectThemeProfile honors NO_COLOR, dumb terms and COLORTERM', () {
      expect(
        detectThemeProfile(ansiSupported: false),
        isNull,
        reason: 'pipes never get styling',
      );
      expect(
        detectThemeProfile(ansiSupported: true, environment: {'NO_COLOR': '1'}),
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

    test('the #804 emitters degrade with the profile (AC1.3)', () {
      final controller = FaThemeController.instance;
      controller.switchTo('ohmypi-dark');
      // ansi256: quantized SGR, never RGB.
      controller.profile = ColorProfile.ansi256;
      final truecolor = RegExp(r'\x1b\[(38|48);2;\d+;\d+;\d+m');
      for (final rendered in [
        controller.thinkingLow('t'),
        controller.mdHeading('t'),
        controller.mdLinkUrl('t'),
        controller.mdCodeBlockBorder('t'),
        controller.syntaxComment('t'),
        controller.statusLineModel('t'),
        controller.statusLineCost('t'),
        controller.bashMode('t'),
        controller.toolDiffAdded('t'),
        controller.customMessageText('t'),
      ]) {
        expect(truecolor.hasMatch(rendered), isFalse);
      }
      expect(
        controller.statusLineModel('t'),
        matches(RegExp(r'\x1b\[38;5;\d+m')),
      );
      // NO_COLOR / dumb: raw text only.
      controller.profile = null;
      expect(controller.thinkingLow('t'), 't');
      expect(controller.statusLineModel('t'), 't');
      expect(controller.customMessageBg('t'), 't');
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
      // Same structure (bold accent, dim muted), different color. The
      // muted value is the gh-671 readability lightening of #5f6673.
      expect(tuiAccent('x'), '\x1b[1m\x1b[38;2;254;188;56mx\x1b[0m');
      expect(tuiDim('x'), contains('\x1b[38;2;134;141;153m'));
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
      TuiTheme theme,
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
      expect(
        style.foregroundRgb ?? style.backgroundRgb,
        color,
        reason: '${theme.name}.$role',
      );
      expect(style.isBold ?? false, bold, reason: '${theme.name}.$role bold');
      expect(style.isDim ?? false, dim, reason: '${theme.name}.$role dim');
    }

    test('ohmypi-dark equals its dark.json values, role by role', () {
      final theme = kBuiltInTuiThemes['ohmypi-dark']!;
      // Generated from oh-my-pi packages/coding-agent/src/modes/theme/dark.json.
      // EXCEPTIONS (gh-671 readability, see tui_theme.dart): muted and
      // toolOutput are lightened from #5f6673 — their ported values fail
      // the contrast floors on a dark terminal and on the tints.
      expectRole(theme, 'accent', const RgbColor(0xfe, 0xbc, 0x38), bold: true);
      expectRole(
        theme,
        'accent2',
        const RgbColor(0xb2, 0x81, 0xd6),
        bold: true,
      );
      expectRole(theme, 'muted', const RgbColor(0x86, 0x8d, 0x99), dim: true);
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
      expectRole(
        theme,
        'accent2',
        const RgbColor(0x95, 0x75, 0xcd),
        bold: true,
      );
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
      expect(
        theme.warning.foregroundRgb,
        kDefaultTuiTheme.warning.foregroundRgb,
      );
      expect(
        theme.success.foregroundRgb,
        kDefaultTuiTheme.success.foregroundRgb,
      );
      expect(
        theme.focusBorder.foregroundRgb,
        kDefaultTuiTheme.focusBorder.foregroundRgb,
      );
      expect(theme.border.isDim ?? false, isTrue);
      expect(
        theme.userMessageBg.backgroundRgb,
        kDefaultTuiTheme.userMessageBg.backgroundRgb,
      );
      expect(
        theme.highlight.backgroundRgb,
        kDefaultTuiTheme.highlight.backgroundRgb,
      );
      // The named accent2 keeps its default bold; the soft variant
      // follows the same color with bold off.
      expect(theme.accent2.isBold ?? false, isTrue);
      expect(theme.accent2.foregroundRgb, theme.accent2Soft.foregroundRgb);
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
        same(TuiTheme.catppuccin),
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
        'moss': parseUserTheme('{"roles": {"accent": "#00ff88"}}', 'moss'),
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

  group('gh-671 readability floors (accessibility)', () {
    // Every pair the emitters actually paint, per built-in theme, against
    // the terminal background the palette was designed for. Body/detail
    // text must clear 4.5:1 (WCAG AA), secondary text and bold labels 3:1,
    // the user band 7:1 (issue #444).
    RgbColor? fgOf(Style style) => style.foregroundRgb;
    RgbColor? bgOf(Style style) => style.backgroundRgb;

    test('reference terminal backgrounds split dark and light palettes', () {
      expect(
        themeReferenceTerminalBg(kBuiltInTuiThemes['ohmypi-light']!),
        const RgbColor(255, 255, 255),
        reason: 'ohmypi-light is a light-terminal palette',
      );
      expect(
        themeReferenceTerminalBg(kBuiltInTuiThemes['dracula']!),
        const RgbColor(0x1e, 0x1e, 0x28),
        reason: 'dark palettes reference a dark terminal',
      );
    });

    test('tool-row detail text clears 4.5:1 over both tints', () {
      for (final entry in kBuiltInTuiThemes.entries) {
        final t = entry.value;
        final fg = fgOf(t.toolOutput);
        expect(
          fg,
          isNotNull,
          reason:
              '${entry.key}: toolOutput must carry an explicit foreground — '
              'detail text over a tint can never rely on the terminal default',
        );
        for (final (name, tint) in [
          ('toolSuccessBg', bgOf(t.toolSuccessBg)),
          ('toolErrorBg', bgOf(t.toolErrorBg)),
        ]) {
          expect(
            themeColorContrast(fg!, tint!),
            greaterThanOrEqualTo(kThemeBodyTextFloor),
            reason:
                '${entry.key}: detail text on $name is '
                '${themeColorContrast(fg, tint).toStringAsFixed(2)}:1 '
                '(floor $kThemeBodyTextFloor) — unreadable command text '
                'was the gh-671 screenshot defect',
          );
        }
      }
    });

    test('tool-row labels and state rails clear 3:1 over their tints', () {
      for (final entry in kBuiltInTuiThemes.entries) {
        final t = entry.value;
        // tuiToolRow paints the label in toolTitle over BOTH tints — done
        // rows (toolSuccessBg) and failed rows (toolErrorBg) — so the floor
        // holds per tint (review: only the error tint was checked).
        for (final (tintName, tint) in [
          ('toolSuccessBg', bgOf(t.toolSuccessBg)),
          ('toolErrorBg', bgOf(t.toolErrorBg)),
        ]) {
          expect(
            themeColorContrast(fgOf(t.toolTitle)!, tint!),
            greaterThanOrEqualTo(kThemeSecondaryTextFloor),
            reason: '${entry.key}: toolTitle on $tintName',
          );
        }
        expect(
          themeColorContrast(fgOf(t.success)!, bgOf(t.toolSuccessBg)!),
          greaterThanOrEqualTo(kThemeSecondaryTextFloor),
          reason: '${entry.key}: done rail on toolSuccessBg',
        );
        expect(
          themeColorContrast(fgOf(t.error)!, bgOf(t.toolErrorBg)!),
          greaterThanOrEqualTo(kThemeSecondaryTextFloor),
          reason: '${entry.key}: failed rail on toolErrorBg',
        );
      }
    });

    test('muted and accent text stay visible on the reference terminal', () {
      for (final entry in kBuiltInTuiThemes.entries) {
        final t = entry.value;
        final bg = themeReferenceTerminalBg(t);
        for (final (role, style) in [
          ('muted', t.muted),
          ('accent', t.accent),
          ('accent2', t.accent2),
          ('success', t.success),
          ('warning', t.warning),
          ('error', t.error),
        ]) {
          final fg = fgOf(style);
          if (fg == null) continue; // base/no-fg roles render terminal-default
          expect(
            themeColorContrast(fg, bg),
            greaterThanOrEqualTo(kThemeSecondaryTextFloor),
            reason:
                '${entry.key}.$role on the reference terminal is '
                '${themeColorContrast(fg, bg).toStringAsFixed(2)}:1 '
                '(floor $kThemeSecondaryTextFloor) — "text almost '
                'invisible" (gh-671)',
          );
        }
      }
    });

    test('the failed row paints an explicit readable fg, never the terminal '
        'default', () {
      for (final name in kBuiltInTuiThemes.keys) {
        FaThemeController.instance.switchTo(name);
        final row = tuiToolRow(
          layoutToolRow(
            const ToolRowSegments(
              glyph: '✗',
              label: 'bash',
              detail: 'command not found',
              elapsed: '0s',
            ),
            78,
          ),
          ToolRowState.failed,
        );
        final fg =
            FaThemeController.instance.current.userMessageText.foregroundRgb;
        expect(
          fg,
          isNotNull,
          reason: '$name: userMessageText resolves to a color',
        );
        expect(
          row,
          contains(tuiSgr(Style(foregroundRgb: fg))),
          reason:
              '$name: failed-row detail/elapsed must be explicit — the '
              'terminal default fg is invisible on light tints (gh-671 '
              'screenshot: ohmypi-light toolErrorBg band)',
        );
        expect(
          themeColorContrast(
            fg!,
            FaThemeController.instance.current.toolErrorBg.backgroundRgb!,
          ),
          greaterThanOrEqualTo(kThemeBodyTextFloor),
          reason: '$name: failed-row text on toolErrorBg',
        );
      }
    });

    test('tinted segments drop the dim flag (unpredictable contrast)', () {
      FaThemeController.instance.switchTo('ohmypi-dark');
      final dimmed = RegExp(r'\x1b\[2m');
      for (final state in [ToolRowState.done, ToolRowState.failed]) {
        final row = tuiToolRow(
          layoutToolRow(
            const ToolRowSegments(
              glyph: '✓',
              label: 'bash',
              detail: 'deploy --verify',
              elapsed: '3.2s',
            ),
            78,
          ),
          state,
        );
        expect(
          dimmed.hasMatch(row),
          isFalse,
          reason:
              '$state: SGR 2 halves contrast unpredictably across terminals; '
              'text over a theme tint keeps an explicit fg only',
        );
      }
      // Unpainted rows keep the classic dim look over the terminal bg.
      final settled = tuiToolRow(
        layoutToolRow(
          const ToolRowSegments(glyph: '●', label: 'bash', detail: 'x'),
          78,
        ),
        ToolRowState.settled,
      );
      expect(dimmed.hasMatch(settled), isTrue);
    });

    test('the transcript formatter re-renders the echo band with the '
        'current bg AND fg (gh-671)', () {
      // The TUI stores the user echo pre-styled; the view-time formatter
      // repaints it from the CURRENT theme. The old path re-applied only
      // the background — the text fell back to the terminal default fg,
      // invisible on the light userMessageBg band (light palettes).
      final stored = tuiUserMessageLine(' fix the flaky login flow ');
      final md = TranscriptMarkdown(width: 80);
      final repainted = md.sync([stored]).single;
      expect(repainted, contains(tuiUserMessageBgSgr()));
      expect(
        repainted,
        contains(tuiUserMessageTextSgr()),
        reason:
            'the repainted band must carry the explicit userMessageText '
            'foreground — bg-only re-renders were the gh-671 echo defect',
      );
      // The text survives stripping, padded to the width.
      expect(
        repainted.replaceAll(RegExp(r'\x1b\[[0-9;]*m'), ''),
        ' fix the flaky login flow '.padRight(80),
      );
      // A mid-session theme switch repaints with the NEW palette (E1).
      FaThemeController.instance.switchTo('dracula');
      final repainted2 = TranscriptMarkdown(width: 80).sync([stored]).single;
      expect(repainted2, contains(tuiUserMessageBgSgr()));
      expect(repainted2, contains(tuiUserMessageTextSgr()));
    });

    test('themeColorContrast/themeLuminance are the WCAG formulas', () {
      expect(themeLuminance(const RgbColor(0, 0, 0)), closeTo(0, 1e-9));
      expect(themeLuminance(const RgbColor(255, 255, 255)), closeTo(1, 1e-9));
      expect(
        themeColorContrast(
          const RgbColor(0, 0, 0),
          const RgbColor(255, 255, 255),
        ),
        closeTo(21, 0.01),
      );
      // #767676 on white is the canonical 4.54:1 AA boundary pair.
      expect(
        themeColorContrast(
          const RgbColor(0x76, 0x76, 0x76),
          const RgbColor(255, 255, 255),
        ),
        closeTo(4.54, 0.02),
      );
    });
  });

  group('gh-671 /theme picker items', () {
    test('every row keeps its swatch and the current row is text-marked', () {
      FaThemeController.instance.switchTo('dracula');
      final items = themePickerItems(
        current: FaThemeController.instance.currentName,
      );
      expect(items, hasLength(FaThemeController.instance.available().length));
      // The swatch survives on EVERY row — the old picker REPLACED the
      // current theme's swatch with a bare '(current)' string.
      for (final item in items) {
        expect(item.description, contains('███'), reason: item.label);
      }
      final current = items.singleWhere((i) => i.key == 'dracula');
      expect(current.description, contains('current'));
      // The marker is colored text (success role), not a color-only cue.
      expect(current.description, contains(tuiSuccess('✓ current')));
      expect(
        items.where((i) => i.description.contains('current')),
        hasLength(1),
      );
    });

    test('the picker preselects the current theme (initialKey contract)', () {
      FaThemeController.instance.switchTo('nord');
      final items = themePickerItems(current: 'nord');
      expect(items.any((i) => i.key == 'nord'), isTrue);
    });

    test('styling off degrades to plain text', () {
      FaThemeController.instance.profile = null;
      final items = themePickerItems(current: 'pi');
      final current = items.singleWhere((i) => i.key == 'pi');
      expect(current.description, contains('███'));
      expect(current.description, contains('✓ current'));
      expect(current.description, isNot(contains('\x1b[')));
    });
  });

  group('theme goldens (AC6)', () {
    // Regenerate with: FA_UPDATE_THEME_GOLDENS=1 dart test test/cli/tui_theme_test.dart
    final update = io.Platform.environment.containsKey(
      'FA_UPDATE_THEME_GOLDENS',
    );
    const themes = [
      'default',
      'catppuccin',
      'nord',
      'dracula',
      'ohmypi-dark',
      'ohmypi-light',
      'pi',
    ];

    /// The same screen under every palette: title + mark, the three
    /// bordered tool-row states (issue #444), markdown answer, user
    /// band, warning/error line, status line.
    List<String> sampleScreen() {
      final markdown = AnsiMarkdown(width: 60).formatAll(const [
        '# Deployment finished',
        '- 12 tests **passed**, 0 failed',
        '- artifact: `build/app.apk`',
        '```',
        'fa deploy --verify',
        '```',
      ]);
      LaidOutToolRow row(String glyph, String detail, {String elapsed = ''}) =>
          layoutToolRow(
            ToolRowSegments(
              glyph: glyph,
              label: 'bash',
              detail: detail,
              elapsed: elapsed,
            ),
            78,
          );
      return [
        '${tuiFaMark()}${tuiDim('fa · flutter_agent_harness — ready')}',
        tuiToolRow(row('•', 'deploy --verify'), ToolRowState.running),
        tuiToolRow(
          row('✓', 'deploy --verify', elapsed: '3.2s'),
          ToolRowState.done,
        ),
        tuiToolRow(
          row('✗', 'command not found', elapsed: '0s'),
          ToolRowState.failed,
        ),
        ...markdown,
        tuiUserMessageLine(' switch the theme to ohmypi '),
        '${tuiWarning('retrying in 2s')} ${tuiError('denied: write outside workspace')}',
        // issue #804 token families: thinking scale, syntax line, diff
        // line, status line segments over the band tint.
        [
          FaThemeController.instance.thinkingOff('· snooze'),
          FaThemeController.instance.thinkingMinimal('· minimal'),
          FaThemeController.instance.thinkingLow('· low'),
          FaThemeController.instance.thinkingMedium('· medium'),
          FaThemeController.instance.thinkingHigh('· high'),
          FaThemeController.instance.thinkingXhigh('· xhigh'),
        ].join(),
        [
          FaThemeController.instance.syntaxKeyword('final'),
          FaThemeController.instance.syntaxPunctuation(' '),
          FaThemeController.instance.syntaxVariable('theme'),
          FaThemeController.instance.syntaxPunctuation(' = '),
          FaThemeController.instance.syntaxString("'omp'"),
          FaThemeController.instance.syntaxPunctuation(';'),
          FaThemeController.instance.syntaxComment(' // parity'),
        ].join(),
        [
          FaThemeController.instance.toolDiffAdded('+ added'),
          FaThemeController.instance.toolDiffRemoved(' - removed'),
          FaThemeController.instance.toolDiffContext(' ~ context'),
        ].join(),
        [
          FaThemeController.instance.statusLineModel('glm-5.3-flash'),
          FaThemeController.instance.statusLineSep(
            FaThemeController.instance.sym('sep.dot'),
          ),
          FaThemeController.instance.statusLinePath('~/work/harness'),
          FaThemeController.instance.statusLineSep(
            FaThemeController.instance.sym('sep.dot'),
          ),
          FaThemeController.instance.statusLineGitClean('✓'),
          FaThemeController.instance.statusLineSep(
            FaThemeController.instance.sym('sep.dot'),
          ),
          FaThemeController.instance.statusLineContext('42%'),
          FaThemeController.instance.statusLineSep(
            FaThemeController.instance.sym('sep.dot'),
          ),
          FaThemeController.instance.statusLineCost('\$1.24'),
        ].join(),
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

  // -- issue #804 -----------------------------------------------------------

  group('controller emitters are the only theme surface (AC1.4)', () {
    test('no view code reads TuiTheme fields raw', () {
      // View code paints through the controller emitters (rule #279 E1):
      // a `.current.<field>` read outside the emitter home would survive a
      // hot theme switch on a stale value. Emitters live in tui_theme.dart
      // (+ the palette type in tui_theme_palette.dart); everything else in
      // lib/src/cli is view code.
      final fieldPattern = RegExp(
        r'\.current\.('
        r'accent2Soft|accentSoft|accent2|accent|muted|highlight|success'
        r'|warning|error|border'
        r'|focusBorder|userMessageBg|borderMuted|toolTitle|toolOutput'
        r'|userMessageText|toolSuccessBg|toolErrorBg|toolPendingBg'
        r'|customMessageBg|customMessageText|thinkingText|thinkingOff'
        r'|thinkingMinimal|thinkingLow|thinkingMedium|thinkingHigh'
        r'|thinkingXhigh|mdHeading|mdLink|mdLinkUrl|mdCode|mdCodeBlock'
        r'|mdCodeBlockBorder|mdQuote|mdQuoteBorder|mdHr|mdListBullet|link'
        r'|toolDiffAdded|toolDiffRemoved|toolDiffContext|syntaxComment'
        r'|syntaxKeyword|syntaxFunction|syntaxVariable|syntaxString'
        r'|syntaxNumber|syntaxType|syntaxOperator|syntaxPunctuation'
        r'|bashMode|pythonMode|statusLineBg|statusLineSep|statusLineModel'
        r'|statusLinePath|statusLineGitClean|statusLineGitDirty'
        r'|statusLineContext|statusLineSpend|statusLineStaged'
        r'|statusLineDirty|statusLineUntracked|statusLineOutput'
        r'|statusLineCost|statusLineSubagents)\b',
      );
      final violations = <String>[];
      for (final entity
          in io.Directory('lib/src/cli').listSync(recursive: true)) {
        if (entity is! io.File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.endsWith('tui_theme.dart') ||
            entity.path.endsWith('tui_theme_palette.dart')) {
          continue;
        }
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (fieldPattern.hasMatch(lines[i])) {
            violations.add('${entity.path}:${i + 1}: ${lines[i].trim()}');
          }
        }
      }
      expect(
        violations,
        isEmpty,
        reason:
            'theme fields must flow through FaThemeController emitters '
            '(rule #279 E1):\n${violations.join('\n')}',
      );
    });
  });

  group('omp token parity (issue #804 AC1.1)', () {
    // Walks EVERY color token of the pinned omp fixtures
    // (test/fixtures/tui_omp/{dark,light}.json, omp df624f5) into the
    // corresponding TuiTheme field: vars resolved, 256-color palette
    // indices expanded, `''` treated as terminal-default. Deliberate
    // deviations (gh-671/#444/#804 readability + role-table contracts)
    // are pinned to their exact ported values so they can never drift
    // silently either.
    Map<String, dynamic> fixtureOf(String name) {
      final raw = io.File('test/fixtures/tui_omp/$name.json').readAsStringSync();
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    }

    final cubeLevels = [0, 95, 135, 175, 215, 255];
    RgbColor cube256(int index) {
      if (index < 16 || index > 255) {
        throw ArgumentError('bad 256-color index: $index');
      }
      if (index >= 232) {
        final gray = 8 + 10 * (index - 232);
        return RgbColor(gray, gray, gray);
      }
      final value = index - 16;
      final r = cubeLevels[value ~/ 36];
      final g = cubeLevels[(value % 36) ~/ 6];
      final b = cubeLevels[value % 6];
      return RgbColor(r, g, b);
    }

    RgbColor hexRgb(String hex) {
      final body = hex.replaceFirst('#', '');
      return RgbColor(
        int.parse(body.substring(0, 2), radix: 16),
        int.parse(body.substring(2, 4), radix: 16),
        int.parse(body.substring(4, 6), radix: 16),
      );
    }

    /// omp token values: `#hex`, a 256 palette index, a var name, or `''`
    /// (terminal default). Var chains resolve recursively.
    RgbColor? resolveOmpToken(dynamic value, Map<String, dynamic> vars) {
      if (value is int) return cube256(value);
      if (value is! String || value.isEmpty) return null;
      if (value.startsWith('#')) return hexRgb(value);
      return resolveOmpToken(vars[value], vars);
    }

    /// omp color key -> the fa TuiTheme field it ports to (returns null
    /// for keys fa has no field for).
    Style? faFieldFor(TuiTheme theme, String key) => switch (key) {
      'accent' => theme.accent,
      'border' => theme.border,
      'borderAccent' => theme.focusBorder,
      'borderMuted' => theme.borderMuted,
      'success' => theme.success,
      'error' => theme.error,
      'warning' => theme.warning,
      'muted' => theme.muted,
      'dim' => theme.muted,
      'thinkingText' => theme.thinkingText,
      'selectedBg' => theme.highlight,
      'userMessageBg' => theme.userMessageBg,
      'userMessageText' => theme.userMessageText,
      'customMessageBg' => theme.customMessageBg,
      'customMessageText' => theme.customMessageText,
      'customMessageLabel' => theme.accent2Soft,
      'toolPendingBg' => theme.toolPendingBg,
      'toolSuccessBg' => theme.toolSuccessBg,
      'toolErrorBg' => theme.toolErrorBg,
      'toolTitle' => theme.toolTitle,
      'toolOutput' => theme.toolOutput,
      'mdHeading' => theme.mdHeading,
      'mdLink' => theme.mdLink,
      'mdLinkUrl' => theme.mdLinkUrl,
      'mdCode' => theme.mdCode,
      'mdCodeBlock' => theme.mdCodeBlock,
      'mdCodeBlockBorder' => theme.mdCodeBlockBorder,
      'mdQuote' => theme.mdQuote,
      'mdQuoteBorder' => theme.mdQuoteBorder,
      'mdHr' => theme.mdHr,
      'mdListBullet' => theme.mdListBullet,
      'toolDiffAdded' => theme.toolDiffAdded,
      'toolDiffRemoved' => theme.toolDiffRemoved,
      'toolDiffContext' => theme.toolDiffContext,
      'link' => theme.link,
      'syntaxComment' => theme.syntaxComment,
      'syntaxKeyword' => theme.syntaxKeyword,
      'syntaxFunction' => theme.syntaxFunction,
      'syntaxVariable' => theme.syntaxVariable,
      'syntaxString' => theme.syntaxString,
      'syntaxNumber' => theme.syntaxNumber,
      'syntaxType' => theme.syntaxType,
      'syntaxOperator' => theme.syntaxOperator,
      'syntaxPunctuation' => theme.syntaxPunctuation,
      'thinkingOff' => theme.thinkingOff,
      'thinkingMinimal' => theme.thinkingMinimal,
      'thinkingLow' => theme.thinkingLow,
      'thinkingMedium' => theme.thinkingMedium,
      'thinkingHigh' => theme.thinkingHigh,
      'thinkingXhigh' => theme.thinkingXhigh,
      'bashMode' => theme.bashMode,
      'pythonMode' => theme.pythonMode,
      'statusLineBg' => theme.statusLineBg,
      'statusLineSep' => theme.statusLineSep,
      'statusLineModel' => theme.statusLineModel,
      'statusLinePath' => theme.statusLinePath,
      'statusLineGitClean' => theme.statusLineGitClean,
      'statusLineGitDirty' => theme.statusLineGitDirty,
      'statusLineContext' => theme.statusLineContext,
      'statusLineSpend' => theme.statusLineSpend,
      'statusLineStaged' => theme.statusLineStaged,
      'statusLineDirty' => theme.statusLineDirty,
      'statusLineUntracked' => theme.statusLineUntracked,
      'statusLineOutput' => theme.statusLineOutput,
      'statusLineCost' => theme.statusLineCost,
      'statusLineSubagents' => theme.statusLineSubagents,
      'text' => null, // terminal default: fa's `base` stays unpainted
      _ => throw StateError('unmapped omp color key: $key — extend the walker'),
    };

    /// omp keys ship `''` or a value fa deliberately replaces (gh-671
    /// readability lifts, #444 explicit-contrast contracts). Pinned to the
    /// exact ported value per theme.
    final deviations = const {
      'userMessageText': {
        'ohmypi-dark': RgbColor(0xd4, 0xd4, 0xd4),
        'ohmypi-light': RgbColor(0x22, 0x22, 0x22),
      },
      'customMessageText': {
        'ohmypi-dark': RgbColor(0xd4, 0xd4, 0xd4),
        'ohmypi-light': RgbColor(0x22, 0x22, 0x22),
      },
      'toolTitle': {
        'ohmypi-dark': RgbColor(0xb2, 0x81, 0xd6),
        'ohmypi-light': RgbColor(0x7e, 0x57, 0xc2),
      },
      'muted': {
        'ohmypi-dark': RgbColor(0x86, 0x8d, 0x99),
        'ohmypi-light': RgbColor(0x76, 0x76, 0x76),
      },
      'dim': {
        'ohmypi-dark': RgbColor(0x86, 0x8d, 0x99),
        'ohmypi-light': RgbColor(0x76, 0x76, 0x76),
      },
      'toolOutput': {
        'ohmypi-dark': RgbColor(0x86, 0x8d, 0x99),
        'ohmypi-light': RgbColor(0x56, 0x56, 0x56),
      },
      'thinkingText': {
        'ohmypi-dark': RgbColor(0x86, 0x8d, 0x99),
      },
      'thinkingOff': {
        'ohmypi-dark': RgbColor(0x77, 0x7d, 0x88),
        'ohmypi-light': RgbColor(0x8c, 0x8c, 0x8c),
      },
      'thinkingMinimal': {
        'ohmypi-dark': RgbColor(0x86, 0x8d, 0x99),
      },
      'mdLinkUrl': {
        'ohmypi-dark': RgbColor(0x86, 0x8d, 0x99),
      },
      'statusLineSep': {
        'ohmypi-light': RgbColor(0x6c, 0x6c, 0x6c),
      },
      'statusLineStaged': {
        'ohmypi-light': RgbColor(0x58, 0x84, 0x58),
      },
      'statusLineDirty': {
        'ohmypi-light': RgbColor(0x9a, 0x73, 0x26),
      },
      'statusLineUntracked': {
        'ohmypi-light': RgbColor(0x5a, 0x80, 0x80),
      },
    };

    /// Bold/dim flags fa keeps on ported roles (omp ships none).
    void expectFlags(TuiTheme theme, String key, Style style) {
      final bold = switch (key) {
        'accent' || 'accent2' || 'toolTitle' => true,
        _ => false,
      };
      final dim = switch (key) {
        'muted' || 'dim' || 'borderMuted' || 'toolOutput' => true,
        _ => false,
      };
      expect(style.isBold ?? false, bold, reason: '${theme.name}.$key bold');
      expect(style.isDim ?? false, dim, reason: '${theme.name}.$key dim');
    }

    for (final fixtureName in ['dark', 'light']) {
      test('$fixtureName.json: every color token ports token-for-token', () {
        final fixture = fixtureOf(fixtureName);
        final themeName = 'ohmypi-$fixtureName';
        final theme = kBuiltInTuiThemes[themeName]!;
        final vars =
            (fixture['vars'] as Map).cast<String, dynamic>();
        final colors =
            (fixture['colors'] as Map).cast<String, dynamic>();
        expect(colors, isNotEmpty);
        final mappedKeys = <String>{};
        colors.forEach((key, value) {
          final style = faFieldFor(theme, key);
          if (style == null) return; // `text`: base stays terminal-default
          mappedKeys.add(key);
          final omp = resolveOmpToken(value, vars);
          final pinned = deviations[key]?[themeName];
          if (pinned != null) {
            expect(
              style.foregroundRgb ?? style.backgroundRgb,
              pinned,
              reason: '$themeName.$key: pinned deviation drifted',
            );
          } else if (omp == null) {
            expect(
              style.foregroundRgb,
              isNull,
              reason:
                  '$themeName.$key: omp ships terminal-default; fa must '
                  'not invent a color (or pin the deviation)',
            );
          } else {
            expect(
              style.foregroundRgb ?? style.backgroundRgb,
              omp,
              reason:
                  '$themeName.$key: expected omp $value -> $omp, got '
                  '${style.foregroundRgb ?? style.backgroundRgb}',
            );
          }
          expectFlags(theme, key, style);
        });
        // Walker completeness, both directions: every fixture token maps
        // to a fa field (except the terminal-default `text`), and the
        // walker stops covering nothing.
        expect(
          mappedKeys,
          equals(colors.keys.toSet()..remove('text')),
        );
      });
    }
  });

  group('auto light/dark detection (issue #804 AC1.2)', () {
    test('tier: measured terminal background beats COLORFGBG', () {
      expect(
        FaThemeController.prefersLightTheme(
          terminalBg: const RgbColor(0xff, 0xff, 0xff),
          colorfgbg: '15;0',
        ),
        isTrue,
        reason: 'luminance > 0.5 wins over a dark COLORFGBG',
      );
      expect(
        FaThemeController.prefersLightTheme(
          terminalBg: const RgbColor(0x12, 0x12, 0x12),
          colorfgbg: '0;15',
        ),
        isFalse,
        reason: 'a dark measured bg wins over a light COLORFGBG',
      );
    });

    test('COLORFGBG: bg >= 8 is light, bg < 8 dark, unparseable dark', () {
      expect(
        FaThemeController.prefersLightTheme(colorfgbg: '0;15'),
        isTrue,
      );
      expect(FaThemeController.prefersLightTheme(colorfgbg: '15;7'), isFalse);
      expect(FaThemeController.prefersLightTheme(colorfgbg: '15'), isFalse);
      expect(
        FaThemeController.prefersLightTheme(colorfgbg: '15;x'),
        isFalse,
      );
      expect(FaThemeController.prefersLightTheme(), isFalse);
    });

    test('boot tier: COLORFGBG light resolves ohmypi-light, dark default', () {
      final controller = FaThemeController.instance;
      controller.armAutoLightDark(colorfgbg: '0;15');
      expect(controller.currentName, 'ohmypi-light');
      expect(controller.autoLightDarkArmed, isTrue);
      controller.reset();
      controller.armAutoLightDark(colorfgbg: '15;0');
      expect(controller.currentName, kDefaultTuiTheme.name);
    });

    test('OSC 11 reply re-resolves the armed tier (hot swap path)', () {
      final controller = FaThemeController.instance;
      controller.armAutoLightDark(colorfgbg: '15;0');
      expect(controller.currentName, kDefaultTuiTheme.name);
      controller.measuredTerminalBg = const RgbColor(0xff, 0xff, 0xff);
      expect(controller.reapplyAutoLightDark(), isTrue);
      expect(controller.currentName, 'ohmypi-light');
      // Dark terminal: swaps back to the default palette.
      controller.measuredTerminalBg = const RgbColor(0x12, 0x12, 0x12);
      expect(controller.reapplyAutoLightDark(), isTrue);
      expect(controller.currentName, kDefaultTuiTheme.name);
      // Same palette again: no change to report.
      expect(controller.reapplyAutoLightDark(), isFalse);
    });

    test('explicit switchTo disarms the tier', () {
      final controller = FaThemeController.instance;
      controller.armAutoLightDark(colorfgbg: '15;0');
      expect(controller.switchTo('ohmypi-light'), isTrue);
      expect(controller.autoLightDarkArmed, isFalse);
      controller.measuredTerminalBg = const RgbColor(0xff, 0xff, 0xff);
      expect(
        controller.reapplyAutoLightDark(),
        isFalse,
        reason: 'an explicit /theme choice outranks detection',
      );
      expect(controller.currentName, 'ohmypi-light');
    });
  });

  group('issue #804 readability floors (new roles)', () {
    RgbColor? fgOf(Style style) => style.foregroundRgb;
    RgbColor? bgOf(Style style) => style.backgroundRgb;

    test('statusLine segments clear 3:1 over the status line band', () {
      for (final entry in kBuiltInTuiThemes.entries) {
        if (!entry.key.startsWith('ohmypi')) continue;
        final t = entry.value;
        final band = bgOf(t.statusLineBg);
        expect(
          band,
          isNotNull,
          reason: '${entry.key}: statusLineBg must paint the band',
        );
        for (final (name, style) in [
          ('statusLineSep', t.statusLineSep),
          ('statusLineModel', t.statusLineModel),
          ('statusLinePath', t.statusLinePath),
          ('statusLineGitClean', t.statusLineGitClean),
          ('statusLineGitDirty', t.statusLineGitDirty),
          ('statusLineContext', t.statusLineContext),
          ('statusLineSpend', t.statusLineSpend),
          ('statusLineStaged', t.statusLineStaged),
          ('statusLineDirty', t.statusLineDirty),
          ('statusLineUntracked', t.statusLineUntracked),
          ('statusLineOutput', t.statusLineOutput),
          ('statusLineCost', t.statusLineCost),
          ('statusLineSubagents', t.statusLineSubagents),
        ]) {
          final fg = fgOf(style);
          expect(
            fg,
            isNotNull,
            reason: '${entry.key}.$name must carry an explicit foreground',
          );
          expect(
            themeColorContrast(fg!, band!),
            greaterThanOrEqualTo(kThemeSecondaryTextFloor),
            reason:
                '${entry.key}.$name on statusLineBg is '
                '${themeColorContrast(fg, band).toStringAsFixed(2)}:1 '
                '(floor $kThemeSecondaryTextFloor)',
          );
        }
      }
    });

    test('custom message text clears 4.5:1 over its band', () {
      for (final entry in kBuiltInTuiThemes.entries) {
        if (!entry.key.startsWith('ohmypi')) continue;
        final t = entry.value;
        expect(
          themeColorContrast(
            fgOf(t.customMessageText)!,
            bgOf(t.customMessageBg)!,
          ),
          greaterThanOrEqualTo(kThemeBodyTextFloor),
          reason: '${entry.key}: customMessageText over its band',
        );
      }
    });

    test('tool rows clear their floors over the pending tint too', () {
      for (final entry in kBuiltInTuiThemes.entries) {
        final t = entry.value;
        final tint = bgOf(t.toolPendingBg);
        if (tint == null) continue; // non-omp palettes may not paint it
        expect(
          themeColorContrast(fgOf(t.toolOutput)!, tint),
          greaterThanOrEqualTo(kThemeBodyTextFloor),
          reason: '${entry.key}: detail text on toolPendingBg',
        );
        expect(
          themeColorContrast(fgOf(t.toolTitle)!, tint),
          greaterThanOrEqualTo(kThemeSecondaryTextFloor),
          reason: '${entry.key}: label on toolPendingBg',
        );
      }
    });

    test('thinking scale steps clear 3:1 on the reference terminal', () {
      for (final entry in kBuiltInTuiThemes.entries) {
        if (!entry.key.startsWith('ohmypi')) continue;
        final t = entry.value;
        final terminalBg = themeReferenceTerminalBg(t);
        // thinkingText is body text (the thinking block prose), not a
        // scale label — it holds the 4.5:1 body floor (review k6LLp).
        expect(
          themeColorContrast(fgOf(t.thinkingText)!, terminalBg),
          greaterThanOrEqualTo(kThemeBodyTextFloor),
          reason:
              '${entry.key}.thinkingText is '
              '${themeColorContrast(fgOf(t.thinkingText)!, terminalBg)
                  .toStringAsFixed(2)}:1 on the reference terminal',
        );
        for (final (name, style) in [
          ('thinkingOff', t.thinkingOff),
          ('thinkingMinimal', t.thinkingMinimal),
          ('thinkingLow', t.thinkingLow),
          ('thinkingMedium', t.thinkingMedium),
          ('thinkingHigh', t.thinkingHigh),
          ('thinkingXhigh', t.thinkingXhigh),
        ]) {
          expect(
            themeColorContrast(fgOf(style)!, terminalBg),
            greaterThanOrEqualTo(kThemeSecondaryTextFloor),
            reason:
                '${entry.key}.$name is '
                '${themeColorContrast(fgOf(style)!, terminalBg)
                    .toStringAsFixed(2)}:1 on the reference terminal',
          );
        }
      }
    });

    test('every new emitter paints under truecolor (review k6LOc)', () {
      final controller = FaThemeController.instance
        ..reset()
        ..switchTo('ohmypi-dark');
      final emitters = <String, String Function(String)>{
        'toolPendingBg': controller.toolPendingBg,
        'customMessageBg': controller.customMessageBg,
        'customMessageText': controller.customMessageText,
        'thinkingText': controller.thinkingText,
        'thinkingOff': controller.thinkingOff,
        'thinkingMinimal': controller.thinkingMinimal,
        'thinkingLow': controller.thinkingLow,
        'thinkingMedium': controller.thinkingMedium,
        'thinkingHigh': controller.thinkingHigh,
        'thinkingXhigh': controller.thinkingXhigh,
        'mdHeading': controller.mdHeading,
        'mdLink': controller.mdLink,
        'mdLinkUrl': controller.mdLinkUrl,
        'mdCode': controller.mdCode,
        'mdCodeBlock': controller.mdCodeBlock,
        'mdCodeBlockBorder': controller.mdCodeBlockBorder,
        'mdQuote': controller.mdQuote,
        'mdQuoteBorder': controller.mdQuoteBorder,
        'mdHr': controller.mdHr,
        'mdListBullet': controller.mdListBullet,
        'link': controller.link,
        'toolDiffAdded': controller.toolDiffAdded,
        'toolDiffRemoved': controller.toolDiffRemoved,
        'toolDiffContext': controller.toolDiffContext,
        'syntaxComment': controller.syntaxComment,
        'syntaxKeyword': controller.syntaxKeyword,
        'syntaxFunction': controller.syntaxFunction,
        'syntaxVariable': controller.syntaxVariable,
        'syntaxString': controller.syntaxString,
        'syntaxNumber': controller.syntaxNumber,
        'syntaxType': controller.syntaxType,
        'syntaxOperator': controller.syntaxOperator,
        'syntaxPunctuation': controller.syntaxPunctuation,
        'bashMode': controller.bashMode,
        'pythonMode': controller.pythonMode,
        'statusLineSep': controller.statusLineSep,
        'statusLineModel': controller.statusLineModel,
        'statusLinePath': controller.statusLinePath,
        'statusLineGitClean': controller.statusLineGitClean,
        'statusLineGitDirty': controller.statusLineGitDirty,
        'statusLineContext': controller.statusLineContext,
        'statusLineSpend': controller.statusLineSpend,
        'statusLineStaged': controller.statusLineStaged,
        'statusLineDirty': controller.statusLineDirty,
        'statusLineUntracked': controller.statusLineUntracked,
        'statusLineOutput': controller.statusLineOutput,
        'statusLineCost': controller.statusLineCost,
        'statusLineSubagents': controller.statusLineSubagents,
        'accentSgr': (text) => '${controller.accentSgr()}$text\x1b[0m',
      };
      expect(emitters, hasLength(49));
      final sgr = RegExp(r'\x1b\[(38|48);2;\d+;\d+;\d+m');
      emitters.forEach((name, emit) {
        expect(
          sgr.hasMatch(emit('x')),
          isTrue,
          reason: '$name must carry a truecolor SGR under ohmypi-dark',
        );
      });
    });
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

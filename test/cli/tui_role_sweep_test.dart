// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.
//
// Issue #444 — TUI color-consistency pass:
//
// - AC1 `UT-role-coverage`: a recording (sentinel) theme walks every TUI
//   row renderer; every colorized segment must resolve to a NAMED role —
//   zero anonymous ANSI picks. Backed by a source guard so the audit
//   stays true, not just today's renderers.
// - AC2 `UT-stable-across-rerenders`: the busy row (`242s` fixture)
//   renders byte-identical colors across 3 consecutive rerenders.
// - AC3/AC5 borders + Fa mark: state→role mapping pins.
// - AC4 `GOLDEN-user-message`: user band at 80/120/200 in light+dark,
//   contrast asserted programmatically (≥ 7:1).
// - AC7 `UT-theme-override`: user-theme JSON overrides flow to rows.
// - E1 old themes without the new keys; E2 NO_COLOR / 256-color degrade.
library;

import 'dart:io' as io;

import 'package:dart_tui/style.dart' show ColorProfile, RgbColor, Style, Theme;
import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/tui_text_width.dart'
    show tuiFitWidth;
import 'package:flutter_agent_harness/src/cli/tool_rows.dart';
import 'package:flutter_agent_harness/src/cli/tui_theme.dart';
import 'package:test/test.dart';

/// A theme where every role carries a UNIQUE sentinel color: any escape
/// a renderer emits is then attributable to exactly one role.
Theme _sentinel() {
  var n = 0;
  RgbColor next() => RgbColor(10 + ++n * 7, 20 + n * 5, 30 + n * 3);
  return Theme(
    name: 'sentinel',
    base: Style(),
    muted: Style(foregroundRgb: next(), isDim: true),
    accent: Style(foregroundRgb: next(), isBold: true),
    highlight: Style(backgroundRgb: next()),
    success: Style(foregroundRgb: next()),
    warning: Style(foregroundRgb: next()),
    error: Style(foregroundRgb: next()),
    border: Style(foregroundRgb: next()),
    focusBorder: Style(foregroundRgb: next()),
    accent2: Style(foregroundRgb: next(), isBold: true),
    accent2Soft: Style(foregroundRgb: next()),
    userMessageBg: Style(backgroundRgb: next()),
    borderMuted: Style(foregroundRgb: next(), isDim: true),
    toolTitle: Style(foregroundRgb: next(), isBold: true),
    toolOutput: Style(foregroundRgb: next(), isDim: true),
    userMessageText: Style(foregroundRgb: next()),
    toolSuccessBg: Style(backgroundRgb: next()),
    toolErrorBg: Style(backgroundRgb: next()),
  );
}

/// Every individual SGR escape the sentinel theme's roles can emit.
Set<String> _roleEscapes(Theme t) {
  final escapes = <String>{'\x1b[0m'};
  for (final style in [
    t.base,
    t.muted,
    t.accent,
    t.highlight,
    t.success,
    t.warning,
    t.error,
    t.border,
    t.focusBorder,
    t.accent2,
    t.accent2Soft,
    t.userMessageBg,
    t.borderMuted,
    t.toolTitle,
    t.toolOutput,
    t.userMessageText,
    t.toolSuccessBg,
    t.toolErrorBg,
    // Derived (non-field) emitters render too.
    Style(foregroundRgb: t.accent.foregroundRgb),
  ]) {
    for (final escape in tuiSgr(style).split(RegExp(r'(?=\x1b)'))) {
      if (escape.isNotEmpty) escapes.add(escape);
    }
  }
  // Attributes (bold/dim/italic/underline + default fg/bg resets) are
  // not color picks — they are style flags carried BY roles.
  escapes.addAll(['\x1b[1m', '\x1b[2m', '\x1b[3m', '\x1b[4m']);
  return escapes;
}

void main() {
  // ANSI SGR/CSI sequences carry zero cells.
  final ansi = RegExp(r'\x1b\[[0-9;?]*[A-Za-z]');
  final sgr = RegExp(r'\x1b\[[0-9;]*m');

  setUp(() {
    FaThemeController.instance
      ..reset()
      ..profile = ColorProfile.trueColor;
  });

  group('AC1 UT-role-coverage', () {
    test('every row renderer emits only named-role escapes', () {
      final sentinel = _sentinel();
      FaThemeController.instance.addUserThemes({'sentinel': sentinel});
      FaThemeController.instance.switchTo('sentinel');
      final allowed = _roleEscapes(sentinel);

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
      final markdown = AnsiMarkdown(
        width: 60,
      ).formatAll(const ['# Title', '- a **b** `c`', '```', 'code', '```']);
      final surfaces = <String, List<String>>{
        'faMark': [tuiFaMark()],
        'userBand': [tuiUserMessageLine('fix the login flow')],
        'toolRunning': [tuiToolRow(row('•', 'npm test'), ToolRowState.running)],
        'toolSettled': [
          tuiToolRow(row('●', 'tail -f x.log'), ToolRowState.settled),
        ],
        'toolDone': [
          tuiToolRow(row('✓', 'npm test', elapsed: '3s'), ToolRowState.done),
        ],
        'toolFailed': [
          tuiToolRow(row('✗', 'exit 1', elapsed: '0s'), ToolRowState.failed),
        ],
        'markdown': markdown,
      };

      surfaces.forEach((name, lines) {
        for (final line in lines) {
          for (final escape in sgr.allMatches(line).map((m) => m[0])) {
            expect(
              allowed,
              contains(escape),
              reason:
                  '$name emitted a non-role escape "$escape" — an '
                  'anonymous ANSI pick is forbidden (issue #444 defect 1)',
            );
          }
        }
      });
    });

    test('the live TUI frame emits only named-role escapes', () {
      final sentinel = _sentinel();
      FaThemeController.instance.addUserThemes({'sentinel': sentinel});
      FaThemeController.instance.switchTo('sentinel');
      final allowed = _roleEscapes(sentinel);
      var model = FaTuiModel(
        callbacks: FaTuiCallbacks(
          onSubmit: (_, {images = const []}) async {},
          onModelSelected: (_) async {},
          buildSlashMenu: (_) => const [],
          buildModelMenu: (_, _) => const [],
          statusLine: () => 'ready',
          prompt: '> ',
        ),
        isExited: () => false,
        termWidth: 80,
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      model = model.update(const BusyMsg(true, source: 'run')).$1 as FaTuiModel;
      model = model.copyWith(
        busyStartedAtMs: now - 242 * 1000,
        busyLastEventMs: now,
        busyPhase: 'Running bash…',
        outputLines: const ['pick a card', 'any card'],
      );
      final frame = model.view().content;
      for (final line in frame.split('\n')) {
        for (final escape in sgr.allMatches(line).map((m) => m[0])) {
          expect(
            allowed,
            contains(escape),
            reason:
                'TUI frame line "$line" emitted a non-role escape '
                '"$escape" (issue #444 defect 1)',
          );
        }
      }
    });

    test('source guard: no anonymous _style color calls remain in cli', () {
      // Line-mode-only surfaces (the REPL fallback when the terminal
      // cannot enter raw/ANSI+theme mode) keep the legacy _Style helper:
      // the theme controller has no profile there. Each entry must name
      // the TUI-invisible reason it is exempt.
      const lineModeOnly = {
        'lib/src/cli/approval_commands.dart':
            '_writeIdlePrompt early-returns when _useTui',
      };
      final offenders = <String>[];
      for (final file in io.Directory('lib/src/cli')
          .listSync(recursive: true)
          .whereType<io.File>()) {
        if (!file.path.endsWith('.dart')) continue;
        if (RegExp(
          r'_style\.(cyan|green|yellow|red|magenta|white|blue)\(',
        ).hasMatch(file.readAsStringSync())) {
          if (!lineModeOnly.containsKey(file.path)) offenders.add(file.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'anonymous ANSI color helpers bypass the theme roles; '
            'use the tui* emitters (issue #444 defect 1). Line-mode-only '
            'exemptions live in [lineModeOnly] with a reason.',
      );
    });
  });

  group('AC2 UT-stable-across-rerenders', () {
    FaTuiCallbacks callbacks() => FaTuiCallbacks(
      onSubmit: (_, {images = const []}) async {},
      onModelSelected: (_) async {},
      buildSlashMenu: (_) => const [],
      buildModelMenu: (_, _) => const [],
      statusLine: () => '',
      prompt: '',
    );

    FaTuiModel busyModelAt242s() {
      var model = FaTuiModel(
        callbacks: callbacks(),
        isExited: () => false,
        termWidth: 80,
      );
      model = model.update(const BusyMsg(true, source: 'run')).$1 as FaTuiModel;
      final now = DateTime.now().millisecondsSinceEpoch;
      return model.copyWith(
        busyStartedAtMs: now - 242 * 1000,
        busyLastEventMs: now,
      );
    }

    test('the busy row renders byte-identical colors across 3 rerenders', () {
      final model = busyModelAt242s();
      List<String> colorOfFirstRow() {
        final row = model
            .view()
            .content
            .split('\n')
            .firstWhere((line) => line.contains('242s'));
        return sgr.allMatches(row).map((m) => m[0]!).toList();
      }

      final first = colorOfFirstRow();
      expect(first, isNotEmpty);
      expect(colorOfFirstRow(), first);
      expect(colorOfFirstRow(), first);
    });

    test('the full frame renders byte-identical colors across 3 rerenders', () {
      final model = busyModelAt242s();
      List<String> frameColors() =>
          sgr.allMatches(model.view().content).map((m) => m[0]!).toList();
      final first = frameColors();
      expect(frameColors(), first);
      expect(frameColors(), first);
    });
  });

  group('AC3/AC5 state→role mapping and the Fa mark', () {
    test('tool row borders pick the border role by state', () {
      final c = FaThemeController.instance;
      String railOf(String row) {
        final match = sgr.firstMatch(row);
        return match == null ? '' : match[0]!;
      }

      expect(
        railOf(
          tuiToolRow(
            layoutToolRow(const ToolRowSegments(glyph: '•', label: 'bash'), 78),
            ToolRowState.running,
          ),
        ),
        tuiSgr(c.current.focusBorder),
        reason: 'running rows carry the accent border (pi borderAccent)',
      );
      expect(
        railOf(
          tuiToolRow(
            layoutToolRow(const ToolRowSegments(glyph: '●', label: 'bash'), 78),
            ToolRowState.settled,
          ),
        ),
        tuiSgr(c.current.borderMuted),
      );
      expect(
        railOf(
          tuiToolRow(
            layoutToolRow(const ToolRowSegments(glyph: '✓', label: 'bash'), 78),
            ToolRowState.done,
          ),
        ),
        tuiSgr(c.current.success),
      );
      expect(
        railOf(
          tuiToolRow(
            layoutToolRow(const ToolRowSegments(glyph: '✗', label: 'bash'), 78),
            ToolRowState.failed,
          ),
        ),
        tuiSgr(c.current.error),
      );
    });

    test('done/failed rows tint with the tool*Bg roles; failed text stays '
        'bright', () {
      final c = FaThemeController.instance;
      final failed = tuiToolRow(
        layoutToolRow(
          const ToolRowSegments(glyph: '✗', label: 'bash', detail: 'boom'),
          78,
        ),
        ToolRowState.failed,
      );
      expect(failed, contains(tuiSgr(c.current.toolErrorBg)));
      expect(failed, isNot(contains(tuiSgr(c.current.toolOutput))));
      final done = tuiToolRow(
        layoutToolRow(
          const ToolRowSegments(glyph: '✓', label: 'bash', detail: 'ok'),
          78,
        ),
        ToolRowState.done,
      );
      expect(done, contains(tuiSgr(c.current.toolSuccessBg)));
      expect(done, contains(tuiSgr(c.current.toolOutput)));
    });

    test('the Fa mark composes exactly two roles', () {
      final c = FaThemeController.instance;
      expect(
        tuiFaMark(),
        '${tuiAccent('>_')}${tuiAccent2('Fa')} ',
        reason: 'the mark is defined ONCE in the theme (issue #444 defect 3)',
      );
      expect(tuiFaMark(), contains(tuiSgr(c.current.accent)));
      expect(tuiFaMark(), contains(tuiSgr(c.current.accent2)));
    });
  });

  group('AC4 user-message band', () {
    test('every built-in palette keeps a ≥7:1 text/band contrast', () {
      for (final entry in {...kBuiltInTuiThemes}.entries) {
        expect(
          themeUserMessageContrast(entry.value),
          greaterThanOrEqualTo(7),
          reason:
              '${entry.key}: userMessageText must stay readable on '
              'userMessageBg (issue #444 defect 4)',
        );
      }
    });

    test('the band renders userMessageText over userMessageBg', () {
      final c = FaThemeController.instance;
      expect(
        tuiUserMessageLine('deploy the site'),
        '${tuiSgr(c.current.userMessageBg)}'
        '${tuiSgr(c.current.userMessageText)}deploy the site\x1b[0m',
      );
    });

    final update = io.Platform.environment.containsKey('FA_UPDATE_444_GOLDENS');
    for (final theme in const ['default', 'ohmypi-light']) {
      for (final width in const [80, 120, 200]) {
        test('golden: user band $theme @$width', () {
          FaThemeController.instance.reset();
          FaThemeController.instance.switchTo(theme);
          final text =
              ' fix the flaky login flow on the settings screen '
              'before the release cut ';
          final band = [
            tuiDim('─' * width),
            tuiUserMessageLine(tuiFitWidth(text, width)),
          ].join('\n');
          final file = io.File(
            'test/cli/goldens/tui_user_band_'
            '${theme}_$width.ans',
          );
          if (update) {
            file.writeAsStringSync('$band\n');
            return;
          }
          expect(band, file.readAsStringSync().trim());
        });
      }
    }
  });

  group('AC7 UT-theme-override', () {
    test('user theme overrides of userMessageText/borderMuted reach rows', () {
      final theme = parseUserTheme(
        '{"roles": {"userMessageText": "#FF00FF", "borderMuted": "#00FF00"}}',
        'override.json',
      );
      FaThemeController.instance.addUserThemes({'override': theme});
      expect(FaThemeController.instance.switchTo('override'), isTrue);
      expect(tuiUserMessageLine('hello'), contains('\x1b[38;2;255;0;255m'));
      expect(
        tuiToolRow(
          layoutToolRow(const ToolRowSegments(glyph: '●', label: 'bash'), 78),
          ToolRowState.settled,
        ),
        contains('\x1b[38;2;0;255;0m'),
      );
    });
  });

  group('E1/E2 degrade paths', () {
    test('E1: an old user theme without the new keys inherits defaults, '
        'never random colors', () {
      final partial = parseUserTheme(
        '{"roles": {"accent": "#ABCDEF"}}',
        'old.json',
      );
      FaThemeController.instance.reset();
      final before = tuiUserMessageLine('hello');
      final rowBefore = tuiToolRow(
        layoutToolRow(
          const ToolRowSegments(glyph: '•', label: 'bash', detail: 'x'),
          78,
        ),
        ToolRowState.running,
      );
      FaThemeController.instance.addUserThemes({'old': partial});
      expect(FaThemeController.instance.switchTo('old'), isTrue);
      expect(tuiUserMessageLine('hello'), before);
      expect(
        tuiToolRow(
          layoutToolRow(
            const ToolRowSegments(glyph: '•', label: 'bash', detail: 'x'),
            78,
          ),
          ToolRowState.running,
        ),
        rowBefore,
      );
    });

    test('E2: styling off renders plain and deterministically', () {
      FaThemeController.instance.profile = null;
      expect(tuiFaMark(), '>_Fa ');
      expect(tuiUserMessageLine('hello'), 'hello');
      final row = tuiToolRow(
        layoutToolRow(
          const ToolRowSegments(glyph: '•', label: 'bash', detail: 'x'),
          78,
        ),
        ToolRowState.running,
      );
      expect(row, '│ • bash · x');
      expect(
        tuiToolRow(
          layoutToolRow(
            const ToolRowSegments(glyph: '•', label: 'bash', detail: 'x'),
            78,
          ),
          ToolRowState.running,
        ),
        row,
      );
    });

    test('E2: 256-color degrade is deterministic across rerenders', () {
      FaThemeController.instance.profile = ColorProfile.ansi256;
      final row = tuiToolRow(
        layoutToolRow(
          const ToolRowSegments(glyph: '✓', label: 'bash', detail: 'ok'),
          78,
        ),
        ToolRowState.done,
      );
      expect(
        tuiToolRow(
          layoutToolRow(
            const ToolRowSegments(glyph: '✓', label: 'bash', detail: 'ok'),
            78,
          ),
          ToolRowState.done,
        ),
        row,
      );
      expect(
        ansi.hasMatch(row),
        isTrue,
        reason: 'still styled, just quantized',
      );
    });
  });
}

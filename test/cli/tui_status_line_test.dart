/// The omp status bar engine (issue #805): registry completeness against
/// the 27-id table, preset shapes, separator variants, the elastic
/// truncation ladder as property tests across widths 40..200, the
/// context gauge thresholds and fill, the config parse contract
/// (valid / unknown-id-warn / strict errors) and snapshot purity
/// (deterministic, no IO).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/tui_text_width.dart'
    show tuiTextWidth;
import 'package:flutter_agent_harness/src/cli/tui_theme.dart' show TuiTheme;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

Object? _tui(String text) => loadYaml(text)['tui'];

StatusLineSnapshot _richSnapshot() => const StatusLineSnapshot(
  cwd: '/Users/ag/work/flutter_agent_harness/lib/src/cli',
  homeDir: '/Users/ag',
  workRoot: '/Users/ag/work/flutter_agent_harness',
  modelName: 'zai/glm-5.3-flash',
  thinkingLevel: 'high',
  approvalMode: 'yolo',
  git: StatusLineGit(branch: 'main', unstaged: 2, untracked: 1),
  contextTokens: 4200,
  contextWindow: 10000,
  tokensIn: 1500,
  tokensOut: 300,
  costUsd: 1.25,
  sessionName: 'fixing-the-status-bar',
  sessionId: 'abc123de',
  subagents: 2,
  hostname: 'mac',
);

StatusLineSpec _defaultSpec() => resolveStatusLineSpec(null);

/// The rich snapshot minus the context window: no gauge in the middle,
/// so the truncation-ladder steps can be pinned exactly.
StatusLineSnapshot _ladderSnapshot() => StatusLineSnapshot(
  cwd: '/Users/ag/work/flutter_agent_harness/lib/src/cli',
  homeDir: '/Users/ag',
  workRoot: '/Users/ag/work/flutter_agent_harness',
  modelName: 'zai/glm-5.3-flash',
  thinkingLevel: 'high',
  sessionName: 'fixing-the-status-bar',
  costUsd: 1.25,
);

void main() {
  group('segment registry', () {
    test('covers exactly the omp 27 ids', () {
      expect(kStatusLineSegmentIds, hasLength(27));
      expect(kStatusLineSegments.keys.toSet(), kStatusLineSegmentIds.toSet());
    });

    test('every id renders without data or throws never', () {
      const empty = StatusLineSnapshot(cwd: '/');
      for (final id in kStatusLineSegmentIds) {
        expect(
          () => kStatusLineSegments[id]!(empty, _defaultSpec()),
          returnsNormally,
          reason: 'segment $id must tolerate an empty snapshot',
        );
      }
    });

    test('data absence hides segments instead of placeholders', () {
      const empty = StatusLineSnapshot(cwd: '/');
      expect(kStatusLineSegments['model']!(empty, _defaultSpec()), isNull);
      expect(kStatusLineSegments['git']!(empty, _defaultSpec()), isNull);
      expect(kStatusLineSegments['pr']!(empty, _defaultSpec()), isNull);
      expect(kStatusLineSegments['cost']!(empty, _defaultSpec()), isNull);
      // An unpriced model (cost null) hides; a priced $0 renders $0.00.
      const priced = StatusLineSnapshot(cwd: '/', costUsd: 0);
      expect(
        kStatusLineSegments['cost']!(priced, _defaultSpec())!.text,
        '\$0.00',
      );
    });

    test('hidden-by-design ids stay valid but render nothing', () {
      const s = StatusLineSnapshot(cwd: '/');
      for (final id in ['usage', 'collab', 'vim', 'cache_hit']) {
        expect(
          kStatusLineSegments[id]!(s, _defaultSpec()),
          isNull,
          reason: '$id has no fa data source yet',
        );
      }
    });

    test('model segment carries the thinking-level suffix', () {
      const s = StatusLineSnapshot(cwd: '/', modelName: 'm1');
      expect(kStatusLineSegments['model']!(s, _defaultSpec())!.text, 'm1');
      const leveled = StatusLineSnapshot(
        cwd: '/',
        modelName: 'm1',
        thinkingLevel: 'high',
      );
      expect(
        kStatusLineSegments['model']!(leveled, _defaultSpec())!.text,
        'm1 · high',
      );
      final noSuffixSpec = resolveStatusLineSpec(
        const StatusLineConfig(
          segmentOptions: StatusLineSegmentOptions(
            modelShowThinkingLevel: false,
          ),
        ),
      );
      expect(kStatusLineSegments['model']!(leveled, noSuffixSpec)!.text, 'm1');
    });
  });

  group('presets', () {
    test('exactly the 7 omp presets', () {
      expect(kStatusLinePresets.keys.toSet(), {
        'default',
        'minimal',
        'compact',
        'full',
        'nerd',
        'ascii',
        'custom',
      });
      expect(kStatusLinePresetNames, hasLength(7));
    });

    test('every preset id list stays within the 27-id table', () {
      for (final preset in kStatusLinePresets.values) {
        for (final id in [...preset.left, ...preset.right]) {
          expect(kStatusLineSegmentIds, contains(id));
        }
      }
    });

    test('shapes pin the omp table', () {
      expect(kStatusLinePresets['default']!.left.first, 'pi');
      expect(kStatusLinePresets['default']!.right, ['session_name']);
      expect(
        kStatusLinePresets['default']!.separator,
        StatusLineSeparatorStyle.powerlineThin,
      );
      expect(
        kStatusLinePresets['ascii']!.separator,
        StatusLineSeparatorStyle.ascii,
      );
      expect(kStatusLinePresets['nerd']!.nerd, isTrue);
      for (final name in ['default', 'minimal', 'compact', 'full', 'ascii']) {
        expect(kStatusLinePresets[name]!.nerd, isFalse, reason: name);
      }
      expect(kStatusLinePresets['minimal']!.options.maxLength, 30);
      expect(kStatusLinePresets['full']!.options.showSeconds, isFalse);
      expect(kStatusLinePresets['nerd']!.options.showSeconds, isTrue);
    });

    test('resolve defaults, explicit preset and custom implication', () {
      expect(_defaultSpec().left, kStatusLinePresets['default']!.left);
      final minimal = resolveStatusLineSpec(
        const StatusLineConfig(preset: 'minimal'),
      );
      expect(minimal.left, kStatusLinePresets['minimal']!.left);
      final custom = resolveStatusLineSpec(
        const StatusLineConfig(left: ['model'], right: ['cost']),
      );
      // Explicit groups without a preset imply the custom base.
      expect(custom.separator, kStatusLinePresets['custom']!.separator);
      expect(custom.left, ['model']);
      expect(custom.right, ['cost']);
    });
  });

  group('separators', () {
    test('all 7 styles resolve glyphs', () {
      expect(getSeparator(StatusLineSeparatorStyle.powerline).left, '▶');
      expect(
        getSeparator(StatusLineSeparatorStyle.powerline).capAfterLeft,
        '◀',
      );
      expect(getSeparator(StatusLineSeparatorStyle.powerlineThin).left, '>');
      expect(getSeparator(StatusLineSeparatorStyle.slash).left, '/');
      expect(getSeparator(StatusLineSeparatorStyle.pipe).left, '│');
      expect(getSeparator(StatusLineSeparatorStyle.block).left, '▌');
      expect(getSeparator(StatusLineSeparatorStyle.space).left, ' ');
      expect(getSeparator(StatusLineSeparatorStyle.ascii).left, '>');
      expect(getSeparator(StatusLineSeparatorStyle.ascii).right, '<');
    });

    test('nerd table swaps the powerline and block glyphs', () {
      final nerd = getSeparator(StatusLineSeparatorStyle.powerline, nerd: true);
      expect(nerd.left.length, 1);
      expect(
        nerd.left.codeUnitAt(0),
        greaterThan(0xE000),
        reason: 'nerd glyphs live in the private-use area',
      );
      expect(
        getSeparator(StatusLineSeparatorStyle.slash, nerd: true).left,
        '/',
      );
      expect(
        getSeparator(StatusLineSeparatorStyle.block, nerd: true).left,
        '█',
      );
    });

    test('parse and strict errors', () {
      expect(parseStatusLineSeparator('slash'), StatusLineSeparatorStyle.slash);
      expect(
        () => parseStatusLineSeparator('nope'),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('truncation ladder (widths 40..200)', () {
    final snapshot = _richSnapshot();
    final spec = _defaultSpec();
    // No context window: the gauge never renders in this group.
    final ladderSnapshot = _ladderSnapshot();

    for (var width = 40; width <= 200; width += 5) {
      test('width $width renders one width-exact row', () {
        final lines = renderStatusLine(snapshot, spec, width);
        expect(lines, hasLength(1));
        expect(lines.single, isNotEmpty);
        expect(tuiTextWidth(lines.single), lessThanOrEqualTo(width));
      });
    }

    test('everything fits at a generous width', () {
      final line = renderStatusLine(snapshot, spec, 200).single;
      // The work-root strip renders the cwd relative to the workspace.
      expect(line, contains('lib/src/cli'));
      expect(line, isNot(contains('/Users/ag')));
      expect(line, contains('fixing-the-status-bar'));
    });

    // The ladder's step order, pinned on a minimal two-segment bar
    // (model 17 cells left, session_name 21 cells right):
    // session_name shrinks (8 → 4 → gone) BEFORE right pops.
    const twoGroupSpec = StatusLineSpec(
      left: ['model'],
      right: ['session_name'],
      separator: StatusLineSeparatorStyle.powerlineThin,
    );
    const model = 'zai/glm-5.3-flash';

    String at(int width) =>
        renderStatusLine(ladderSnapshot, twoGroupSpec, width).join();

    test('full bar fits at 45+', () {
      final line = at(50);
      expect(line, contains(model));
      expect(line, contains('fixing-the-status-bar'));
    });

    test('step 1: session_name shrinks to the ellipsis form first', () {
      final line = at(40);
      expect(line, contains(model));
      expect(line, contains('fixing-…'));
      expect(line, isNot(contains('fixing-the-status-bar')));
    });

    test('step 1 again: then to 4 cells, still keeping the model', () {
      final line = at(31);
      expect(line, contains(model));
      expect(line, contains('fix…'));
      expect(line, isNot(contains('fixing')));
    });

    test('step 2: session_name pops before the model drops', () {
      final line = at(27);
      expect(line, contains(model));
      expect(line, isNot(contains('fix')));
    });

    test('step 4: left drops left-to-right last', () {
      const costOnly = StatusLineSpec(
        left: ['model', 'cost'],
        right: [],
        separator: StatusLineSeparatorStyle.powerlineThin,
      );
      final line = renderStatusLine(ladderSnapshot, costOnly, 24).single.trim();
      expect(line, '\$1.25');
      expect(line, isNot(contains(model)));
    });

    test('step 3: the path re-renders at shrinking maxLengths', () {
      const pathOnly = StatusLineSpec(
        left: ['path'],
        right: [],
        separator: StatusLineSeparatorStyle.powerlineThin,
      );
      const cwd = '/Users/ag/work/flutter_agent_harness/lib/src/cli';
      const home = '/Users/ag';
      final full = StatusLineSnapshot(cwd: cwd, homeDir: home);
      final wide = renderStatusLine(full, pathOnly, 45).single.trim();
      final narrow = renderStatusLine(full, pathOnly, 30).single.trim();
      // The abbreviated path clamps at maxLength (40 default, 30 after
      // the shrink step).
      expect(tuiTextWidth(wide), 40);
      expect(tuiTextWidth(narrow), 30);
      expect(narrow.length, lessThan(wide.length));
    });

    test('irreducible overflow never exceeds the width', () {
      final huge = StatusLineSnapshot(
        cwd: '/x/${'y' * 300}',
        modelName: 'm' * 300,
        contextWindow: 10000,
        contextTokens: 9000,
      );
      for (final width in [40, 60, 100]) {
        final line = renderStatusLine(huge, spec, width).single;
        expect(tuiTextWidth(line), lessThanOrEqualTo(width));
      }
    });

    test('empty groups render nothing', () {
      const empty = StatusLineSnapshot(cwd: '/');
      final blank = resolveStatusLineSpec(
        const StatusLineConfig(
          preset: 'custom',
          left: ['usage'],
          right: ['vim'],
        ),
      );
      expect(renderStatusLine(empty, blank, 80), isEmpty);
    });
  });

  group('context gauge', () {
    test('thresholds: 50 warn, 90 error', () {
      expect(statusLineGaugeLevel(0), StatusLineGaugeLevel.normal);
      expect(statusLineGaugeLevel(49.9), StatusLineGaugeLevel.normal);
      expect(statusLineGaugeLevel(50), StatusLineGaugeLevel.warn);
      expect(statusLineGaugeLevel(89.9), StatusLineGaugeLevel.warn);
      expect(statusLineGaugeLevel(90), StatusLineGaugeLevel.error);
      expect(statusLineGaugeLevel(120), StatusLineGaugeLevel.error);
    });

    test('percent format: one decimal only below 1%', () {
      expect(formatStatusLinePercent(0.3), '0.3%');
      expect(formatStatusLinePercent(42), '42%');
      expect(formatStatusLinePercent(99.6), '100%');
    });

    test('minimum width covers both labels plus the bridge', () {
      expect(
        statusLineGaugeMinWidth(42, 10000),
        '42%'.length + formatTokens(10000).length + 4,
      );
    });

    test('fill lands between the groups at the right level', () {
      final snapshot = _richSnapshot();
      final spec = _defaultSpec();
      final spans = renderStatusLineSpans(snapshot, spec, 160);
      final gaugeRoles = spans
          .where((s) => s.$1.contains('━'))
          .map((s) => s.$2)
          .toSet();
      // 42 %: the used cells carry the gauge role, unused cells the
      // unused role; the label carries the level role (normal → gauge).
      expect(gaugeRoles, {
        StatusLineRoleKey.gaugeUsed,
        StatusLineRoleKey.gaugeUnused,
      });

      final warnSpans = renderStatusLineSpans(snapshot, spec, 160);
      // Level role appears on the percent label.
      final labelRole = warnSpans.firstWhere((s) => s.$1.trim() == '42%').$2;
      expect(labelRole, StatusLineRoleKey.gaugeUsed);

      StatusLineSnapshot at(double pct) => StatusLineSnapshot(
        cwd: '/',
        modelName: 'm',
        contextWindow: 10000,
        contextTokens: (100 * pct).round(),
      );
      expect(
        renderStatusLineSpans(
          at(60),
          spec,
          160,
        ).firstWhere((s) => s.$1.trim() == '60%').$2,
        StatusLineRoleKey.warn,
      );
      expect(
        renderStatusLineSpans(
          at(95),
          spec,
          160,
        ).firstWhere((s) => s.$1.trim() == '95%').$2,
        StatusLineRoleKey.error,
      );
    });

    test('unknown window hides the gauge, keeps the groups', () {
      const noWindow = StatusLineSnapshot(cwd: '/', modelName: 'm');
      final spans = renderStatusLineSpans(noWindow, _defaultSpec(), 80);
      final text = spans.map((s) => s.$1).join();
      expect(text, contains('m'));
      expect(text, isNot(contains('%')));
    });
  });

  group('config parse', () {
    test('valid full section', () {
      final tui = parseTuiSection(
        _tui('''
tui:
  theme: catppuccin
  classic: true
  statusLine:
    preset: minimal
    separator: slash
    transparent: true
    left: [pi, model, path]
    right: [cost, context_pct]
    segmentOptions:
      path:
        maxLength: 30
        abbreviate: false
      time:
        format: 12h
        showSeconds: true
'''),
      );
      expect(tui.theme, 'catppuccin');
      expect(tui.classic, isTrue);
      final sl = tui.statusLine!;
      expect(sl.preset, 'minimal');
      expect(sl.separator, StatusLineSeparatorStyle.slash);
      expect(sl.transparent, isTrue);
      expect(sl.left, ['pi', 'model', 'path']);
      expect(sl.right, ['cost', 'context_pct']);
      expect(sl.segmentOptions!.maxLength, 30);
      expect(sl.segmentOptions!.abbreviate, isFalse);
      expect(sl.segmentOptions!.time24h, isFalse);
      expect(sl.segmentOptions!.timeShowSeconds, isTrue);
    });

    test('unknown segment ids warn and drop at resolve, never throw', () {
      final warnings = <String>[];
      final spec = resolveStatusLineSpec(
        const StatusLineConfig(left: ['model', 'bogus'], right: ['nope']),
        warn: warnings.add,
      );
      expect(spec.left, ['model']);
      expect(spec.right, isEmpty);
      expect(warnings, hasLength(2));
      expect(warnings.first, contains('bogus'));
    });

    test(' CliConfig parses and round-trips the tui section', () {
      final config = parseTuiSection(
        _tui('''
tui:
  statusLine:
    preset: ascii
'''),
      );
      expect(config.statusLine!.preset, 'ascii');
    });

    test('strict errors', () {
      expect(
        () => parseTuiSection(_tui('tui: nope')),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => parseTuiSection(_tui('tui:\n  bogus: 1')),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => parseTuiSection(_tui('tui:\n  classic: yes-please')),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => parseTuiSection(_tui('tui:\n  statusLine: minimal')),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => parseTuiSection(_tui('tui:\n  statusLine:\n    preset: fancy')),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () =>
            parseTuiSection(_tui('tui:\n  statusLine:\n    separator: fancy')),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => parseTuiSection(_tui('tui:\n  statusLine:\n    left: model')),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => parseTuiSection(_tui('tui:\n  statusLine:\n    left: [42]')),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => parseTuiSection(
          _tui('''
tui:
  statusLine:
    segmentOptions:
      path:
        maxLength: 0
'''),
        ),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => parseTuiSection(
          _tui('''
tui:
  statusLine:
    segmentOptions:
      bogus: {}
'''),
        ),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => parseTuiSection(
          _tui('''
tui:
  statusLine:
    segmentOptions:
      time:
        format: military
'''),
        ),
        throwsA(isA<ConfigException>()),
      );
    });

    test('toYaml writes only non-defaults and re-parses', () {
      const config = StatusLineConfig(
        preset: 'minimal',
        separator: StatusLineSeparatorStyle.pipe,
        segmentOptions: StatusLineSegmentOptions(pathMaxLength: 25),
      );
      final yaml = config.toYaml();
      expect(yaml, contains('preset: minimal'));
      expect(yaml, contains('separator: pipe'));
      expect(yaml, contains('maxLength: 25'));
      expect(yaml, isNot(contains('transparent')));
      final reparsed = parseTuiSection(
        (loadYaml('tui:\n${config.toYaml()}') as YamlMap)['tui'],
      ).statusLine!;
      expect(reparsed.preset, 'minimal');
      expect(reparsed.separator, StatusLineSeparatorStyle.pipe);
      expect(reparsed.segmentOptions!.maxLength, 25);
    });

    test('CliConfig carries the fields and emits the section', () {
      final config = CliConfig(
        tuiTheme: 'catppuccin',
        statusLine: const StatusLineConfig(preset: 'compact'),
      );
      final yaml = config.toYaml();
      expect(yaml, contains('tui:'));
      expect(yaml, contains('theme: catppuccin'));
      expect(yaml, contains('preset: compact'));
      final reparsed = CliConfig.fromYaml(loadYaml(yaml) as YamlMap);
      expect(reparsed.tuiTheme, 'catppuccin');
      expect(reparsed.statusLine!.preset, 'compact');
      expect(reparsed.tuiClassic, isFalse);
      // The kill switch round-trips too.
      final classic = CliConfig.fromYaml(
        loadYaml('tui:\n  classic: true\n') as YamlMap,
      );
      expect(classic.tuiClassic, isTrue);
      expect(classic.toYaml(), contains('classic: true'));
    });
  });

  group('snapshot purity', () {
    test('render is deterministic and read-only', () {
      final snapshot = _richSnapshot();
      final spec = _defaultSpec();
      expect(
        renderStatusLine(snapshot, spec, 120),
        renderStatusLine(snapshot, spec, 120),
      );
    });

    test('git porcelain fixture parses (host seam format)', () {
      final git = parseGitStatusPorcelain('''
## main...origin/main
 M unstaged-one
M  staged-one
?? untracked-one
?? untracked-two
''');
      expect(git.branch, 'main');
      expect(git.staged, 1);
      expect(git.unstaged, 1);
      expect(git.untracked, 2);
      expect(git.isDirty, isTrue);
      expect(
        parseGitStatusPorcelain('## main...origin/main\n').isDirty,
        isFalse,
      );
    });

    test('path abbreviation and work-root strip', () {
      expect(
        abbreviateSegmentPath(
          '/Users/ag/work/x',
          homeDir: '/Users/ag',
          abbreviate: true,
          maxLength: 40,
          workRoot: '/Users/ag/work/x',
          stripWorkPrefix: true,
        ),
        '.',
      );
      expect(
        abbreviateSegmentPath(
          '/Users/ag/elsewhere',
          homeDir: '/Users/ag',
          abbreviate: true,
          maxLength: 40,
          workRoot: null,
          stripWorkPrefix: true,
        ),
        '~/elsewhere',
      );
      expect(
        abbreviateSegmentPath(
          '/Users/ag',
          homeDir: '/Users/ag',
          abbreviate: true,
          maxLength: 40,
          workRoot: null,
          stripWorkPrefix: true,
        ),
        '~',
      );
      expect(
        abbreviateSegmentPath(
          '/a/very/long/path/that/overflows',
          abbreviate: false,
          maxLength: 10,
          stripWorkPrefix: false,
        ),
        '/a/very/l…',
      );
    });

    test('clock and duration formats', () {
      expect(
        formatStatusLineClock(
          DateTime(2026, 9, 22, 21, 3, 7),
          clock24h: true,
          showSeconds: false,
        ),
        '21:03',
      );
      expect(
        formatStatusLineClock(
          DateTime(2026, 9, 22, 21, 3, 7),
          clock24h: true,
          showSeconds: true,
        ),
        '21:03:07',
      );
      expect(
        formatStatusLineClock(
          DateTime(2026, 9, 22, 21, 3),
          clock24h: false,
          showSeconds: false,
        ),
        '9:03 PM',
      );
      expect(
        formatStatusLineDuration(
          const Duration(hours: 1, minutes: 2, seconds: 3),
        ),
        '1:02:03',
      );
      expect(
        formatStatusLineDuration(const Duration(minutes: 21, seconds: 3)),
        '21:03',
      );
    });

    test('brand fade tweens on the virtual clock', () {
      // Static endpoints.
      expect(statusLineBrandFadeT(lit: true, changedAgoMs: null), 1.0);
      expect(statusLineBrandFadeT(lit: false, changedAgoMs: null), 0.0);
      // 450 ms / 40 ms quantization: flip to idle renders fully lit at
      // t=0 and fully dim at the 450 ms settle.
      expect(statusLineBrandFadeT(lit: false, changedAgoMs: 0), 1.0);
      expect(statusLineBrandFadeT(lit: false, changedAgoMs: 450), 0.0);
      final mid = statusLineBrandFadeT(lit: false, changedAgoMs: 220);
      expect(mid, greaterThan(0.3));
      expect(mid, lessThan(0.8));
      // Ramping up mirrors it.
      expect(statusLineBrandFadeT(lit: true, changedAgoMs: 0), 0.0);
      expect(statusLineBrandFadeT(lit: true, changedAgoMs: 450), 1.0);
    });

    test('write-time style seam resolves through the role table', () {
      final theme = TuiTheme.catppuccin;
      final model = kStatusLineRoles[StatusLineRoleKey.model]!(theme);
      // Not idle: the role resolves as-is (same object identity).
      expect(
        identical(
          statusLineStyle(StatusLineRoleKey.model, theme: theme, idle: false),
          model,
        ),
        isTrue,
      );
      // Idle dims every non-brand span to the muted role.
      final muted = kStatusLineRoles[StatusLineRoleKey.dim]!(theme);
      expect(
        identical(
          statusLineStyle(StatusLineRoleKey.model, theme: theme, idle: true),
          muted,
        ),
        isTrue,
      );
      // The brand mark fades: at the lit endpoint the role resolves
      // as-is; mid-fade blends toward the muted rgb (a fresh Style).
      final brand = kStatusLineRoles[StatusLineRoleKey.brandA]!(theme);
      expect(
        identical(
          statusLineStyle(
            StatusLineRoleKey.brandA,
            theme: theme,
            idle: true,
            brandT: 1.0,
          ),
          brand,
        ),
        isTrue,
      );
      final mid = statusLineStyle(
        StatusLineRoleKey.brandA,
        theme: theme,
        idle: true,
        brandT: 0.5,
      );
      expect(identical(mid, brand), isFalse);
      expect(
        mid.foregroundRgb,
        isNot(equals(brand.foregroundRgb)),
        reason: 'mid-fade sits between the lit and dim endpoints',
      );
    });
  });

  group('review pins (#831 round 2)', () {
    test('pi brand mark text is pinned', () {
      const s = StatusLineSnapshot(cwd: '/');
      expect(kStatusLineSegments['pi']!(s, _defaultSpec())!.text, '>_Fa');
    });

    test('role table covers every StatusLineRoleKey', () {
      expect(kStatusLineRoles.keys.toSet(), StatusLineRoleKey.values.toSet());
    });

    test('mode segment: autopilot rides the dedicated highlight role', () {
      final render = kStatusLineSegments['mode']!;
      final spec = _defaultSpec();
      final autopilot = render(
        const StatusLineSnapshot(
          cwd: '/',
          modelName: 'm',
          approvalMode: 'autopilot',
        ),
        spec,
      );
      expect(autopilot, isNotNull);
      expect(autopilot!.text, 'autopilot');
      expect(autopilot.spans.single, (
        'autopilot',
        StatusLineRoleKey.autopilot,
      ));

      // Every other approval mode keeps the quiet mode role, unchanged.
      final yolo = render(
        const StatusLineSnapshot(
          cwd: '/',
          modelName: 'm',
          approvalMode: 'yolo',
        ),
        spec,
      );
      expect(yolo!.spans.single, ('yolo', StatusLineRoleKey.mode));
    });

    test('mode segment: autopilot keeps the load-mode tail muted', () {
      final render = kStatusLineSegments['mode']!;
      final seg = render(
        const StatusLineSnapshot(
          cwd: '/',
          modelName: 'm',
          approvalMode: 'autopilot',
          agentLoadMode: 'omp',
        ),
        _defaultSpec(),
      );
      expect(seg!.spans, [
        ('autopilot', StatusLineRoleKey.autopilot),
        (' omp', StatusLineRoleKey.mode),
      ]);
    });

    test('autopilot highlight resolves to the accent and never idle-dims', () {
      final theme = TuiTheme.catppuccin;
      final accent = kStatusLineRoles[StatusLineRoleKey.autopilot]!(theme);
      expect(accent.foregroundRgb, theme.accent.foregroundRgb);
      // The highlight is the point (gh-946): it survives the idle dim that
      // quiets every other non-brand span.
      expect(
        identical(
          statusLineStyle(
            StatusLineRoleKey.autopilot,
            theme: theme,
            idle: true,
          ),
          accent,
        ),
        isTrue,
      );
    });

    test('registries are unmodifiable', () {
      expect(
        () => kStatusLineSegments['pi'] = _renderPiForTest,
        throwsUnsupportedError,
      );
      expect(
        () =>
            kStatusLineRoles[StatusLineRoleKey.dim] = (t) =>
                kStatusLineRoles[StatusLineRoleKey.name]!(t),
        throwsUnsupportedError,
      );
    });

    test('transparent drops the gap fill, keeps content', () {
      final spec = resolveStatusLineSpec(
        const StatusLineConfig(transparent: true),
      );
      // No context window -> the gap is pure dim fill; transparent
      // drops exactly that fill and keeps the content.
      final filled = renderStatusLine(_ladderSnapshot(), _defaultSpec(), 200);
      final clear = renderStatusLine(_ladderSnapshot(), spec, 200);
      // Same content, no band fill: the filled line is width-exact, the
      // transparent one lets the terminal bg show through.
      expect(tuiTextWidth(filled.single), 200);
      expect(clear.single, isNot(equals(filled.single)));
      expect(tuiTextWidth(clear.single), lessThan(200));
      expect(clear.single, contains('fixing-the-status-bar'));
      // With a gauge in the gap the gauge IS the fill: content only,
      // nothing for transparent to drop.
      final gaugeFilled = renderStatusLine(
        _richSnapshot(),
        _defaultSpec(),
        200,
      );
      final gaugeClear = renderStatusLine(_richSnapshot(), spec, 200);
      expect(gaugeClear.single, equals(gaugeFilled.single));
    });

    test('session renders the short id; session_name the title', () {
      const s = StatusLineSnapshot(cwd: '/', sessionId: 'abc123de');
      expect(
        kStatusLineSegments['session']!(s, _defaultSpec())!.text,
        'abc123de',
      );
      expect(
        kStatusLineSegments['session_name']!(s, _defaultSpec())!.text,
        'abc123de',
        reason: 'session_name falls back to the short id before new',
      );
      // The 'new' stand-in belongs to session_name alone (no id either).
      expect(
        kStatusLineSegments['session_name']!(
          const StatusLineSnapshot(cwd: '/'),
          _defaultSpec(),
        )!.text,
        'new',
      );

      const named = StatusLineSnapshot(
        cwd: '/',
        sessionId: 'abc123de',
        sessionName: 'fixing-the-status-bar',
      );
      // The nerd preset carries both ids - the name must render once.
      final nerd = resolveStatusLineSpec(
        const StatusLineConfig(preset: 'nerd'),
      );
      final line = renderStatusLineSpans(named, nerd, 90);
      final nameCount = line
          .where((span) => span.$1.contains('fixing-the-status-bar'))
          .length;
      expect(nameCount, 1);
      expect(line.map((s) => s.$1), contains('abc123de'));
    });

    test('session hides without an id (E7, no placeholder)', () {
      const s = StatusLineSnapshot(cwd: '/');
      expect(kStatusLineSegments['session']!(s, _defaultSpec()), isNull);
    });

    test('unknown id in a hand-built spec hides instead of crashing', () {
      const snapshot = StatusLineSnapshot(cwd: '/', modelName: 'm');
      final spec = resolveStatusLineSpec(
        const StatusLineConfig(left: ['bogus'], right: ['model']),
      );
      expect(() => renderStatusLine(snapshot, spec, 80), returnsNormally);
      final line = renderStatusLine(snapshot, spec, 80).single;
      expect(line, contains('m'));
    });

    test('brand fade snaps on degenerate frame tuning (no NaN)', () {
      expect(
        statusLineBrandFadeT(
          lit: true,
          changedAgoMs: 10,
          durationMs: 20,
          frameMs: 40,
        ),
        1.0,
      );
      expect(
        statusLineBrandFadeT(
          lit: false,
          changedAgoMs: 10,
          durationMs: 20,
          frameMs: 40,
        ),
        0.0,
      );
    });

    test('powerline end caps match omp (thin style: full-width caps)', () {
      final pw = getSeparator(StatusLineSeparatorStyle.powerline);
      expect(pw.capAfterLeft, pw.right);
      expect(pw.capBeforeRight, pw.left);
      final thin = getSeparator(StatusLineSeparatorStyle.powerlineThin);
      expect(thin.capAfterLeft, pw.right, reason: 'omp verbatim');
      expect(thin.capBeforeRight, pw.left);
      // Flat styles carry no band edges.
      for (final style in StatusLineSeparatorStyle.values) {
        if (style == StatusLineSeparatorStyle.powerline ||
            style == StatusLineSeparatorStyle.powerlineThin) {
          continue;
        }
        expect(
          getSeparator(style).capAfterLeft,
          isNull,
          reason: '$style has no band',
        );
      }
    });

    test('ignored (!) files never count as untracked', () {
      final git = parseGitStatusPorcelain(' M a\n?? b\n! c\n');
      expect(git.untracked, 1);
      expect(git.staged, 0);
      expect(git.unstaged, 1);
    });

    test('no-commits header is not adopted as a branch name', () {
      final git = parseGitStatusPorcelain(
        '## No commits yet on main\n?? new-file\n',
      );
      expect(git.branch, isNull);
      expect(git.untracked, 1);
    });
  });
}

/// The pi renderer reference for the unmodifiable-registry probe above.
LaidSegment? _renderPiForTest(StatusLineSnapshot s, StatusLineSpec spec) =>
    kStatusLineSegments['pi']!(s, spec);

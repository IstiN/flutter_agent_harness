/// herdr detection-manifest contract (issue #818).
///
/// herdr (github.com/herdrdev/herdr) classifies fa panes from the pane
/// screen via `docs/integrations/herdr/fa.toml` — the canonical fa-side
/// source of the upstream `src/detect/manifests/fa.toml`. This test:
///
/// 1. parses the manifest with a transliteration of herdr's engine
///    (`src/detect/manifest.rs` — regions, gate matching, priority
///    arbitration, the known-agent idle fallback),
/// 2. classifies the committed fixture transcripts (real prompt-sheet
///    bytes from `renderTuiPrompt`; busy/gutter/footer screens shaped by
///    `_busyRowLine` / `_writeBusyAndQueue` / `_statusLine`), and
/// 3. re-renders the sheet fixtures live, so a chrome change that would
///    break herdr classification fails here before the upstream manifest
///    ships.
///
/// No herdr binary involved — the manifest rules are data.
@TestOn('vm')
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_agent_harness/src/approval/approval.dart';
import 'package:flutter_agent_harness/src/cli/tui_prompt.dart';
import 'package:flutter_agent_harness/src/tools/ask_tool.dart';
import 'package:test/test.dart';

final _repoRoot = Directory.current.path;
final _manifestPath = '$_repoRoot/docs/integrations/herdr/fa.toml';
final _fixturesDir = '$_repoRoot/docs/integrations/herdr/fixtures';

// ---------------------------------------------------------------------------
// Minimal TOML reader for the manifest subset fa.toml uses. Anything else
// throws — the parser grows only when the manifest legitimately grows.
// ---------------------------------------------------------------------------

List<String> _stringList(String raw) => RegExp(
  r'''['"]([^'"]*)['"]''',
).allMatches(raw).map((m) => m.group(1)!).toList();

/// Merges physical lines into logical TOML lines: comments are stripped
/// per line (never inside quotes) and multi-line arrays join until their
/// brackets balance.
List<String> _logicalLines(String text) {
  String stripComment(String line) {
    var inQuote = false;
    for (var i = 0; i < line.length; i++) {
      if (line[i] == "'") inQuote = !inQuote;
      if (line[i] == '#' && !inQuote) return line.substring(0, i);
    }
    return line;
  }

  final out = <String>[];
  var depth = 0;
  var current = '';
  for (final physical in text.replaceAll('\r\n', '\n').split('\n')) {
    final line = stripComment(physical);
    for (final ch in line.split('')) {
      if (ch == '[' || ch == '{') depth++;
      if (ch == ']' || ch == '}') depth--;
      current += ch;
    }
    if (depth > 0) {
      current += ' ';
      continue;
    }
    if (current.trim().isNotEmpty) out.add(current.trim());
    current = '';
  }
  if (current.trim().isNotEmpty) out.add(current.trim());
  return out;
}

class _Gate {
  const _Gate(
    this.contains,
    this.regex,
    this.lineRegex,
    this.all,
    this.any,
    this.not,
  );

  /// `{ key = [values] }` — a single-key inline gate table.
  factory _Gate.inline(String raw) {
    final m = RegExp(r'^\{ (\w+) = \[(.*)\] \}$').firstMatch(raw.trim());
    if (m == null) throw FormatException('unsupported gate shape: $raw');
    final values = _stringList(m.group(2)!);
    if (values.isEmpty) {
      // herdr's validate_gate rejects matcher-less gates — an empty gate
      // would match vacuously and silently poison `any`/`not`.
      throw FormatException('empty gate (quote-style parse bug?): $raw');
    }
    return switch (m.group(1)) {
      'contains' => _Gate(
        values,
        const [],
        const [],
        const [],
        const [],
        const [],
      ),
      'regex' => _Gate(
        const [],
        values,
        const [],
        const [],
        const [],
        const [],
      ),
      'line_regex' => _Gate(
        const [],
        const [],
        values,
        const [],
        const [],
        const [],
      ),
      final key => throw FormatException('unsupported gate key: $key'),
    };
  }

  final List<String> contains;
  final List<String> regex;
  final List<String> lineRegex;
  final List<_Gate> all;
  final List<_Gate> any;
  final List<_Gate> not;

  bool get hasPositiveMatcher =>
      contains.isNotEmpty ||
      regex.isNotEmpty ||
      lineRegex.isNotEmpty ||
      all.isNotEmpty ||
      any.isNotEmpty;

  /// herdr's `compiled_gate_matches`: contains is case-insensitive
  /// (needles and haystack lowercased), regex spans the whole region,
  /// line_regex hits when ANY single line matches; `all`/`any` recurse and
  /// every `not` gate must stay unmatched.
  bool matches(String text) {
    final lower = text.toLowerCase();
    if (!contains.every((needle) => lower.contains(needle.toLowerCase()))) {
      return false;
    }
    if (!regex.every((pattern) => RegExp(pattern).hasMatch(text))) {
      return false;
    }
    if (!lineRegex.every(
      (pattern) =>
          text.split('\n').any((line) => RegExp(pattern).hasMatch(line)),
    )) {
      return false;
    }
    if (!all.every((gate) => gate.matches(text))) return false;
    if (any.isNotEmpty && !any.any((gate) => gate.matches(text))) {
      return false;
    }
    if (not.any((gate) => gate.matches(text))) return false;
    return true;
  }
}

class _Rule {
  const _Rule({
    required this.id,
    required this.state,
    required this.priority,
    required this.region,
    required this.visibleIdle,
    required this.visibleBlocker,
    required this.visibleWorking,
    required this.gate,
  });

  final String id;
  final String state;
  final int priority;
  final String region;
  final bool visibleIdle;
  final bool visibleBlocker;
  final bool visibleWorking;
  final _Gate gate;
}

class _Manifest {
  _Manifest(this.id, this.minEngineVersion, this.aliases, this.rules);

  final String id;
  final int minEngineVersion;
  final List<String> aliases;
  final List<_Rule> rules;
}

_Manifest _parseFaManifest(String text) {
  String? id;
  var minEngineVersion = 1;
  var aliases = <String>[];
  final rules = <_Rule>[];

  var inRules = false;
  String? rId;
  String? rState;
  var rPriority = 0;
  var rRegion = 'whole_recent';
  var rVisibleIdle = false;
  var rVisibleBlocker = false;
  var rVisibleWorking = false;
  var rContains = <String>[];
  var rLineRegex = <String>[];
  var rAny = <_Gate>[];
  var rNot = <_Gate>[];

  void flushRule() {
    if (rId == null) return;
    rules.add(
      _Rule(
        id: rId!,
        state: rState ?? 'unknown',
        priority: rPriority,
        region: rRegion,
        visibleIdle: rVisibleIdle,
        visibleBlocker: rVisibleBlocker,
        visibleWorking: rVisibleWorking,
        gate: _Gate(rContains, const [], rLineRegex, const [], rAny, rNot),
      ),
    );
    rId = rState = null;
    rPriority = 0;
    rRegion = 'whole_recent';
    rVisibleIdle = rVisibleBlocker = rVisibleWorking = false;
    rContains = rLineRegex = const [];
    rAny = rNot = const [];
  }

  for (final line in _logicalLines(text)) {
    if (line == '[[rules]]') {
      flushRule();
      inRules = true;
      continue;
    }
    final scalar = RegExp(r'^(\w+) = "(.*)"$').firstMatch(line);
    if (scalar != null) {
      final (key, value) = (scalar.group(1)!, scalar.group(2)!);
      if (!inRules) {
        if (key == 'id') id = value;
        continue;
      }
      switch (key) {
        case 'id':
          rId = value;
        case 'state':
          rState = value;
        case 'region':
          rRegion = value;
      }
      continue;
    }
    final intScalar = RegExp(r'^(\w+) = (\d+)$').firstMatch(line);
    if (intScalar != null) {
      final (key, value) = (intScalar.group(1)!, intScalar.group(2)!);
      if (key == 'min_engine_version') {
        minEngineVersion = int.parse(value);
      } else if (inRules && key == 'priority') {
        rPriority = int.parse(value);
      }
      continue;
    }
    final array = RegExp(r'^(\w+) = \[(.*)\]$').firstMatch(line);
    if (array != null) {
      final (key, raw) = (array.group(1)!, array.group(2)!);
      if (!inRules) {
        if (key == 'aliases') aliases = _stringList(raw);
        continue;
      }
      switch (key) {
        case 'contains':
          rContains = _stringList(raw);
        case 'line_regex':
          rLineRegex = _stringList(raw);
        case 'all':
        case 'any':
          final gates = RegExp(
            r'\{[^{}]*\}',
          ).allMatches(raw).map((m) => _Gate.inline(m.group(0)!)).toList();
          if (key == 'any') {
            rAny = gates;
          } else {
            // `all` gates land in the line-regex path in fa.toml; a real
            // nested `all` would need parser growth — fail loudly instead.
            throw FormatException('fa.toml does not use all gates: $line');
          }
        case 'not':
          rNot = RegExp(
            r'\{[^{}]*\}',
          ).allMatches(raw).map((m) => _Gate.inline(m.group(0)!)).toList();
      }
      continue;
    }
    if (inRules && RegExp(r'^visible_\w+ = true$').hasMatch(line)) {
      if (line.startsWith('visible_idle')) rVisibleIdle = true;
      if (line.startsWith('visible_blocker')) rVisibleBlocker = true;
      if (line.startsWith('visible_working')) rVisibleWorking = true;
      continue;
    }
    if (!inRules) continue; // updated_at / version — not asserted on
    throw FormatException('unsupported manifest line: $line');
  }
  flushRule();
  if (id == null) throw FormatException('manifest id missing');
  return _Manifest(id, minEngineVersion, aliases, rules);
}

// ---------------------------------------------------------------------------
// herdr's engine, transliterated (src/detect/manifest.rs).
// ---------------------------------------------------------------------------

/// `bottom_non_empty_lines(n)`: from the n-th non-empty line counting from
/// the bottom to the end of the content (short buffers clamp at the
/// bottom-most non-empty line).
String bottomNonEmptyLines(String screen, int n) {
  final lines = screen.split('\n');
  final nonEmptyFromBottom = <int>[
    for (var i = lines.length - 1; i >= 0; i--)
      if (lines[i].trim().isNotEmpty) i,
  ];
  if (nonEmptyFromBottom.isEmpty) return '';
  final start =
      nonEmptyFromBottom[n <= nonEmptyFromBottom.length
          ? n - 1
          : nonEmptyFromBottom.length - 1];
  return lines.sublist(start).join('\n');
}

String _region(String screen, String spec) {
  if (spec == 'whole_recent') return screen;
  final count = RegExp(r'^bottom_non_empty_lines\((\d+)\)$').firstMatch(spec);
  if (count != null) {
    return bottomNonEmptyLines(screen, int.parse(count.group(1)!));
  }
  throw FormatException('region not exercised by fa.toml: $spec');
}

/// herdr's arbitration: rules evaluate in declaration order, a matching
/// rule replaces the current best only on STRICTLY higher priority (ties
/// keep the earlier rule), and a known agent with no match falls back to
/// idle — `default_known_agent_idle_fallback`.
String _classifyFaScreen(_Manifest manifest, String screen) {
  _Rule? best;
  for (final rule in manifest.rules) {
    if (!rule.gate.matches(_region(screen, rule.region))) continue;
    if (best == null || rule.priority > best.priority) best = rule;
  }
  return best?.state ?? 'idle';
}

// ---------------------------------------------------------------------------
// Fixture regeneration: the committed sheet fixtures are REAL renderer
// bytes, ANSI-stripped (herdr's engine reads the post-emulation screen).
// ---------------------------------------------------------------------------

String _stripAnsi(String text) =>
    text.replaceAll(RegExp(r'\x1b\[[0-9;]*[a-zA-Z]'), '');

String _sheet(TuiPromptSpec spec) => _stripAnsi(
  renderTuiPrompt(TuiPromptState(spec), 80).join('\n'),
).trimRight();

String renderApprovalFixture() {
  const request = ApprovalRequest(
    toolName: 'bash',
    tier: ApprovalTier.exec,
    arguments: {'command': 'rm -rf ./build'},
    reason: 'exec tier requires approval in mode: code',
  );
  return '⠋ Working…      3s\n${_sheet(ApprovalPromptSpec(request: request))}\n';
}

String renderSecretFixture() {
  const spec = SecretPromptSpec(
    name: 'SERPAPI_KEY',
    reason: 'the web_search tool needs a SerpApi key',
  );
  return '⠋ Working…      3s\n${_sheet(spec)}\n';
}

String renderAskFixture() {
  const spec = AskPromptSpec(
    header: 'Ask',
    question: 'Which database should the migration target?',
    index: 0,
    total: 1,
    options: [
      AskOption(label: 'Postgres', description: 'keeps the current host'),
      AskOption(label: 'SQLite'),
    ],
    recommended: 0,
  );
  return '⠋ Working…      3s\n${_sheet(spec)}\n';
}

void main() {
  final manifest = _parseFaManifest(File(_manifestPath).readAsStringSync());

  test('manifest shape matches what herdr bundles', () {
    expect(manifest.id, 'fa');
    expect(manifest.aliases, contains('herdr:fa'));
    // Engine 2 (any/not gates); never above what current herdr bundles.
    expect(manifest.minEngineVersion, lessThanOrEqualTo(2));
    expect(
      manifest.rules.map((r) => r.id),
      containsAll(<String>[
        'approval_sheet',
        'secret_sheet',
        'busy_row',
        'composer_gutter',
      ]),
    );
    for (final rule in manifest.rules) {
      expect(rule.state, isIn(['working', 'blocked', 'idle', 'unknown']));
      expect(rule.gate.hasPositiveMatcher, isTrue, reason: rule.id);
    }
  });

  test('every committed fixture classifies to its state', () {
    final expected = {
      'working.txt': 'working',
      'working-classic.txt': 'working',
      'idle.txt': 'idle',
      'idle-classic.txt': 'idle',
      'blocked-approval.txt': 'blocked',
      'blocked-secret.txt': 'blocked',
      'blocked-ask.txt': 'blocked',
    };
    expected.forEach((name, state) {
      final screen = File('$_fixturesDir/$name').readAsStringSync();
      expect(
        _classifyFaScreen(manifest, screen),
        state,
        reason: '$name misclassified',
      );
    });
  });

  test('prompt-sheet fixtures match the live renderer bytes', () {
    final live = {
      'blocked-approval.txt': renderApprovalFixture(),
      'blocked-secret.txt': renderSecretFixture(),
      'blocked-ask.txt': renderAskFixture(),
    };
    live.forEach((name, rendered) {
      final committed = File('$_fixturesDir/$name').readAsStringSync();
      expect(committed, rendered, reason: '$name drifted from the renderer');
    });
  });

  test(
    'arbitration: live signals beat idle cues, transcript quotes stay idle',
    () {
      // The gutter stays painted while the busy row spins — the working
      // rules must win anyway (the not-gate suppression).
      final busyWithGutter = File(
        '$_fixturesDir/working.txt',
      ).readAsStringSync();
      expect(_classifyFaScreen(manifest, busyWithGutter), 'working');

      // A transcript that merely quotes `Working…` cannot outvote the resting
      // gutter (150 > 100).
      expect(
        _classifyFaScreen(
          manifest,
          'the log said Working… and moved on\n╰─ \n',
        ),
        'idle',
      );

      // No rule matches a known agent: herdr's idle fallback.
      expect(_classifyFaScreen(manifest, 'random shell output\n'), 'idle');

      // The open host picker replaces the busy row and blocks the pane.
      expect(
        _classifyFaScreen(
          manifest,
          '${'─' * 80}\nwaiting for your selection…\n╰─ \n',
        ),
        'blocked',
      );

      // A quoted sheet scrolled out of the bottom-24 region (24+ non-empty
      // rows below it) does not block a live run.
      final filler = List.generate(40, (i) => 'transcript line $i').join('\n');
      final fillerAfter = List.generate(25, (i) => 'newer line $i').join('\n');
      expect(
        _classifyFaScreen(
          manifest,
          '$filler\n┌─ Approval ───┐\n│ Approve once (y) │\n'
          '$fillerAfter\n⠙ Working…      5s\n╰─ \n',
        ),
        'working',
      );
    },
  );
}

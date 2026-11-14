// gh-2181 — AGENTS.md size ceiling guard.
//
// AGENTS.md is the agent ENTRY document: the harness carries it into the
// system prompt with a ~19 KB entry budget, so everything past the budget
// is invisible to agents in practice (gh-2181 measured 146405 B / 2201
// lines — ~75% of the file silently disabled). The slimmed file must STAY
// slim: <= 300 lines AND <= 20480 bytes (20 KB), enforced by
// scripts/check_agents_md_size.sh wired into BOTH gate paths:
//   - scripts/ci_fast_gate.sh stage_analyze (runs for docs/*.md commits —
//     the pre-commit hook is a thin wrapper over the same script);
//   - .github/workflows/ci.yml `static` job (whole-tree, every validation).
//
// Cap semantics: <= (at-cap passes) — the ticket ceiling is "≤ 300 lines
// and ≤ 20 KB". This differs from scripts/check_changelog_size.sh whose
// pub.dev cap is a strict less-than; do not copy its comparison.
import 'dart:io';

import 'package:test/test.dart';

const maxLines = 300;
const maxBytes = 20480;

final _tmpRoot = Directory.systemTemp.createTempSync('agents-md-size-');

int _run(List<String> args, String cwd) => Process.runSync('bash', <String>[
  File('scripts/check_agents_md_size.sh').absolute.path,
  ...args,
], workingDirectory: cwd).exitCode;

ProcessResult _runOut(List<String> args, String cwd) => Process.runSync(
  'bash',
  <String>[File('scripts/check_agents_md_size.sh').absolute.path, ...args],
  workingDirectory: cwd,
);

String _fixture(String name) {
  final dir = Directory('${_tmpRoot.path}/$name')..createSync(recursive: true);
  return dir.path;
}

void main() {
  test('shebang + executable bit (guard runs from hook and CI)', () {
    final f = File('scripts/check_agents_md_size.sh');
    expect(f.existsSync(), isTrue, reason: 'the guard script must exist');
    expect(
      f.readAsStringSync().startsWith('#!'),
      isTrue,
      reason: 'guard script must start with a shebang',
    );
    expect(
      f.statSync().modeString().substring(0, 3),
      contains('x'),
      reason: 'guard script must be executable (hook/CI call it directly)',
    );
  });

  test('under both caps passes (exit 0)', () {
    final dir = _fixture('under');
    File('$dir/AGENTS.md').writeAsStringSync('# small\n\nclean\n');
    expect(_run(const [], dir), 0);
  });

  test('exactly at both caps passes (ceiling is <=)', () {
    final dir = _fixture('at-cap');
    File(
      '$dir/AGENTS.md',
    ).writeAsStringSync('${List.filled(maxLines, 'x').join('\n')}\n');
    final r = _runOut(['AGENTS.md', '$maxLines', '$maxBytes'], dir);
    expect(r.exitCode, 0, reason: 'at-cap must pass: ${r.stdout}');
  });

  test('over the line cap fails naming the limits and the fix', () {
    final dir = _fixture('over-lines');
    File(
      '$dir/AGENTS.md',
    ).writeAsStringSync('${List.filled(maxLines + 1, 'x').join('\n')}\n');
    final r = _runOut(['AGENTS.md', '$maxLines', '$maxBytes'], dir);
    expect(r.exitCode, 1);
    expect(r.stdout, contains('::error::'));
    expect(r.stdout, contains('${maxLines + 1} lines'));
    expect(r.stdout, contains('$maxLines'));
    expect(r.stdout, contains('docs/'));
  });

  test('over the byte cap fails naming the limits and the fix', () {
    final dir = _fixture('over-bytes');
    File('$dir/AGENTS.md').writeAsStringSync('x' * (maxBytes + 1));
    final r = _runOut(['AGENTS.md', '$maxLines', '$maxBytes'], dir);
    expect(r.exitCode, 1);
    expect(r.stdout, contains('::error::'));
    expect(r.stdout, contains('${maxBytes + 1} bytes'));
    expect(r.stdout, contains('20480'));
  });

  test('defaults are AGENTS.md / 300 lines / 20480 bytes', () {
    final dir = _fixture('defaults');
    Directory('$dir/docs').createSync();
    File(
      '$dir/AGENTS.md',
    ).writeAsStringSync('${List.filled(301, 'x').join('\n')}\n');
    expect(_run(const [], dir), 1);
  });

  test('missing AGENTS.md fails loudly', () {
    final dir = _fixture('missing');
    expect(_run(const [], dir), 1);
  });

  test('repo AGENTS.md is within the ceiling (gh-2181 slim landed)', () {
    final f = File('AGENTS.md');
    expect(f.existsSync(), isTrue);
    final bytes = f.lengthSync();
    final lines = f.readAsLinesSync().length;
    expect(
      bytes,
      lessThanOrEqualTo(maxBytes),
      reason:
          'AGENTS.md regrew to $bytes bytes — the agent entry budget is '
          '~19 KB, so the tail is invisible to agents again (gh-2181). '
          'Move essays to docs/ (index: docs/README.md).',
    );
    expect(
      lines,
      lessThanOrEqualTo(maxLines),
      reason:
          'AGENTS.md regrew to $lines lines — ceiling is $maxLines '
          '(gh-2181). Move essays to docs/ (index: docs/README.md).',
    );
  });

  test(
    'wiring: ci_fast_gate.sh analyze stage runs the guard (docs-only commits pay it)',
    () {
      final gate = File('scripts/ci_fast_gate.sh').readAsStringSync();
      final analyze = gate.indexOf('stage_analyze()');
      expect(analyze, greaterThan(0), reason: 'fixture: analyze stage exists');
      final call = gate.indexOf('check_agents_md_size.sh', analyze);
      expect(
        call,
        greaterThan(analyze),
        reason:
            'the guard must run inside the analyze stage — AGENTS.md '
            'edits classify as docs, whose only fast-gate stage IS '
            'analyze; a check living in a lib-only stage would never '
            'fire on the exact commit that regrows the file',
      );
    },
  );

  test('wiring: ci.yml static job runs the guard whole-tree', () {
    final ci = File('.github/workflows/ci.yml').readAsStringSync();
    final staticJob = ci.indexOf('  static:');
    expect(staticJob, greaterThan(0), reason: 'fixture: static job exists');
    expect(
      ci.indexOf('check_agents_md_size.sh', staticJob),
      greaterThan(staticJob),
      reason:
          'the Static gates job must invoke the guard — CI is the '
          'authority when hooks are skipped (--no-verify)',
    );
  });
}

import 'dart:io';

import 'package:flutter_agent_harness/src/cli/cli_args.dart';
import 'package:test/test.dart';

/// Parse-level tests for `fa import` (issue #1562): strict operand
/// handling (GOAL F7), the selector rule, harness names, and the REG-3
/// help guard.
void main() {
  CliArgs parse(List<String> args) {
    final result = parseCliArgs(['import', ...args]);
    if (result is! CliArgs) throw StateError('expected CliArgs, got $result');
    return result;
  }

  test('the canonical forms parse', () {
    final all = parse(['--harness=omp', '--all']);
    expect(all.importCmd?.harness, 'omp');
    expect(all.importCmd?.all, isTrue);
    expect(all.importCmd?.session, isNull);

    final spaced = parse(['--harness', 'claude', '--session', 'abc123']);
    expect(spaced.importCmd?.harness, 'claude');
    expect(spaced.importCmd?.all, isFalse);
    expect(spaced.importCmd?.session, 'abc123');

    final rooted = parse([
      '--harness=omp',
      '--all',
      '--session-root',
      '/tmp/store',
      '--cwd=/work',
    ]);
    expect(rooted.sessionRoot, '/tmp/store');
    expect(rooted.cwd, '/work');
  });

  test('an id-prefix selector rides --session', () {
    final result = parse(['--harness=omp', '--session=1f9d2a6']);
    expect(result.importCmd?.session, '1f9d2a6');
  });

  test('missing / conflicting selectors are usage errors (exit 1 class)', () {
    expect(() => parse(['--harness=omp']), throwsA(isA<CliArgsException>()));
    expect(
      () => parse(['--harness=omp', '--all', '--session=x']),
      throwsA(isA<CliArgsException>()),
    );
    expect(() => parse(['--all']), throwsA(isA<CliArgsException>()));
    expect(() => parse([]), throwsA(isA<CliArgsException>()));
  });

  test('an empty --session value is a usage error, not a wildcard (F7)', () {
    expect(
      () => parse(['--harness=omp', '--session=']),
      throwsA(
        isA<CliArgsException>().having(
          (e) => e.message,
          'message',
          contains('non-empty id or prefix'),
        ),
      ),
    );
    expect(
      () => parse(['--harness=omp', '--session', '   ']),
      throwsA(isA<CliArgsException>()),
    );
  });

  test('unknown harness names are usage errors', () {
    expect(
      () => parse(['--harness=pi', '--all']),
      throwsA(
        isA<CliArgsException>().having(
          (e) => e.message,
          'message',
          contains('unknown harness: pi'),
        ),
      ),
    );
    expect(() => parse(['--all']), throwsA(isA<CliArgsException>()));
  });

  test('unknown flags are usage errors — never a prompt (F7)', () {
    expect(
      () => parse(['--harness=omp', '--all', '--dry-run']),
      throwsA(
        isA<CliArgsException>().having(
          (e) => e.message,
          'message',
          contains('unknown argument: --dry-run'),
        ),
      ),
    );
  });

  test('--help routes to the help result', () {
    expect(parseCliArgs(['import', '--help']), isA<CliArgsHelp>());
    expect(parseCliArgs(['import', '-h']), isA<CliArgsHelp>());
  });

  test('REG-3: the subcommand table and the cli help cover fa import', () {
    // The dispatch table is private; its registration is proven by the
    // parse tests above — this pins the HELP half: the QUICK COMMANDS
    // section must document the subcommand with its surface.
    final help = File('lib/src/cli/cli_help.dart').readAsStringSync();
    expect(help, contains('fa import --harness=<omp|kimi|opencode|'));
    expect(help, contains('  import                       fa import'));
  });
}

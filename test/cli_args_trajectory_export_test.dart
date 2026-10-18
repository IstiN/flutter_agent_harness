// `fa trajectory export` argument parsing (gh-1681 Gap 2): the ATIF
// export verb, its `--format`/`--output` flags, and the typo guards that
// keep unknown formats/flags from ever becoming a prompt.
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('fa trajectory export parsing', () {
    test('export is a recognized verb', () {
      final args = parseCliArgs(['trajectory', 'export']) as CliArgs;
      expect(args.trajectory!.verb, 'export');
      expect(args.trajectory!.format, 'atif');
      expect(args.trajectory!.output, isNull);
      expect(args.trajectory!.positionals, isEmpty);
    });

    test('session id, --format, and --output parse positionally', () {
      final args = parseCliArgs([
        'trajectory',
        'export',
        'sess-1',
        '--format',
        'atif',
        '--output',
        '/logs/agent/trajectory.json',
      ]) as CliArgs;
      expect(args.trajectory!.verb, 'export');
      expect(args.trajectory!.positionals, ['sess-1']);
      expect(args.trajectory!.format, 'atif');
      expect(args.trajectory!.output, '/logs/agent/trajectory.json');
    });

    test('--session-root still parses after the verb', () {
      final args = parseCliArgs([
        'trajectory',
        'export',
        '--session-root',
        '/logs/agent/fah-sessions',
        '--output',
        '/tmp/t.json',
      ]) as CliArgs;
      expect(args.sessionRoot, '/logs/agent/fah-sessions');
      expect(args.trajectory!.output, '/tmp/t.json');
    });

    test('an unknown format fails fast with a usage error', () {
      expect(
        () => parseCliArgs(['trajectory', 'export', '--format', 'jsonl']),
        throwsA(
          isA<CliArgsException>().having(
            (e) => e.message,
            'message',
            contains('unsupported trajectory export format'),
          ),
        ),
      );
    });

    test('--format and --output are export-only flags', () {
      expect(
        () => parseCliArgs(['trajectory', 'view', '--output', '/tmp/x']),
        throwsA(isA<CliArgsException>()),
      );
      expect(
        () => parseCliArgs(['trajectory', 'cost', '--format', 'atif']),
        throwsA(isA<CliArgsException>()),
      );
    });

    test('export rejects --at and --json', () {
      expect(
        () => parseCliArgs(['trajectory', 'export', '--at', '3']),
        throwsA(isA<CliArgsException>()),
      );
      expect(
        () => parseCliArgs(['trajectory', 'export', '--json']),
        throwsA(isA<CliArgsException>()),
      );
    });

    test('unknown verbs still fail fast', () {
      expect(
        () => parseCliArgs(['trajectory', 'exportx']),
        throwsA(isA<CliArgsException>()),
      );
    });
  });
}

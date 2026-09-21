import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Issue #695: `--output-format text|stream-json` and the `--mode json`
/// alias (pi `--mode json` parity) for headless runs.
void main() {
  group('--output-format', () {
    test('stream-json parses on every headless entry point', () {
      for (final args in [
        ['--output-format', 'stream-json', '-p', 'hi'],
        ['--output-format', 'stream-json', '--prompt', 'hi'],
        ['--output-format', 'stream-json', '--prompt-file', 'p.md'],
        ['--output-format', 'stream-json', 'hi'],
      ]) {
        final parsed = parseCliArgs(args) as CliArgs;
        expect(parsed.outputFormat, 'stream-json', reason: '$args');
      }
    });

    test('text is accepted and is the default (null)', () {
      expect(
        (parseCliArgs(['--output-format', 'text', '-p', 'hi']) as CliArgs)
            .outputFormat,
        'text',
      );
      expect((parseCliArgs(['-p', 'hi']) as CliArgs).outputFormat, isNull);
    });

    test('unknown format is a usage error naming the flag', () {
      expect(
        () => parseCliArgs(['--output-format', 'xml', '-p', 'hi']),
        throwsA(
          isA<CliArgsException>().having(
            (e) => e.message,
            'message',
            allOf(contains('--output-format'), contains('stream-json')),
          ),
        ),
      );
    });

    test('stream-json requires a headless prompt', () {
      expect(
        () => parseCliArgs(['--output-format', 'stream-json']),
        throwsA(
          isA<CliArgsException>().having(
            (e) => e.message,
            'message',
            contains('headless'),
          ),
        ),
      );
    });

    test('cannot combine with --output events (two stdout owners)', () {
      expect(
        () => parseCliArgs([
          '--output',
          'events',
          '--output-format',
          'stream-json',
          '-p',
          'hi',
        ]),
        throwsA(isA<CliArgsException>()),
      );
    });

    test('text format without a prompt is fine (no-op)', () {
      expect(
        (parseCliArgs(['--output-format', 'text']) as CliArgs).outputFormat,
        'text',
      );
    });
  });

  group('--mode json alias', () {
    test('is an exact alias for --output-format stream-json', () {
      final parsed = parseCliArgs(['--mode', 'json', '-p', 'hi']) as CliArgs;
      expect(parsed.outputFormat, 'stream-json');
    });

    test('does not change the agent mode', () {
      final parsed = parseCliArgs(['--mode', 'json', '-p', 'hi']) as CliArgs;
      expect(
        parsed.mode,
        isNull,
        reason: 'json is an output-format alias, not an agent mode',
      );
    });

    test('agent modes still parse', () {
      for (final mode in ['code', 'architect', 'review']) {
        final parsed = parseCliArgs(['--mode', mode, '-p', 'hi']) as CliArgs;
        expect(parsed.mode, mode);
        expect(parsed.outputFormat, isNull);
      }
    });

    test('last declaration wins per concern', () {
      final both =
          parseCliArgs(['--mode', 'json', '--mode', 'code', '-p', 'hi'])
              as CliArgs;
      expect(both.mode, 'code');
      expect(both.outputFormat, 'stream-json');
    });

    test('--mode json without a prompt is a usage error', () {
      expect(
        () => parseCliArgs(['--mode', 'json']),
        throwsA(isA<CliArgsException>()),
      );
    });
  });
}

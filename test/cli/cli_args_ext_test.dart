import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Tests for the `fa ext <verb>` argument family: interception, verbs,
/// flags, and usage errors (mirrors the trajectory family tests).
void main() {
  ExtCliCommand parse(List<String> args) =>
      (parseCliArgs(args) as CliArgs).ext!;

  group('fa ext parsing', () {
    test('bare ext is a usage error listing the verbs', () {
      expect(
        () => parseCliArgs(['ext']),
        throwsA(
          isA<CliArgsException>().having(
            (e) => e.message,
            'message',
            contains('list|install|remove|update|audit|enable|disable'),
          ),
        ),
      );
    });

    test('--help inside the family wins', () {
      expect(parseCliArgs(['ext', '--help']), isA<CliArgsHelp>());
      expect(parseCliArgs(['ext', 'list', '-h']), isA<CliArgsHelp>());
    });

    test('unknown verb is a usage error', () {
      expect(
        () => parseCliArgs(['ext', 'repl']),
        throwsA(
          isA<CliArgsException>().having(
            (e) => e.message,
            'message',
            allOf(contains('unknown ext verb: repl'), contains('install')),
          ),
        ),
      );
    });

    test('list with --json', () {
      final cmd = parse(['ext', 'list', '--json']);
      expect(cmd.verb, 'list');
      expect(cmd.json, isTrue);
      expect(cmd.sources, isEmpty);
    });

    test('install parses sources and install-only flags', () {
      final cmd = parse([
        'ext',
        'install',
        './a',
        'gh:o/r',
        '--pin',
        'abc',
        '--trust',
        '--strict',
      ]);
      expect(cmd.verb, 'install');
      expect(cmd.sources, ['./a', 'gh:o/r']);
      expect(cmd.pin, 'abc');
      expect(cmd.trust, isTrue);
      expect(cmd.strict, isTrue);
      expect(cmd.bundled, isFalse);
    });

    test('--bundled alone means all bundled', () {
      final cmd = parse(['ext', 'install', '--bundled']);
      expect(cmd.bundled, isTrue);
      expect(cmd.bundledName, isNull);
    });

    test('--bundled takes an optional name', () {
      final cmd = parse(['ext', 'install', '--bundled', 'crap-guard']);
      expect(cmd.bundled, isTrue);
      expect(cmd.bundledName, 'crap-guard');
      // A following flag is NOT consumed as the name.
      final mixed = parse(['ext', 'install', '--bundled', '--trust']);
      expect(mixed.bundledName, isNull);
      expect(mixed.trust, isTrue);
    });

    test('install without a source or --bundled is a usage error', () {
      expect(
        () => parseCliArgs(['ext', 'install']),
        throwsA(isA<CliArgsException>()),
      );
      expect(
        () => parseCliArgs(['ext', 'install', '--pin', 'abc']),
        throwsA(isA<CliArgsException>()),
      );
    });

    test('--pin requires a value', () {
      expect(
        () => parseCliArgs(['ext', 'install', '--pin']),
        throwsA(
          isA<CliArgsException>().having(
            (e) => e.message,
            'message',
            contains('--pin requires a sha256 value'),
          ),
        ),
      );
    });

    test('install-only flags are rejected on other verbs', () {
      for (final args in [
        ['ext', 'list', '--pin', 'abc'],
        ['ext', 'remove', 'x', '--trust'],
        ['ext', 'update', '--bundled'],
        ['ext', 'audit', '--strict'],
      ]) {
        expect(
          () => parseCliArgs(args),
          throwsA(
            isA<CliArgsException>().having(
              (e) => e.message,
              'message',
              contains('only applies to fa ext install'),
            ),
          ),
          reason: args.join(' '),
        );
      }
    });

    test('remove/enable/disable need exactly one name', () {
      expect(parse(['ext', 'remove', 'demo']).name, 'demo');
      expect(parse(['ext', 'disable', 'demo']).name, 'demo');
      expect(
        () => parseCliArgs(['ext', 'remove']),
        throwsA(isA<CliArgsException>()),
      );
      expect(
        () => parseCliArgs(['ext', 'enable', 'a', 'b']),
        throwsA(isA<CliArgsException>()),
      );
    });

    test('update/audit take an optional single name', () {
      expect(parse(['ext', 'update']).name, isNull);
      expect(parse(['ext', 'update', 'demo']).name, 'demo');
      expect(parse(['ext', 'audit', 'demo']).name, 'demo');
      expect(
        () => parseCliArgs(['ext', 'update', 'a', 'b']),
        throwsA(isA<CliArgsException>()),
      );
    });

    test('list takes no operands', () {
      expect(
        () => parseCliArgs(['ext', 'list', 'extra']),
        throwsA(isA<CliArgsException>()),
      );
    });

    test('unknown flag is an error', () {
      expect(
        () => parseCliArgs(['ext', 'list', '--wat']),
        throwsA(
          isA<CliArgsException>().having(
            (e) => e.message,
            'message',
            contains('unknown argument: --wat'),
          ),
        ),
      );
    });

    test('ext does not leak into prompt parsing and vice versa', () {
      expect(parse(['ext', 'list']).verb, 'list');
      final promptArgs = parseCliArgs(['hello', 'world']) as CliArgs;
      expect(promptArgs.ext, isNull);
      expect(promptArgs.positionals, ['hello', 'world']);
    });
  });
}

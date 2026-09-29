@Tags(['integration'])
// The ratchet leg's coverage source (scripts/check_cli_coverage.py measures
// lib/src/cli/** from the integration-tagged PTY shards): the jsr parser
// lives in lib/src/cli/cli_args.dart, so these tests MUST carry the tag —
// gh-1033 review thread 7 (coverage ratchet dilution).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Tests for the `fa jsr <verb>` argument family (gh-1033): interception,
/// the two widget verbs, and VERBATIM passthrough of everything after the
/// verb — the flag surface is owned by the jsr CLI, not by fah (invariant
/// I1: zero widget logic in the harness).
void main() {
  JsrCliCommand parse(List<String> args) =>
      (parseCliArgs(args) as CliArgs).jsr!;

  group('fa jsr parsing', () {
    test('bare jsr is a usage error listing the verbs', () {
      expect(
        () => parseCliArgs(['jsr']),
        throwsA(
          isA<CliArgsException>().having(
            (e) => e.message,
            'message',
            contains('widget:test|widget:screenshot'),
          ),
        ),
      );
    });

    test('--help inside the family wins', () {
      expect(parseCliArgs(['jsr', '--help']), isA<CliArgsHelp>());
      expect(parseCliArgs(['jsr', 'widget:test', '-h']), isA<CliArgsHelp>());
    });

    test('unknown verb is a usage error', () {
      expect(
        () => parseCliArgs(['jsr', 'widget:render']),
        throwsA(
          isA<CliArgsException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('unknown jsr verb: widget:render'),
              contains('widget:test'),
            ),
          ),
        ),
      );
    });

    test('AC1 shape: widget:test with repeated and wildcard events', () {
      final cmd = parse([
        'jsr',
        'widget:test',
        'example/widgets/calculator',
        '--event',
        'btn_7',
        '--event',
        'btn_*',
        '--event',
        'btn_6',
        '--event',
        'btn_=',
        '--expect-state',
        '{"display":"42"}',
      ]);
      expect(cmd.verb, 'widget:test');
      expect(cmd.args, [
        'example/widgets/calculator',
        '--event',
        'btn_7',
        '--event',
        'btn_*',
        '--event',
        'btn_6',
        '--event',
        'btn_=',
        '--expect-state',
        '{"display":"42"}',
      ]);
    });

    test('widget:screenshot flags pass through untouched', () {
      final cmd = parse([
        'jsr',
        'widget:screenshot',
        'example/widgets/calculator',
        '--out',
        'shot.png',
        '--width',
        '390',
        '--height',
        '844',
        '--theme',
        'dark',
        '--scale',
        '2',
        '--freeze-clock',
      ]);
      expect(cmd.verb, 'widget:screenshot');
      expect(cmd.args, containsAll(['--freeze-clock', '2']));
      expect(cmd.args.last, '--freeze-clock');
    });

    test('unknown jsr flags are FORWARDED, never rejected (I1)', () {
      // The flag surface is jsr-owned and may drift (e.g. --settle-ms);
      // fah must not grow validator code for it.
      final cmd = parse([
        'jsr',
        'widget:test',
        'w',
        '--settle-ms',
        '750',
        '--boot-timeout-ms',
        '9000',
        '--seed-storage',
        '{"k":"v"}',
        '--json',
      ]);
      expect(cmd.args, contains('--settle-ms'));
      expect(cmd.args, contains('750'));
      expect(cmd.args, contains('--seed-storage'));
      expect(cmd.args, contains('--json'));
    });

    test('missing widget path operand is a usage error', () {
      expect(
        () => parseCliArgs(['jsr', 'widget:test', '--json']),
        throwsA(
          isA<CliArgsException>().having(
            (e) => e.message,
            'message',
            contains('requires a widget path'),
          ),
        ),
      );
      expect(
        () => parseCliArgs(['jsr', 'widget:screenshot']),
        throwsA(isA<CliArgsException>()),
      );
    });

    test('the jsr verb words never become a prompt (REG)', () {
      final result = parseCliArgs([
        'jsr',
        'widget:test',
        'calc',
        '--event',
        'btn_7',
      ]);
      final args = result as CliArgs;
      expect(args.jsr, isNotNull);
      expect(args.positionals, isEmpty);
      expect(args.isHeadless, isFalse);
    });

    test('non-jsr invocations still parse as prompts (REG)', () {
      final args = parseCliArgs(['jsr like the package registry']) as CliArgs;
      expect(args.jsr, isNull);
      expect(args.positionals, ['jsr like the package registry']);
    });
  });
}

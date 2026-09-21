/// Markdown renders in every human-read CLI surface (issue #774).
///
/// Pins the per-surface routing through the ONE [MarkdownSurface] policy:
/// headless-to-TTY and the line-mode REPL render (AC2), piped/redirected
/// output stays byte-identical raw (AC3), `NO_COLOR`-style degrades render
/// structure with zero escape bytes (AC4), and markdown inside tool
/// results stays raw data (E7). Deterministic: fake [CliIO], no PTY.
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// The owner-reported repro shape: heading + list + table + fence — the
/// AC2 construct coverage, in one deterministic fixture.
const _repro =
    '# Plan\n\n- **step** one\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n'
    '```dart\nvar x = 1;\n```\n';

/// A [CliIO] with the headless channel split: [write] is the pipeable
/// primary stream (stdout), [writeln] diagnostics (stderr).
class _HeadlessIO implements CliIO {
  final out = StringBuffer();
  final diag = StringBuffer();

  @override
  int columns = 80;

  @override
  int rows = 24;

  @override
  bool get isInteractive => false;

  @override
  Stream<String> get lines => const Stream<String>.empty();

  @override
  Stream<void> get interrupts => const Stream<void>.empty();

  @override
  Stream<KeyEvent> get keys => const Stream<KeyEvent>.empty();

  @override
  bool get supportsRawMode => false;

  @override
  void write(String text) => out.write(text);

  @override
  void writeln(String text) => diag.write('$text\n');
}

AgentCli _headlessCli(
  _HeadlessIO io, {
  MarkdownSurface? markdownSurface,
}) {
  return AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: 'test-key',
      env: MemoryExecutionEnv(cwd: '/work'),
      sessionRoot: '/sessions',
    ),
    io: io,
    streamFunction: FakeStreamFunction([textTurn(_repro)]).call,
    markdownSurface: markdownSurface,
  );
}

void main() {
  group('headless -p (issue #774)', () {
    test('to a color TTY renders through the policy (AC2)', () async {
      final io = _HeadlessIO();
      final surface = MarkdownSurface.resolving(
        tty: true,
        color: true,
        width: 80,
      );
      final code = await _headlessCli(
        io,
        markdownSurface: surface,
      ).runHeadless('hi');

      expect(code, 0);
      // The stdout bytes are exactly the policy's render + the trailing
      // newline the line channel owns.
      expect(io.out.toString(), '${surface.render(_repro)}\n');
      // The raw-### symptom is gone: the h1 strips the marker and gains
      // emphasis; list, table and fence render.
      expect(io.out.toString(), contains('\x1b[4mPlan'));
      expect(io.out.toString(), isNot(contains('# Plan')));
      expect(io.out.toString(), contains('•'));
      expect(io.out.toString(), contains('│'));
      expect(io.out.toString(), contains('  var x = 1;'));
    });

    test('piped stays byte-identical raw (AC3)', () async {
      final io = _HeadlessIO();
      final code = await _headlessCli(
        io,
        markdownSurface: MarkdownSurface.resolving(tty: false, color: true),
      ).runHeadless('hi');

      expect(code, 0);
      expect(io.out.toString(), '$_repro\n'); // exact raw bytes
      expect(io.out.toString().contains('\x1b'), isFalse);
    });

    test('a default (unresolved) surface keeps the legacy raw bytes',
        () async {
      final io = _HeadlessIO();
      final code = await _headlessCli(io).runHeadless('hi');

      expect(code, 0);
      expect(io.out.toString(), '$_repro\n');
    });

    test('NO_COLOR-style degrade renders structure, zero escapes (AC4)',
        () async {
      final io = _HeadlessIO();
      final code = await _headlessCli(
        io,
        markdownSurface: MarkdownSurface.resolving(tty: true, color: false),
      ).runHeadless('hi');

      expect(code, 0);
      final out = io.out.toString();
      expect(out.contains('\x1b'), isFalse); // byte-scan
      expect(out, contains('Plan')); // heading emphasis kept, marker gone
      expect(out, isNot(contains('# Plan')));
      expect(out, contains('•'));
      expect(out, contains('│'));
      expect(out, contains('  var x = 1;'));
    });
  });

  group('line-mode REPL (issue #774)', () {
    test('assistant answers render through the policy (AC2)', () async {
      final io = FakeCliIO();
      final surface = MarkdownSurface.resolving(
        tty: true,
        color: true,
        width: 80,
      );
      final fake = FakeStreamFunction([textTurn(_repro)]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: MemoryExecutionEnv(cwd: '/work'),
          sessionRoot: '/sessions',
        ),
        io: io,
        useColor: true,
        streamFunction: fake.call,
        markdownSurface: surface,
      );

      final run = cli.run();
      io.sendLine('hi');
      await waitForIt(() => fake.calls == 1 && !cli.isBusy);
      io.sendLine('/exit');
      await run;

      final out = io.out.toString();
      expect(out, contains(surface.render(_repro)));
      expect(out, contains('\x1b[4mPlan'));
      expect(out, isNot(contains('# Plan')));
      expect(out, contains('•'));
      expect(out, contains('│'));
      await io.close();
    });
  });
}

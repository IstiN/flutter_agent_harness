/// Markdown renders in every human-read CLI surface (issue #774).
///
/// Pins the per-surface routing through the ONE [MarkdownSurface] policy:
/// headless-to-TTY and the line-mode REPL render (AC2), piped/redirected
/// output stays byte-identical raw (AC3), `NO_COLOR`-style degrades render
/// structure with zero escape bytes (AC4), raw pipes stream deltas live
/// while styled modes buffer to message end (review #778), and the theme
/// palette resolves once and rides the surface. Deterministic: fake
/// [CliIO], no PTY.
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:flutter_agent_harness/src/cli/tui_theme.dart'
    show ColorProfile, FaThemeController;
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
  // The policy reads the process-wide controller (it must never write
  // it — issue #778 round 2); tests pin it so constructor writes in the
  // wiring groups cannot leak into golden groups regardless of order.
  setUp(() => FaThemeController.instance.profile = ColorProfile.trueColor);

  group('headless -p (issue #774)', () {
    test('to a color TTY renders through the policy (AC2)', () async {
      final io = _HeadlessIO();
      final surface = MarkdownSurface.resolving(
        tty: true,
        color: true,
        width: 80,
        profile: ColorProfile.trueColor,
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
      // ```dart highlights per line — compare escape-free text.
      expect(
        io.out.toString().replaceAll(RegExp(r'\x1b\[[0-9;]*m'), ''),
        contains('  var x = 1;'),
      );
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
        profile: ColorProfile.trueColor,
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

  /// A stream function whose first delta lands before the message ends:
  /// [gate] releases the second delta and the DoneEvent.
  StreamFunction gatedStream(Completer<void> gate, String full) {
    return (model, context, {cancelToken}) {
      AssistantMessage partialOf(String text) => testAssistant(
        content: [TextContent(text: text)],
      );
      final stream = AssistantMessageEventStream()
        ..push(StartEvent(partial: testAssistant()))
        ..push(TextStartEvent(contentIndex: 0, partial: testAssistant()))
        ..push(
          TextDeltaEvent(
            contentIndex: 0,
            delta: 'hel',
            partial: partialOf('hel'),
          ),
        );
      unawaited(
        gate.future.then((_) {
          stream
            ..push(
              TextDeltaEvent(
                contentIndex: 0,
                delta: 'lo there',
                partial: partialOf(full),
              ),
            )
            ..push(
              DoneEvent(reason: StopReason.stop, message: partialOf(full)),
            )
            ..end();
        }),
      );
      return stream;
    };
  }

  group('streaming mode split (review #778)', () {
    test('raw mode streams deltas live — no per-message buffering', () async {
      final io = _HeadlessIO();
      final gate = Completer<void>();
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: MemoryExecutionEnv(cwd: '/work'),
          sessionRoot: '/sessions',
        ),
        io: io,
        streamFunction: gatedStream(gate, 'hello there'),
        // Default const surface = raw passthrough.
      );

      final run = cli.runHeadless('hi');
      // The first delta is on stdout BEFORE the message ends: pipes get
      // live bytes again.
      await waitForIt(() => io.out.toString() == 'hel');
      gate.complete();
      expect(await run, 0);
      // And the full stream is byte-identical to the pre-#774 output —
      // no re-render, no doubled text.
      expect(io.out.toString(), 'hello there\n');
    });

    test('ansi mode buffers and renders once at message end', () async {
      final io = _HeadlessIO();
      final gate = Completer<void>();
      final surface = MarkdownSurface.resolving(
        tty: true,
        color: true,
        width: 80,
        profile: ColorProfile.trueColor,
      );
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: MemoryExecutionEnv(cwd: '/work'),
          sessionRoot: '/sessions',
        ),
        io: io,
        streamFunction: gatedStream(gate, 'hello there'),
        markdownSurface: surface,
      );

      final run = cli.runHeadless('hi');
      // Deltas are consumed but buffered: nothing on stdout mid-message.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(io.out.toString(), isEmpty);
      gate.complete();
      expect(await run, 0);
      expect(io.out.toString(), '${surface.render('hello there')}\n');
    });
  });

  group('FA_NO_FORMAT env parse (review #778)', () {
    test('truthy values count as forced-raw, case/trim tolerant', () {
      for (final value in ['1', 'true', 'TRUE', ' yes ', 'on', 'On']) {
        expect(isTruthyEnvValue(value), isTrue, reason: value);
      }
    });

    test('falsy and absent values never force raw', () {
      for (final value in ['0', 'false', 'FALSE', '', 'no', 'off', null]) {
        expect(isTruthyEnvValue(value), isFalse, reason: '$value');
      }
    });
  });

  group('theme palette wiring (review #778)', () {
    test('the surface palette is the single CLI resolution', () {
      AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: MemoryExecutionEnv(cwd: '/work'),
          sessionRoot: '/sessions',
        ),
        io: _HeadlessIO(),
        markdownSurface: MarkdownSurface(
          mode: MarkdownSurfaceMode.ansi,
          profile: ColorProfile.trueColor,
        ),
      );
      expect(FaThemeController.instance.profile, ColorProfile.trueColor);
    });

    test('a plain palette pins plain; no palette falls back to detection',
        () {
      AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: MemoryExecutionEnv(cwd: '/work'),
          sessionRoot: '/sessions',
        ),
        io: _HeadlessIO(),
        markdownSurface: MarkdownSurface(
          mode: MarkdownSurfaceMode.ansi,
          profile: ColorProfile.ansi256,
        ),
      );
      expect(FaThemeController.instance.profile, ColorProfile.ansi256);

      // Null profile: the constructor's own detection with no styling
      // inputs (headless, uncolored) degrades to null — pre-#774 rule.
      AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: MemoryExecutionEnv(cwd: '/work'),
          sessionRoot: '/sessions',
        ),
        io: _HeadlessIO(),
        markdownSurface: const MarkdownSurface(),
      );
      expect(FaThemeController.instance.profile, isNull);
    });
  });

  group('resolveMarkdownSurface — the host wiring step (issue #778 r2)', () {
    test('a terminal resolves ANSI with the detected palette', () {
      final s = resolveMarkdownSurface(ansiSupported: true);
      expect(s.mode, MarkdownSurfaceMode.ansi);
      expect(s.profile, isNotNull);
      // The palette is the CLI styling's source of truth: chrome styles
      // iff the surface resolved one (bin/fah useColor derivation).
      expect(s.profile != null, isTrue);
    });

    test('a pipe stays raw byte-identical (AC3)', () {
      final s = resolveMarkdownSurface(ansiSupported: false);
      expect(s.mode, MarkdownSurfaceMode.raw);
      expect(s.profile, isNull);
    });

    test('NO_COLOR degrades the WHOLE session to plain', () {
      final s = resolveMarkdownSurface(
        ansiSupported: true,
        environment: const {'NO_COLOR': '1'},
      );
      expect(s.mode, MarkdownSurfaceMode.plain);
      expect(s.profile, isNull);
    });

    test('TERM=dumb degrades to plain', () {
      final s = resolveMarkdownSurface(
        ansiSupported: true,
        environment: const {'TERM': 'dumb'},
      );
      expect(s.mode, MarkdownSurfaceMode.plain);
      expect(s.profile, isNull);
    });

    test('FA_NO_FORMAT truthy forces raw; =0 does not', () {
      expect(
        resolveMarkdownSurface(
          ansiSupported: true,
          environment: const {'FA_NO_FORMAT': '1'},
        ).mode,
        MarkdownSurfaceMode.raw,
      );
      expect(
        resolveMarkdownSurface(
          ansiSupported: true,
          environment: const {'FA_NO_FORMAT': '0'},
        ).mode,
        MarkdownSurfaceMode.ansi,
      );
    });

    test('the --no-format flag forces raw', () {
      expect(
        resolveMarkdownSurface(ansiSupported: true, noFormatFlag: true).mode,
        MarkdownSurfaceMode.raw,
      );
    });

    test('width threads through (the one construction-time freeze)', () {
      expect(resolveMarkdownSurface(ansiSupported: true, width: 40).width, 40);
    });
  });
}

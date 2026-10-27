// gh-1929: esc during the PRE-FLIGHT auto-compaction must cancel the
// SUBMISSION, never crash the CLI. The compaction layer's rethrow is
// deliberate (issue #1085) — a cancelled compaction surfaces as an abort —
// but `_runPrompt` ran the pre-flight OUTSIDE its guarded body, so the
// deliberate `CancelledException` escaped into the fire-and-forget run
// future (`_startRun`'s unlistened `whenComplete` chain) and reached the
// root zone handler: `fa crashed: CancelledException: interrupted by user`
// + crash.log + exit 1, with the typed prompt lost.
//
// Layers covered:
// - interactive line mode: esc mid-pre-flight → no crash, neutral
//   cancelled status (never `error:`), prompt NOT sent, and the next
//   prompt retries the compaction and runs normally (IT-1);
// - headless `fa -p`: same cancel exits 130 — the aborted-run semantics —
//   with no `error:` line (IT-2);
// - the live TUI submit boundary: the composer text is RESTORED after a
//   cancelled pre-flight (the submission was never sent) (IT-3);
// - regression: esc during a NORMAL streaming run keeps its current
//   behavior — aborted transcript message, no cancelled-submission
//   receipt, no `error:` line (REG-1).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

// Over-TRIGGER but UNDER-WINDOW resume (the lazy regime, gh-1425 AC5):
// boot defers and the first turn's pre-flight owns the durable compaction —
// the exact window gh-1929 crashes in. Same numbers the resume-boot-cap
// suite pins: 131072 window, trigger 114688, ~115k seeded tokens.
const _window = 131072;
const _trigger = _window - 16384;

Model get _bigModel => const Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: _window,
  maxTokens: 4096,
);

/// A scripted stream whose calls from [hangFromCall] on never emit until
/// their [CancelToken] fires — the deterministic way to freeze the CLI
/// inside the pre-flight compaction summarizer and then deliver the user's
/// esc as a real provider abort (like `ScriptedThenHangStream`, plus
/// request capture for the prompt-NOT-sent assertions).
class _CancelObservingStream {
  _CancelObservingStream(this.scripted, {this.hangFromCall = 1 << 30});

  final List<List<AssistantMessageEvent>> scripted;
  var calls = 0;
  int hangFromCall;
  final contexts = <Context>[];

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final n = ++calls;
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
    final stream = AssistantMessageEventStream();
    if (n < hangFromCall || n > scripted.length) {
      for (final event in scripted[n - 1]) {
        stream.push(event);
      }
      stream.end();
      return stream;
    }
    stream.push(StartEvent(partial: testAssistant()));
    var aborted = false;
    cancelToken?.onCancel.then((_) {
      if (aborted) return;
      aborted = true;
      stream.push(
        ErrorEvent(
          reason: StopReason.aborted,
          error: testAssistant(
            stopReason: StopReason.aborted,
            errorMessage: 'Operation aborted',
          ),
        ),
      );
      stream.end();
    });
    return stream;
  }
}

/// Collects rendered TUI frame bytes (dart_tui wraps this into an IOSink).
class _FrameSink implements StreamConsumer<List<int>> {
  final _bytes = BytesBuilder(copy: false);

  void add(List<int> data) => _bytes.add(data);

  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> close() async {}

  String get text => utf8.decode(_bytes.toBytes(), allowMalformed: true);

  /// The rendered transcript with ANSI control sequences stripped.
  String get plain => text
      .replaceAll(RegExp('\u001B\\][^\u0007]*\u0007'), '')
      .replaceAll(RegExp('\u001B\\[[0-9;?]*[A-Za-z]'), '');
}

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  /// Seeds an over-trigger / under-window named session (the shape the
  /// resume-boot-cap suite pins): 10 old + a compaction boundary + kept
  /// recent messages, each priced ~100 tokens.
  Future<MemoryExecutionEnv> seedOverWindow(
    String name, {
    int keptCount = 115,
  }) async {
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final seed = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await seed.appendSessionName(name);
    for (var i = 0; i < 10; i++) {
      await seed.appendMessage(UserMessage.text('old$i ${'a' * 4000}'));
    }
    final firstKept = await seed.appendMessage(
      UserMessage.text('kept0 ${'a' * 4000}'),
    );
    await seed.appendCompaction(
      summary: 'earlier marathon context',
      firstKeptEntryId: firstKept,
      tokensBefore: 99999,
    );
    for (var i = 1; i < keptCount; i++) {
      await seed.appendMessage(UserMessage.text('kept$i ${'a' * 4000}'));
    }
    return env;
  }

  /// Whether ANY captured request carried [text] as its latest user
  /// message — the prompt-really-was-not-sent probe.
  bool promptSent(_CancelObservingStream stream, String text) =>
      stream.contexts.any(
        (context) => context.messages.lastOrNull is UserMessage &&
            messageText(context.messages.last as UserMessage) == text,
      );

  group('interactive submit cancel during the pre-flight compaction', () {
    test(
      'esc mid-pre-flight cancels the submission: no crash, neutral '
      'status, prompt not sent, next prompt recovers (IT-1)',
      timeout: const Timeout(Duration(minutes: 2)),
      () async {
        await seedOverWindow('cancel-target');
        final stream = _CancelObservingStream([
          textTurn('resumed context summary'),
          textTurn('recovered context summary'),
          textTurn('recovered answer'),
          textTurn('spare'),
        ], hangFromCall: 1);
        final cli = AgentCli(
          config: AgentCliConfig(
            model: _bigModel,
            apiKey: 'test-key',
            env: env,
            sessionRoot: '/sessions',
            sessionName: 'cancel-target',
            providerKind: 'openai-completions',
            skillsAccess: SkillsAccess.granted,
            // Classic: ONE summarizer call per pass — deterministic
            // call indices (issue #287 default is structured).
            compactionEngine: CompactionEngine.classic,
          ),
          io: io,
          streamFunction: stream.call,
        );
        final run = cli.run();
        // Lazy boot: the over-trigger resume defers to the first turn's
        // pre-flight — zero provider calls so far.
        await waitForIt(
          () =>
              io.out.toString().contains(
                'compaction deferred to the first message',
              ) &&
              !cli.isBusy,
          reason: 'boot settles without any compaction pass',
        );
        expect(stream.calls, 0);

        io.sendLine('rescue-me');
        await waitForIt(
          () => stream.calls >= 1,
          reason: 'the pre-flight summarizer started',
        );
        // The esc: the same `_abortRunOrCompaction` the TUI esc/Ctrl+C
        // route through while the run bracket is up.
        io.interrupt();
        await waitForIt(
          () => !cli.isBusy,
          reason: 'the cancelled submission settles',
        );

        final out = io.out.toString();
        // THE crash regression: the deliberate abort must surface as the
        // neutral cancelled status — never as an `error:` line (and never
        // as the unhandled zone error that killed the process, which
        // fails this test on its own pre-fix).
        expect(out, contains('submission cancelled'));
        expect(out, isNot(contains('error:')));
        expect(out, isNot(contains('CancelledException')));
        // The prompt was never sent: the only request is the summarizer's.
        expect(stream.calls, 1);
        expect(promptSent(stream, 'rescue-me'), isFalse);

        // Session alive: the next prompt retries the compaction (the
        // fresh turn re-arms it) and runs normally.
        stream.hangFromCall = 1 << 30;
        io.sendLine('again');
        await waitForIt(
          () => stream.calls >= 3 && !cli.isBusy,
          reason: 'the retried pre-flight compaction + turn settle',
        );
        expect(io.out.toString(), contains('recovered answer'));

        io.sendLine('/exit');
        await run;
      },
    );
  });

  group('headless submit cancel during the pre-flight compaction', () {
    test(
      'esc mid-pre-flight exits 130 with no error line, prompt not '
      'sent (IT-2)',
      timeout: const Timeout(Duration(minutes: 2)),
      () async {
        await seedOverWindow('headless-cancel');
        final stream = _CancelObservingStream([
          textTurn('resumed context summary'),
          textTurn('spare'),
        ], hangFromCall: 1);
        final cli = AgentCli(
          config: AgentCliConfig(
            model: _bigModel,
            apiKey: 'test-key',
            env: env,
            sessionRoot: '/sessions',
            sessionName: 'headless-cancel',
            providerKind: 'openai-completions',
            skillsAccess: SkillsAccess.granted,
            compactionEngine: CompactionEngine.classic,
          ),
          io: io,
          streamFunction: stream.call,
        );
        final exitFuture = cli.runHeadless('rescue-me');
        await waitForIt(
          () => stream.calls >= 1,
          reason: 'the headless pre-flight summarizer started',
        );
        io.interrupt();
        final code = await exitFuture;

        // Normal cancelled semantics — the aborted-run exit code, not
        // the failure path's 1 + `error:` line.
        expect(code, 130);
        final out = io.out.toString();
        expect(out, contains('submission cancelled'));
        expect(out, isNot(contains('error:')));
        expect(out, isNot(contains('CancelledException')));
        expect(stream.calls, 1);
        expect(promptSent(stream, 'rescue-me'), isFalse);
      },
    );
  });

  group('the live TUI submit boundary', () {
    late _FrameSink frames;
    late StreamController<List<int>> keys;

    setUp(() {
      frames = _FrameSink();
      keys = StreamController<List<int>>();
    });

    /// Boots the real CLI in TUI mode over the over-window resume.
    Future<AgentCli> bootTui() async {
      final stream = _CancelObservingStream([
        textTurn('resumed context summary'),
        textTurn('recovered context summary'),
        textTurn('recovered answer'),
        textTurn('spare'),
      ], hangFromCall: 1);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: _bigModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          sessionName: 'tui-cancel',
          providerKind: 'openai-completions',
          skillsAccess: SkillsAccess.granted,
          compactionEngine: CompactionEngine.classic,
          tuiProgramHooks: TuiProgramHooks(
            input: keys.stream,
            output: frames,
            width: 80,
            height: 24,
          ),
        ),
        io: io,
        useTui: true,
        streamFunction: stream.call,
      );
      final run = cli.run();
      unawaited(run.catchError((Object _) {}));
      await seedOverWindow('tui-cancel');
      await waitForIt(
        () =>
            frames.plain.contains(
              'compaction deferred to the first message',
            ) ||
            frames.text.contains('\x1b[?1049h'),
        reason: 'the TUI booted',
      );
      return cli;
    }

    Future<void> quitTui() async {
      keys.add([0x03]); // ctrl+c press 1: arms the double-press window
      keys.add([0x03]); // press 2 within the window quits the TUI
    }

    test(
      'esc mid-pre-flight restores the composer text (IT-3)',
      timeout: const Timeout(Duration(minutes: 2)),
      () async {
        final cli = await bootTui();
        try {
          // The live TUI submit: the echo lands, the composer clears,
          // and the pre-flight compaction freezes on the hung summarizer.
          final submit = cli.tuiSubmitForTest('ZR9Q rescue me', const []);
          await waitForIt(
            () => frames.plain.contains('ZR9Q rescue me'),
            reason: 'the submitted text echoed into the transcript',
          );
          // The esc key: aborts the pre-flight compaction mid-flight.
          keys.add([0x1B]);
          await submit;
          await waitForIt(
            () => !cli.isBusy,
            reason: 'the cancelled submission settles',
          );

          final plain = frames.plain;
          expect(plain, contains('submission cancelled'));
          expect(plain, isNot(contains('error:')));
          expect(plain, isNot(contains('CancelledException')));
          // The composer text is RESTORED: the echo above holds one
          // occurrence, the refilled composer a second one (pre-fix the
          // submitted text lived only in the stale echo).
          expect(
            'ZR9Q'.allMatches(plain).length,
            greaterThanOrEqualTo(2),
            reason: 'the composer must hold the typed text again',
          );
        } finally {
          await quitTui();
        }
      },
    );
  });

  group('regression: esc during a normal streaming run', () {
    test(
      'keeps its current behavior: aborted transcript, no cancel '
      'receipt, no error line (REG-1)',
      timeout: const Timeout(Duration(seconds: 120)),
      () async {
        final stream = _CancelObservingStream([
          textTurn('a quick answer'),
        ], hangFromCall: 1);
        final cli = AgentCli(
          config: AgentCliConfig(
            model: testModel,
            apiKey: 'test-key',
            env: env,
            sessionRoot: '/sessions',
            providerKind: 'openai-completions',
            skillsAccess: SkillsAccess.granted,
          ),
          io: io,
          streamFunction: stream.call,
        );
        final run = cli.run();
        io.sendLine('hello');
        await waitForIt(() => stream.calls >= 1 && cli.isBusy);
        io.interrupt();
        await waitForIt(() => !cli.isBusy);

        final out = io.out.toString();
        // The classic aborted-turn surface is untouched.
        expect(out, contains('Operation aborted'));
        expect(out, isNot(contains('submission cancelled')));
        expect(out, isNot(contains('error:')));

        io.sendLine('/exit');
        await run;
      },
    );
  });
}

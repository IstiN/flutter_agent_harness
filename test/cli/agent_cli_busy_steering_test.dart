import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'package:flutter_agent_harness/src/cli/paste_image.dart';

import 'agent_cli_test_support.dart';

/// A stream function that blocks one chosen call on a gate (copied from
/// the busy-gate test): the deterministic way to hold a run open while
/// the test types mid-run input.
class _GatedStream {
  _GatedStream(this.turns, {required this.gateOnCall});

  final List<List<AssistantMessageEvent>> turns;
  final int gateOnCall;
  final gate = Completer<void>();
  final contexts = <Context>[];

  int get calls => contexts.length;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
    final stream = AssistantMessageEventStream();
    void emit(List<AssistantMessageEvent> events) {
      for (final event in events) {
        stream.push(event);
      }
      stream.end();
    }

    if (calls == gateOnCall) {
      unawaited(
        gate.future.then((_) {
          // A cancelled token surfaces as an aborted completion (the
          // provider contract), leaving the steering queue untouched —
          // the deterministic leftover-steering setup.
          emit(
            (cancelToken?.isCancelled ?? false)
                ? _abortedTurn()
                : turns.removeAt(0),
          );
        }),
      );
    } else {
      emit(turns.removeAt(0));
    }
    return stream;
  }
}

/// An aborted completion (the provider-contract abort surface).
List<AssistantMessageEvent> _abortedTurn() {
  final empty = testAssistant();
  final partial = testAssistant(
    content: const [TextContent(text: '')],
    stopReason: StopReason.aborted,
  );
  return [
    StartEvent(partial: empty),
    DoneEvent(reason: StopReason.aborted, message: partial),
  ];
}

/// Waits for the CLI to persist its session (boot complete).
Future<void> waitForSessions(MemoryExecutionEnv env) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  for (var i = 0; i < 5000; i++) {
    if ((await repo.list(cwd: '/work')).isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: session persisted');
}

/// Steering-message delivery in the busy CLI.
///
/// Covers the user-reported steering bugs:
/// - a message whose FIRST token is an existing file path used to hit the
///   command dispatcher mid-run and die on `_startRun`'s busy guard —
///   silently dropped;
/// - steered messages that only reach a drain point after the run ended
///   used to sit in the queue until an unrelated later run (or forever);
/// - an interrupt used to discard queued/steered messages without ever
///   showing what was dropped.
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;
  final tempFiles = <File>[];

  File tempFile(String name) {
    final file = File('${Directory.systemTemp.path}/fah_busy_steering_$name')
      ..writeAsStringSync('hello from $name');
    tempFiles.add(file);
    return file;
  }

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() async {
    await io.close();
    for (final file in tempFiles) {
      if (file.existsSync()) file.deleteSync();
    }
    tempFiles.clear();
  });

  /// Builds the CLI and REBINDS [env] to the instance it uses — session
  /// persistence probes in these tests read the same in-memory filesystem.
  AgentCli buildCli(_GatedStream stream, {String shellStdout = ''}) {
    env = MemoryExecutionEnv(
      cwd: '/work',
      shell: shellStdout.isEmpty
          ? const UnavailableShell()
          : FakeShell(stdout: shellStdout),
    );
    return AgentCli(
      config: AgentCliConfig(
        model: const Model(
          id: 'test-model',
          api: 'test-api',
          provider: 'test-provider',
          baseUrl: 'https://example.test',
          contextWindow: 128000,
          maxTokens: 4096,
        ),
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
      ),
      io: io,
      streamFunction: stream.call,
    );
  }

  test(
    'a file-path message typed mid-run is steered with the attachment '
    'marker, never dropped by the busy guard',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final file = tempFile('report.md');
      final stream = _GatedStream([
        textTurn('first answer'),
        textTurn('steered answer'),
      ], gateOnCall: 1);
      final cli = buildCli(stream);
      final run = cli.run();
      await waitForSessions(env);

      io.sendLine('start');
      await waitForIt(() => stream.calls >= 1 && cli.isBusy);
      io.sendLine('${file.path} summarize this please');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      stream.gate.complete();
      await waitForIt(() => !cli.isBusy, reason: 'first run settles');

      // The steered message must become a follow-up run whose prompt is the
      // RESOLVED attachment marker — not the raw path, not a dropped line.
      await waitForIt(() => stream.calls >= 2);
      await waitForIt(() => !cli.isBusy);
      final text = messageText(stream.contexts[1].messages.last as UserMessage);
      expect(text, contains('[attached file:'));
      expect(text, contains('summarize this please'));
      expect(
        io.out.toString(),
        isNot(contains('a run is already streaming')),
        reason: 'the busy guard must not swallow the message',
      );

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'a ./-prefixed file message steered mid-run carries the attachment '
    'marker too',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      // './name' resolves against the PROCESS working directory (the
      // repo root under `dart test`), so the file must live there.
      final file = File('fah_busy_steering_notes.md')
        ..writeAsStringSync('hello from notes');
      tempFiles.add(file);
      final relative = './fah_busy_steering_notes.md';
      final stream = _GatedStream([
        textTurn('first answer'),
        textTurn('steered answer'),
      ], gateOnCall: 1);
      final cli = buildCli(stream);
      final run = cli.run();
      await waitForSessions(env);

      io.sendLine('start');
      await waitForIt(() => stream.calls >= 1 && cli.isBusy);
      io.sendLine('$relative check this');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      stream.gate.complete();
      await waitForIt(() => !cli.isBusy);
      await waitForIt(() => stream.calls >= 2);
      await waitForIt(() => !cli.isBusy);
      final text = messageText(stream.contexts[1].messages.last as UserMessage);
      expect(text, contains('[attached file:'));
      expect(text, contains('check this'));

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'a path-led message typed mid-run steers verbatim — a folder or '
    'nonexistent leading path is never refused nor bounced by the busy '
    'guard (issue #1152)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final dir = await Directory.systemTemp.createTemp('fah_busy_dir_1152');
      addTearDown(() => dir.delete(recursive: true));
      final stream = _GatedStream([
        textTurn('first answer'),
        textTurn('steered answer'),
      ], gateOnCall: 1);
      final cli = buildCli(stream);
      final run = cli.run();
      await waitForSessions(env);

      io.sendLine('start');
      await waitForIt(() => stream.calls >= 1 && cli.isBusy);
      final message = '${dir.path} найди в fa create goal скилл';
      io.sendLine(message);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      stream.gate.complete();
      await waitForIt(() => !cli.isBusy, reason: 'first run settles');

      // The steered message becomes a follow-up run carrying the full
      // sentence verbatim — a directory attaches nothing, refuses nothing.
      await waitForIt(() => stream.calls >= 2);
      await waitForIt(() => !cli.isBusy);
      final text = messageText(stream.contexts[1].messages.last as UserMessage);
      expect(text, contains(message));
      final out = io.out.toString();
      expect(out, isNot(contains('looks like a filesystem path')));
      expect(
        out,
        isNot(contains('a run is already streaming')),
        reason: 'the busy guard must not bounce path-led chat',
      );

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'a known slash command with args typed mid-run still dispatches — '
    'not mistaken for path-led chat (issue #1152 strictness)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final stream = _GatedStream([textTurn('first answer')], gateOnCall: 1);
      final cli = buildCli(stream);
      final run = cli.run();
      await waitForSessions(env);

      io.sendLine('start');
      await waitForIt(() => stream.calls >= 1 && cli.isBusy);
      io.sendLine('/help exit');
      await waitForIt(
        () => io.out.toString().contains('/exit'),
        reason: 'the slash command executes immediately, mid-run',
      );
      expect(cli.isBusy, isTrue, reason: 'the run keeps streaming');

      // No steering side channel: a known command never becomes a
      // follow-up run.
      stream.gate.complete();
      await waitForIt(() => !cli.isBusy);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(stream.calls, 1, reason: 'a known command must not steer');
      expect(io.out.toString(), isNot(contains('a run is already streaming')));

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'a path-led TUI submit with chips mid-run steers the images too '
    '(issue #1152 round-2)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final dir = await Directory.systemTemp.createTemp('fah_busy_chips_1152');
      addTearDown(() => dir.delete(recursive: true));
      const chip = TuiImageAttachment(
        name: 'clipboard-1.png',
        mimeType: 'image/png',
        bytes: [0x89, 0x50, 0x4E, 0x47, 1, 2, 3],
      );
      final stream = _GatedStream([
        textTurn('first answer'),
        textTurn('steered answer'),
      ], gateOnCall: 1);
      final cli = buildCli(stream);
      final run = cli.run();
      await waitForSessions(env);

      io.sendLine('start');
      await waitForIt(() => stream.calls >= 1 && cli.isBusy);
      // tuiSubmitForTest awaits _settled (the in-flight gated run) after
      // handling the line — awaiting it here would deadlock against the
      // gate below. Fire it, open the gate, THEN await it.
      final submit = cli.tuiSubmitForTest('${dir.path} summarize this please', [
        chip,
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      stream.gate.complete();
      await submit;
      await waitForIt(() => !cli.isBusy, reason: 'first run settles');
      await waitForIt(() => stream.calls >= 2);
      await waitForIt(() => !cli.isBusy);

      // The steered turn carries the image next to the path-led text.
      final blocks =
          (stream.contexts[1].messages.last as UserMessage).content
              as List<ContentBlock>;
      expect(
        blocks.whereType<TextContent>().map((b) => b.text).join(' '),
        contains('summarize this please'),
      );
      expect(
        blocks.whereType<ImageContent>().map((b) => b.mimeType),
        contains('image/png'),
      );

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'plain text typed mid-run is delivered to the model',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final stream = _GatedStream([
        textTurn('first answer'),
        textTurn('late answer'),
      ], gateOnCall: 1);
      final cli = buildCli(stream);
      final run = cli.run();
      await waitForSessions(env);

      io.sendLine('start');
      await waitForIt(() => stream.calls >= 1 && cli.isBusy);
      io.sendLine('late user question');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      stream.gate.complete();
      await waitForIt(() => !cli.isBusy);
      await waitForIt(() => stream.calls >= 2);
      await waitForIt(() => !cli.isBusy);
      final text = messageText(stream.contexts[1].messages.last as UserMessage);
      expect(text, contains('late user question'));

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'a bang-command typed mid-run executes immediately AND the agent is '
    'told the user ran it',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final stream = _GatedStream([textTurn('first answer')], gateOnCall: 1);
      final cli = buildCli(stream, shellStdout: 'bang-ran-now\n');
      final run = cli.run();
      await waitForSessions(env);

      io.sendLine('start');
      await waitForIt(() => stream.calls >= 1 && cli.isBusy);
      io.sendLine('!echo bang-ran-now');
      await waitForIt(
        () => io.out.toString().contains('bang-ran-now'),
        reason: 'the bang command runs immediately, mid-run',
      );
      expect(cli.isBusy, isTrue, reason: 'the run keeps streaming');

      // The model learns the user ran it: a system-notice steers into the
      // run and lands at the next turn boundary (a second stream call).
      stream.gate.complete();
      await waitForIt(() => stream.calls >= 2);
      final delivered = [
        for (final message in stream.contexts[1].messages)
          if (message is UserMessage) messageText(message),
      ].join('\n');
      expect(delivered, contains('<system-notice>'));
      expect(delivered, contains('echo bang-ran-now'));
      expect(delivered, contains('ran a local shell command'));

      await waitForIt(() => !cli.isBusy);
      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'an idle bang-command queues the notice for the next prompt',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final stream = _GatedStream([
        textTurn('answer with notice'),
      ], gateOnCall: 1);
      final cli = buildCli(stream, shellStdout: 'idle-ran\n');
      final run = cli.run();
      await waitForSessions(env);

      io.sendLine('!echo idle-ran');
      await waitForIt(
        () => io.out.toString().contains('idle-ran'),
        reason: 'the idle bang command runs immediately',
      );
      expect(stream.calls, 0, reason: 'a notice never wakes the agent');

      io.sendLine('what happened?');
      await waitForIt(() => stream.calls >= 1);
      final delivered = [
        for (final message in stream.contexts[0].messages)
          if (message is UserMessage) messageText(message),
      ].join('\n');
      expect(delivered, contains('echo idle-ran'));
      expect(delivered, contains('what happened?'));

      stream.gate.complete();
      await waitForIt(() => !cli.isBusy);
      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'an interrupt prints the steering messages it drops instead of '
    'discarding them silently',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final stream = _GatedStream([textTurn('first answer')], gateOnCall: 1);
      final cli = buildCli(stream);
      final run = cli.run();
      await waitForSessions(env);

      io.sendLine('start');
      await waitForIt(() => stream.calls >= 1 && cli.isBusy);
      io.sendLine('this must not vanish');
      io.interrupt();
      stream.gate.complete();
      await waitForIt(() => !cli.isBusy);

      expect(io.out.toString(), contains('dropped steering'));
      expect(io.out.toString(), contains('this must not vanish'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(
        stream.calls,
        1,
        reason: 'dropped steering must not start a new run',
      );

      io.sendLine('/exit');
      await run;
    },
  );
}

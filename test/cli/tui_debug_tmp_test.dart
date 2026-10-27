import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

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
  String get plain => text
      .replaceAll(RegExp('\u001B\\][^\u0007]*\u0007'), '')
      .replaceAll(RegExp('\u001B\\[[0-9;?]*[A-Za-z]'), '');
}

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
    contexts.add(Context(
      systemPrompt: context.systemPrompt,
      messages: List.of(context.messages),
      tools: context.tools,
    ));
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
      stream.push(ErrorEvent(
        reason: StopReason.aborted,
        error: testAssistant(
          stopReason: StopReason.aborted,
          errorMessage: 'Operation aborted',
        ),
      ));
      stream.end();
    });
    return stream;
  }
}

void main() {
  test('debug tui cancel', timeout: const Timeout(Duration(minutes: 2)), () async {
    final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
    final io = FakeCliIO();
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final seed = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await seed.appendSessionName('tui-cancel');
    for (var i = 0; i < 10; i++) {
      await seed.appendMessage(UserMessage.text('old$i ${'a' * 4000}'));
    }
    final firstKept = await seed.appendMessage(UserMessage.text('kept0 ${'a' * 4000}'));
    await seed.appendCompaction(
      summary: 'earlier marathon context',
      firstKeptEntryId: firstKept,
      tokensBefore: 99999,
    );
    for (var i = 1; i < 115; i++) {
      await seed.appendMessage(UserMessage.text('kept$i ${'a' * 4000}'));
    }
    final frames = _FrameSink();
    final keys = StreamController<List<int>>();
    final stream = _CancelObservingStream([
      textTurn('resumed context summary'),
      textTurn('spare'),
    ], hangFromCall: 1);
    const bigModel = Model(
      id: 'test-model',
      api: 'test-api',
      provider: 'test-provider',
      baseUrl: 'https://example.test',
      contextWindow: 131072,
      maxTokens: 4096,
    );
    final cli = AgentCli(
      config: AgentCliConfig(
        model: bigModel,
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
    await waitForIt(() => io.out.toString().contains('compaction deferred'));
    await waitForIt(() => frames.text.contains('\x1b[?1049h'));

    final submit = cli.tuiSubmitForTest('ZR9Q rescue me', const []);
    await waitForIt(() => stream.calls >= 1);
    keys.add([0x1B]);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    // ignore: avoid_print
    print('SUBMIT_DONE=${await submit.isEmpty ? false : true}');
    // ignore: avoid_print
    print('IO_OUT_HAS_NOTE=${io.out.toString().contains('submission cancelled')}');
    // ignore: avoid_print
    print('FRAMES_HAS_NOTE=${frames.plain.contains('submission cancelled')}');
    // ignore: avoid_print
    print('FRAMES_HAS_ZR9Q=${frames.plain.contains('ZR9Q rescue me')}');
    // ignore: avoid_print
    print('IO_OUT_TAIL=${io.out.toString().substring(io.out.toString().length > 400 ? io.out.toString().length - 400 : 0)}');
    // ignore: avoid_print
    print('FRAMES_TAIL=${frames.plain.substring(frames.plain.length > 500 ? frames.plain.length - 500 : 0)}');
    keys.add([0x03]);
    keys.add([0x03]);
    try {
      await run;
    } on Object catch (e) {
      // ignore: avoid_print
      print('RUN_ERROR=$e');
    }
    await io.close();
  });
}

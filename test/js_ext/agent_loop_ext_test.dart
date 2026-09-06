// Agent-loop-level extension tests (issue #32): a JS tool (parity fixture
// through host + FakeJsrRuntime) inside a REAL agent loop with a fake model
// stream. Covers AC3b (afterToolCall append reaches the model next step),
// AC2 (exec-tier JS tools pass the approval gate's prompt path), AC9
// (two extensions keep bridge state fully separate), and AC10 (the bridge
// method set is closed and never carries key values).
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/js_ext/ext_protocol.dart';
import 'package:flutter_agent_harness/src/js_ext/extension_host.dart';
import 'package:flutter_agent_harness/src/js_ext/extension_store.dart';
import 'package:flutter_agent_harness/src/js_ext/jsr_runtime.dart';
import 'package:test/test.dart';

import 'fixtures/parity_ext/parity_contract.dart';
import 'helpers/parity_harness.dart';
import 'helpers/scripted_env.dart';

const _model = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

AssistantMessage _assistantMsg({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
}) => AssistantMessage(
  content: content,
  api: 'test-api',
  provider: 'test-provider',
  model: 'test-model',
  usage: Usage.zero,
  stopReason: stopReason,
  timestamp: DateTime.utc(2026),
);

/// A scripted turn ending with tool calls.
List<AssistantMessageEvent> _toolTurn(List<ToolCall> calls) {
  final empty = _assistantMsg();
  final partial = _assistantMsg(content: calls, stopReason: StopReason.toolUse);
  final events = <AssistantMessageEvent>[StartEvent(partial: empty)];
  for (var i = 0; i < calls.length; i++) {
    events
      ..add(ToolCallStartEvent(contentIndex: i, partial: empty))
      ..add(
        ToolCallEndEvent(contentIndex: i, toolCall: calls[i], partial: partial),
      );
  }
  events.add(DoneEvent(reason: StopReason.toolUse, message: partial));
  return events;
}

/// A scripted plain-text turn.
List<AssistantMessageEvent> _textTurn(String text) {
  final empty = _assistantMsg();
  final partial = _assistantMsg(content: [TextContent(text: text)]);
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

/// Fake [StreamFunction]: replays scripted turns, records every context it
/// was called with.
class _FakeStreamFunction {
  _FakeStreamFunction(this.turns);

  final List<List<AssistantMessageEvent>> turns;
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
    for (final event in turns.removeAt(0)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

String _messageText(Message message) => message is ToolResultMessage
    ? message.content.whereType<TextContent>().map((b) => b.text).join('\n')
    : '';

void main() {
  test(
    'AC3b: the afterToolCall append reaches the model in the next request',
    () async {
      final runtime = FakeJsrRuntime('fake');
      installParityGlobals(runtime);
      final (_, _, host) = await installParityHost(
        runtimeFactory: () => runtime,
      );
      final fake = _FakeStreamFunction([
        _toolTurn([
          ToolCall(id: 't1', name: 'parity_echo', arguments: {'text': 'ping'}),
        ]),
        _textTurn('done'),
      ]);
      final agent = Agent(
        model: _model,
        streamFunction: fake.call,
        toolRegistry: ToolRegistry(host.tools),
      );
      host.attachHooks(agent);

      await agent.promptMessages([UserMessage.text('go')]);

      expect(fake.calls, 2, reason: 'tool turn + text turn');
      final secondRequest = fake.contexts[1];
      final echoResults = secondRequest.messages
          .whereType<ToolResultMessage>()
          .where((m) => m.toolName == 'parity_echo')
          .toList();
      expect(echoResults, hasLength(1));
      final text = _messageText(echoResults.single);
      // The model sees the fixture's result AND the appended hook text.
      expect(text, contains(parityEchoText(engineId: 'fake', text: 'ping')));
      expect(text, contains(kParityAppend));
      await host.dispose();
    },
  );

  test(
    'AC2: exec-tier JS tool goes through the approval gate prompt path',
    () async {
      final shell = ScriptedShell([
        const ShellExecResult(
          stdout: kParityExecStdout,
          stderr: '',
          exitCode: 0,
        ),
      ]);
      final runtime = FakeJsrRuntime('fake');
      installParityGlobals(runtime);
      final (_, _, host) = await installParityHost(
        runtimeFactory: () => runtime,
        shell: shell,
      );
      final prompts = <ApprovalRequest>[];
      final approval = ApprovalManager(
        mode: ApprovalMode.write,
        prompt: (request) {
          prompts.add(request);
          return ApprovalDecision.approveOnce;
        },
      );
      final fake = _FakeStreamFunction([
        _toolTurn([
          ToolCall(id: 't1', name: 'parity_exec', arguments: const {}),
        ]),
        _textTurn('executed'),
      ]);
      final agent = Agent(
        model: _model,
        streamFunction: fake.call,
        toolRegistry: ToolRegistry(host.tools),
      );
      // Order matters: approval first, JS hooks outermost (host wiring rule).
      attachApproval(agent, approval);
      host.attachHooks(agent);

      await agent.promptMessages([UserMessage.text('run it')]);

      expect(prompts, hasLength(1));
      expect(prompts.single.toolName, 'parity_exec');
      expect(prompts.single.tier, ApprovalTier.exec);
      expect(prompts.single.arguments, const {});
      // The approved call actually executed through the exec bridge.
      expect(shell.commands, [kParityExecCommand]);
      await host.dispose();
    },
  );

  test('AC9: two extensions keep bridge state fully separate', () async {
    Future<({JsExtensionHost host, FakeJsrRuntime runtime, List<String> notes})>
    isolatedExt(String name, String projectDir, String dataFirstLine) async {
      final env = ScriptedShellEnv(cwd: projectDir);
      (await env.writeFile(
        '$projectDir/parity_data.txt',
        '$dataFirstLine\nsecond\n',
      )).getOrThrow();
      final store = ExtensionStore(
        env: env,
        projectDir: projectDir,
        userDir: '$projectDir-home',
      );
      final files = parityFixtureFiles(name: name);
      await store.write(name, files: files, trust: parityTrustRecord(files));
      final runtime = FakeJsrRuntime('fake');
      installParityGlobals(runtime);
      final notes = <String>[];
      final host = JsExtensionHost(
        env: env,
        store: store,
        runtimeFactory: (_) => runtime,
        bootstrapJs: parityBootstrapJs,
      )..onAppendNote = notes.add;
      final report = await host.loadAll();
      expect(report.loaded, [name]);
      return (host: host, runtime: runtime, notes: notes);
    }

    final a = await isolatedExt('parity-a', '/projA', 'A-first-line');
    final b = await isolatedExt('parity-b', '/projB', 'B-first-line');
    final bBaseline = b.runtime.invokeCount;

    // Extension A's tool reads A's own fs and never wakes B's engine.
    final tool = a.host.tools.singleWhere((t) => t.name == 'parity_echo');
    final result = await tool.execute({'text': 'x'}, null, null);
    expect(resultText(result), contains('file=A-first-line'));
    expect(b.runtime.invokeCount, bBaseline, reason: 'B engine untouched');
    expect(b.runtime.lastMainJs, isNotNull, reason: 'B loaded independently');

    // Session state is per-extension too: A's note never lands in B.
    await a.host.sessionStart();
    expect(a.notes, [parityNote('onSessionStart')]);
    expect(b.notes, isEmpty);
    await a.host.dispose();
    await b.host.dispose();
  });

  test('AC10: the bridge method set is closed and value-free', () {
    // Exactly the documented closed set.
    expect(ExtBridgeMethods.all, {
      ExtBridgeMethods.registerTool,
      ExtBridgeMethods.registerHook,
      ExtBridgeMethods.registerSlash,
      ExtBridgeMethods.registerFlow,
      ExtBridgeMethods.sessionAppendNote,
      ExtBridgeMethods.sessionEnqueueFollowUp,
      ExtBridgeMethods.fsReadFile,
      ExtBridgeMethods.execRun,
      ExtBridgeMethods.ioWrite,
      ExtBridgeMethods.ioWriteln,
      ExtBridgeMethods.keysRequest,
      ExtBridgeMethods.has,
    });
    // keys.request exists — and nothing else even smells like a key value.
    expect(ExtBridgeMethods.all, contains('keys.request'));
    final keyish = ExtBridgeMethods.all.where((m) => m.contains('key'));
    expect(keyish, ['keys.request']);
    final valueish = ExtBridgeMethods.all.where(
      (m) => RegExp(r'get|secret|value|retrieve|read.?key').hasMatch(m),
    );
    expect(valueish, isEmpty);
  });
}

// Shared fakes and helpers for the agent_cli test suite.
import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const testModel = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

/// A catalog-backed cloud model, for the banner's key-status line.
const testCloudModel = Model(
  id: 'claude-sonnet-4-5',
  api: 'anthropic-messages',
  provider: 'anthropic',
  baseUrl: 'https://api.anthropic.com',
  contextWindow: 200000,
  maxTokens: 8192,
);

/// A model on a custom endpoint: the provider flips to `openai` (see
/// `buildCliDefaultModel`) while the key lookup stays by provider kind.
const testCustomEndpointModel = Model(
  id: 'local-model',
  api: 'openai-completions',
  provider: 'openai',
  baseUrl: 'http://127.0.0.1:8932',
  contextWindow: 100000,
  maxTokens: 4096,
);

AssistantMessage testAssistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
  String? errorMessage,
  Usage? usage,
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: usage ?? Usage.zero,
    stopReason: stopReason,
    errorMessage: errorMessage,
    timestamp: DateTime.utc(2026),
  );
}

List<AssistantMessageEvent> textTurn(String text, {Usage? usage}) {
  final empty = testAssistant();
  final partial = testAssistant(
    content: [TextContent(text: text)],
    usage: usage,
  );
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

List<AssistantMessageEvent> toolTurn(List<ToolCall> calls) {
  final empty = testAssistant();
  final partial = testAssistant(content: calls, stopReason: StopReason.toolUse);
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

/// Scripted [StreamFunction] replaying pre-recorded turns.
class FakeStreamFunction {
  FakeStreamFunction(this.turns);

  final List<List<AssistantMessageEvent>> turns;
  final contexts = <Context>[];
  final models = <Model>[];

  int get calls => contexts.length;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    models.add(model);
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

/// A [StreamFunction] turn that hangs until cancelled, then reports aborted.
class AbortableStreamFunction {
  var started = false;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    started = true;
    final stream = AssistantMessageEventStream();
    stream.push(StartEvent(partial: testAssistant()));
    cancelToken?.onCancel.then((_) {
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

/// A [Shell] that blocks until [release] completes the gate.
class GatedShell implements Shell {
  final _gate = Completer<void>();

  void release() => _gate.complete();

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    await _gate.future;
    return const Ok(ShellExecResult(stdout: '', stderr: '', exitCode: 0));
  }
}

/// A [Shell] that echoes the command and returns canned output.
class FakeShell implements Shell {
  FakeShell({this.stdout = '', this.stderr = '', this.exitCode = 0});

  final String stdout;
  final String stderr;
  final int exitCode;
  final commands = <String>[];
  ShellExecOptions? lastOptions;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    commands.add(command);
    lastOptions = options;
    return Ok(
      ShellExecResult(stdout: stdout, stderr: stderr, exitCode: exitCode),
    );
  }
}

/// In-memory [CliIO]: scripted input lines, captured output.
class FakeCliIO implements CliIO {
  @override
  int columns = 80;

  @override
  int rows = 24;

  final _lines = StreamController<String>();
  final _interrupts = StreamController<void>.broadcast();
  final _keys = StreamController<KeyEvent>.broadcast();
  final out = StringBuffer();

  /// Tests flip this to exercise the non-interactive approval path.
  @override
  bool isInteractive = true;

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Stream<void> get interrupts => _interrupts.stream;

  @override
  Stream<KeyEvent> get keys => _keys.stream;

  @override
  bool get supportsRawMode => true;

  @override
  void write(String text) => out.write(text);

  @override
  void writeln(String text) => out.write('$text\n');

  void sendLine(String line) => _lines.add(line);

  void sendKey(KeyEvent key) => _keys.add(key);

  void interrupt() => _interrupts.add(null);

  Future<void> close() async {
    // The close future only completes once a listener received the done
    // event; tests that never ran the CLI have no listener, so don't await.
    unawaited(_lines.close());
    unawaited(_keys.close());
    await _interrupts.close();
  }
}

/// In-memory [SecureKeyStore] with a toggleable availability flag.
class FakeSecureKeyStore implements SecureKeyStore {
  FakeSecureKeyStore({this.available = true});

  bool available;
  bool failWrites = false;
  final map = <String, String>{};

  @override
  String get label => 'fake store';

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<String?> read(String name) async => map[name];

  @override
  Future<void> write(String name, String value) async {
    if (failWrites) throw StateError('keychain write failed (exit 45)');
    map[name] = value;
  }

  @override
  Future<void> delete(String name) async => map.remove(name);
}

Future<void> waitForIt(bool Function() condition, {String? reason}) async {
  for (var i = 0; i < 400; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: ${reason ?? 'condition'}');
}

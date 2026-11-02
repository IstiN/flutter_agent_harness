@TestOn('vm')
library;

/// SCRATCH DEBUG — do not commit. Mirrors the AC2 fixture with pass-level
/// tracing to find why the resumed run ends with no assistant message.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/task/child_session_io.dart';
import 'package:test/test.dart';

final _model = Model(
  id: 'child-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 4300 + _contractTokens,
  maxTokens: 4096,
);

final int _contractTokens = () {
  final mgr = SubagentManager(parentSessionId: 'p', maxReplyChars: 8000);
  final descriptions = [
    for (final tool in subagentMonitoringTools(
      manager: mgr,
      currentSubagentId: () => null,
    ))
      if (tool.name == 'reply' || tool.name == 'agent_message')
        tool.description,
  ];
  final contract = deliverableChunkContract(8000).length;
  const gh1956BaselineChars = 2339;
  final footprintChars =
      contract + descriptions.fold<int>(0, (a, d) => a + d.length);
  return 237 + ((footprintChars - gh1956BaselineChars) / 4).ceil();
}();

final _fakeTime = DateTime.utc(2026, 9, 15, 12, 0, 0);

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
  String? errorMessage,
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: stopReason,
    errorMessage: errorMessage,
    timestamp: DateTime.utc(2026),
  );
}

List<AssistantMessageEvent> _textTurn(String text) {
  final empty = _assistant();
  final partial = _assistant(content: [TextContent(text: text)]);
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

List<AssistantMessageEvent> _toolTurn(String toolName, String callId) {
  final empty = _assistant();
  final call = ToolCall(id: callId, name: toolName, arguments: const {});
  final partial = _assistant(content: [call], stopReason: StopReason.toolUse);
  return [
    StartEvent(partial: empty),
    ToolCallStartEvent(contentIndex: 0, partial: empty),
    ToolCallEndEvent(contentIndex: 0, toolCall: call, partial: empty),
    DoneEvent(reason: StopReason.toolUse, message: partial),
  ];
}

typedef _Rule = ({String match, List<List<AssistantMessageEvent>> turns});

final class _ScriptedStream {
  _ScriptedStream([List<_Rule> rules = const []]) : rules = List.of(rules);

  final List<_Rule> rules;
  final contexts = <Context>[];
  int compactionCalls = 0;
  final passLog = <String>[];

  int get calls => contexts.length;

  int requestTokens(Context context) => estimateRequestTokens(
    context.messages,
    systemPrompt: context.systemPrompt,
    tools: context.tools ?? const [],
  );

  static String lastUserText(Context context) {
    for (final message in context.messages.reversed) {
      if (message is UserMessage) {
        final content = message.content;
        if (content is String) return content;
        if (content is List<ContentBlock>) {
          return content.whereType<TextContent>().map((b) => b.text).join('\n');
        }
      }
    }
    return '';
  }

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final system = context.systemPrompt ?? '';
    if (system.contains('context-hygiene judge')) {
      compactionCalls++;
      final seqs = RegExp(r'^\[(\d+)\]', multiLine: true)
          .allMatches(lastUserText(context))
          .map((m) => int.parse(m.group(1)!))
          .toList();
      passLog.add('judge: picks=$seqs');
      return _streamOf(_textTurn(jsonEncode(seqs)));
    }
    if (system.contains('context checkpoint assistant')) {
      compactionCalls++;
      passLog.add('checkpoint call');
      return _streamOf(_textTurn('checkpoint: earlier work summarized'));
    }
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
    final text = lastUserText(context);
    passLog.add(
      'request #${contexts.length}: tokens=${requestTokens(context)} '
      'lastUser="${text.length > 60 ? text.substring(0, 60) : text}" '
      'messages=${context.messages.map((m) => m.runtimeType).toList()}',
    );
    for (final rule in rules) {
      if (text.contains(rule.match) && rule.turns.isNotEmpty) {
        final events = rule.turns.removeAt(0);
        return _streamOf(events);
      }
    }
    return _streamOf(_textTurn('done'));
  }

  static AssistantMessageEventStream _streamOf(
    List<AssistantMessageEvent> events,
  ) {
    final stream = AssistantMessageEventStream();
    for (final event in events) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

AgentTool _fatTool(String name, int payloadChars) {
  return AgentTool(
    name: name,
    description: '$name tool',
    tier: ApprovalTier.read,
    execute: (arguments, cancelToken, onUpdate) async =>
        ToolExecutionResult.text('r${'x' * payloadChars}'),
  );
}

final class _Wiring {
  _Wiring({
    List<_Rule> rules = const [],
    List<AgentTool>? childTools,
    int payloadChars = 2400,
  }) {
    stream = _ScriptedStream(rules);
    manager = SubagentManager(
      parentSessionId: 'parent-session',
      clock: () => _fakeTime,
    )..mailboxPrefix = 'parent-session';
    final registry = TaskAgentRegistry([
      const TaskAgentDefinition(
        name: 'worker',
        description: 'tiny worker',
        systemPrompt: 'w',
      ),
    ]);
    executor = TaskExecutor(
      childTools: childTools ?? [_fatTool('read', payloadChars)],
      streamFunction: () => stream.call,
      model: () => _model,
      registry: registry,
      semaphore: Semaphore(4),
      store: AgentOutputStore(),
      subagentManager: manager,
      childSessionFactory: (parentId, childId) => repo.create(
        JsonlSessionCreateOptions(
          cwd: '/work',
          metadata: {
            'agent': 'subagent',
            'id': childId,
            'parent': parentId,
            'model': _model.id,
          },
        ),
      ),
      childSessionOpener: jsonlChildSessionOpener(env),
    );
  }

  final env = MemoryExecutionEnv(cwd: '/work');
  late final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  late final _ScriptedStream stream;
  late final SubagentManager manager;
  late final TaskExecutor executor;

  Future<TaskSingleResult> spawn(
    String name,
    String taskMarker, {
    String agent = 'worker',
  }) {
    return executor.runSpawn(
      item: TaskItem(name: name, agent: agent, task: taskMarker),
      index: 0,
      context: '',
    );
  }

  Future<void> settle(String id) async {
    final placeholder = '${manager.parentSessionId}/$id';
    for (var i = 0; i < 1000; i++) {
      if (manager[id]!.sessionId != placeholder) return;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    fail('child session for "$id" never attached');
  }

  List<AgentTool> monitoringTools() => subagentMonitoringTools(
    manager: manager,
    readMessages: jsonlChildMessageReader(env),
    resumeChild: executor.resumeChild,
  );

  AgentTool tool(String name) =>
      monitoringTools().firstWhere((t) => t.name == name);

  Future<String> execute(String toolName, Map<String, dynamic> args) async {
    final result = await tool(toolName).execute(args, null, null);
    return result.content.whereType<TextContent>().map((b) => b.text).join();
  }
}

void main() {
  test('DEBUG at-wall scenario', () async {
    // ignore: avoid_print
    print('window=${_model.contextWindow} '
        'trigger=${_model.contextWindow - 1024}');
    final w = _Wiring(
      payloadChars: 2820,
      rules: [
        (
          match: 'fill',
          turns: [
            _toolTurn('read', 'c1'),
            _toolTurn('read', 'c2'),
            _toolTurn('read', 'c3'),
            _textTurn('filled'),
          ],
        ),
      ],
    );
    final result = await w.spawn('filled_child', 'fill the context');
    // ignore: avoid_print
    print('spawn: ${result.status} err=${result.error}');
    await w.settle('filled_child');
    final handle = w.manager['filled_child']!;
    // ignore: avoid_print
    print('compactions=${handle.compactions}');
    // ignore: avoid_print
    print('--- stream log after spawn:');
    for (final line in w.stream.passLog) {
      // ignore: avoid_print
      print('  $line');
    }
    w.stream.passLog.clear();
    final sendResult = await w.execute('task_send', {
      'id': 'filled_child',
      'message': 'follow-up: ${'y' * 4000}',
    });
    // ignore: avoid_print
    print('sendResult: $sendResult');
    // ignore: avoid_print
    print('--- stream log after send:');
    for (final line in w.stream.passLog) {
      // ignore: avoid_print
      print('  $line');
    }
    // ignore: avoid_print
    print('status=${handle.status} compactions=${handle.compactions} '
        'compactionError=${handle.compactionError}');
    // Dump the child's persisted records.
    final path = handle.sessionId;
    final storage = await JsonlSessionStorage.open(w.env, path);
    final entries = await storage.getEntries();
    for (final e in entries) {
      // ignore: avoid_print
      print('record: ${e.runtimeType} '
          'id=${e.id} '
          '${e is CompactCheckpointRecord ? 'covers=${e.coversRecordIds} ' : ''}'
          '${e is HiddenRangeRecord ? 'hidden=${e.recordIds} ' : ''}');
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}

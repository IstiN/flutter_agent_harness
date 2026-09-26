// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Issue #958: background subagents finish, but the parent orchestrator
/// (the app host) sat idle until the user pinged — `task_observe` showed
/// both children done. The CLI always re-entered settled jobs; the app
/// never wired `TaskJobManager.completions`. These tests pin the app
/// contract on the real config-built service:
///
/// - idle: a settled background child starts a fresh turn carrying the
///   async-result notice (`<task-result id=... status=...>`), no user ping;
/// - mid-run: a child settling under a busy parent is delivered at the
///   next step boundary (steered).

import 'dart:async';

import 'package:fa/services/agent_service.dart';
import 'package:fa_ui/fa_ui.dart' show FaChatMessage;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

const _testModel = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

String _userText(List<FaChatMessage> messages) {
  for (final message in messages.reversed) {
    if (message.role == 'user') return message.content;
  }
  return '';
}

bool _hasUserText(List<FaChatMessage> messages, Pattern needle) =>
    messages.any((m) => m.role == 'user' && m.content.contains(needle));

bool _hasAssistantText(List<FaChatMessage> messages, String text) =>
    messages.any((m) => m.role == 'assistant' && m.content == text);

String _lastUserOf(List<Message> messages) {
  for (final message in messages.reversed) {
    if (message is UserMessage) {
      final content = message.content;
      if (content is String) return content;
      if (content is List<ContentBlock>) {
        return [
          for (final block in content)
            if (block is TextContent) block.text,
        ].join('\n');
      }
    }
  }
  return '';
}

AssistantMessage _assistant(String text, {StopReason reason = StopReason.stop}) =>
    AssistantMessage(
      content: [TextContent(text: text)],
      api: _testModel.api,
      provider: _testModel.provider,
      model: _testModel.id,
      usage: Usage.zero,
      stopReason: reason,
      timestamp: DateTime.now(),
    );

/// A complete text turn as events.
List<AssistantMessageEvent> _textEvents(String text) {
  final empty = AssistantMessage(
    content: const [],
    api: _testModel.api,
    provider: _testModel.provider,
    model: _testModel.id,
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.now(),
  );
  final partial = _assistant(text);
  return [
    StartEvent(partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

/// The events of one tool-call turn.
List<AssistantMessageEvent> _toolTurnEvents(List<ToolCall> calls) {
  final empty = AssistantMessage(
    content: const [],
    api: _testModel.api,
    provider: _testModel.provider,
    model: _testModel.id,
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.now(),
  );
  final partial = AssistantMessage(
    content: calls,
    api: _testModel.api,
    provider: _testModel.provider,
    model: _testModel.id,
    usage: Usage.zero,
    stopReason: StopReason.toolUse,
    timestamp: DateTime.now(),
  );
  final events = <AssistantMessageEvent>[StartEvent(partial: empty)];
  for (var i = 0; i < calls.length; i++) {
    events
      ..add(ToolCallStartEvent(contentIndex: i, partial: empty))
      ..add(ToolCallEndEvent(contentIndex: i, toolCall: calls[i], partial: partial));
  }
  events.add(DoneEvent(reason: StopReason.toolUse, message: partial));
  return events;
}

/// Routes every run by its last user message: the child assignment replays
/// a delayed text turn (the job doing timed work, then settling —
/// [childDone] completes then); the async-result notice replays the wake
/// reply; the parent spawn turn replays [spawnTurns] in order. The wake
/// branch wins over the child markers — the notice QUOTES the child's
/// task text.
StreamFunction _router({
  required List<String> childMarkers,
  required List<List<AssistantMessageEvent>> spawnTurns,
  Completer<void>? childDone,
  Duration childDelay = const Duration(milliseconds: 120),
  String wakeText = 'results acknowledged',
}) {
  final queue = List.of(spawnTurns);
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final lastUser = _lastUserOf(context.messages);
    if (lastUser.contains('<task-result')) {
      for (final event in _textEvents(wakeText)) {
        stream.push(event);
      }
      stream.end();
      return stream;
    }
    for (final marker in childMarkers) {
      if (lastUser.contains(marker)) {
        stream.push(StartEvent(partial: _assistant('')));
        unawaited(
          Future<void>.delayed(childDelay, () {
            for (final event in _textEvents('findings for $marker')) {
              stream.push(event);
            }
            stream.end();
            childDone?.complete();
          }),
        );
        return stream;
      }
    }
    final events = queue.isNotEmpty
        ? queue.removeAt(0)
        : _textEvents('noted.');
    for (final event in events) {
      stream.push(event);
    }
    stream.end();
    return stream;
  };
}

ToolCall _backgroundSpawn(List<String> names) => ToolCall(
  id: 't1',
  name: 'task',
  arguments: {
    'context': 'ctx',
    'background': true,
    'tasks': [
      for (final name in names)
        {'name': name, 'agent': 'task', 'task': 'TASKMARK-$name do work'},
    ],
  },
);

/// A [Shell] whose exec parks on the gate: the parent mid-turn wedge.
class _GatedShell implements Shell {
  final _gate = Completer<void>();

  void release() => _gate.complete();

  bool get isPending => !_gate.isCompleted;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    await _gate.future;
    return const Ok(ShellExecResult(stdout: '', stderr: '', exitCode: 0));
  }
}

Future<void> _waitFor(
  bool Function() condition, {
  String reason = 'condition',
  Duration budget = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(budget);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('timed out waiting: $reason');
}

Future<AgentService> _service(
  StreamFunction stream, {
  Shell? shell,
}) => AgentService.create(
  config: AgentConfig(
    providerKind: 'openai-completions',
    modelId: 'test-model',
    baseUrl: 'https://example.test',
    apiKey: 'test-key',
  ),
  // The config-built boot is what the real app runs: it registers the task
  // tool and arms the completions subscription under test (issue #958).
  env: shell == null
      ? MemoryExecutionEnv(cwd: '/work')
      : MemoryExecutionEnv(cwd: '/work', shell: shell),
  streamFunction: stream,
);

void main() {
  test(
    'a settled background child re-enters the idle parent as a fresh turn '
    '(issue #958 repro)',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      final childDone = Completer<void>();
      final stream = _router(
        childMarkers: const ['TASKMARK-alpha'],
        childDone: childDone,
        spawnTurns: [
          _toolTurnEvents([_backgroundSpawn(['alpha'])]),
        ],
      );
      final service = await _service(stream);
      addTearDown(service.dispose);
      service.setApprovalMode(ApprovalMode.yolo);

      await service.sendText('spawn alpha in the background');
      await service.waitForIdle();

      // NO user ping. The child settled while the parent idled; the
      // settlement must re-enter as a fresh turn: the notice lands as a
      // user message, the scripted wake reply follows it.
      await _waitFor(
        () => _hasUserText(service.messages, '<task-result') &&
            _hasUserText(service.messages, 'alpha'),
        reason: 'the settled child re-enters as an async-result turn',
      );
      await _waitFor(
        () => _hasAssistantText(service.messages, 'results acknowledged'),
        reason: 'the re-entry turn reaches the model',
      );
      expect(
        _userText(service.messages),
        contains('finished with status: completed'),
        reason: 'the last user turn IS the notice, not the user ping',
      );
    },
  );

  test(
    'a child settling under a busy parent is delivered at the next step '
    'boundary (issue #958, mid-run)',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      final gate = _GatedShell();
      final childDone = Completer<void>();
      final stream = _router(
        childMarkers: const ['TASKMARK-gamma'],
        childDone: childDone,
        spawnTurns: [
          _toolTurnEvents([_backgroundSpawn(['gamma'])]),
          _toolTurnEvents([
            ToolCall(
              id: 't2',
              name: 'bash',
              arguments: const {'command': 'long-running step'},
            ),
          ]),
        ],
      );
      final service = await _service(stream, shell: gate);
      addTearDown(service.dispose);
      service.setApprovalMode(ApprovalMode.yolo);

      await service.sendText('spawn gamma then run the long step');
      await _waitFor(
        () => gate.isPending,
        reason: 'the parent parks mid-turn on the long tool call',
      );
      await childDone.future.timeout(const Duration(seconds: 10));

      // Releasing the gate ends the tool call; the boundary right after
      // must deliver the steered notice.
      gate.release();
      await _waitFor(
        () => _hasUserText(service.messages, '<task-result'),
        reason: 'the async-result is delivered at the next boundary',
      );
      await service.waitForIdle();
    },
  );
}

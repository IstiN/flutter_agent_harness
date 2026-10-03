// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1164 AC5 + AC3 (delivery half): a JS app error report re-enters the
/// authoring session — while idle, as a fresh `<system-notice>` turn the
/// model answers (the same re-entry background shell jobs use). The report
/// carries app id, surface, revision, message and stack head so the agent
/// fixes the named source instead of guessing blind (the calculator
/// incident's "I can't see the widget myself").
///
/// The live-run delivery (steer at the next step boundary) rides the same
/// `sendText` machinery — pinned by the shell-job steer test
/// (`agent_service_task_completion_wake_test.dart`) this file mirrors.
library;


import 'package:fa/apps/js_app_error_channel.dart';
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

bool _hasUserText(List<FaChatMessage> messages, Pattern needle) =>
    messages.any((m) => m.role == 'user' && m.content.contains(needle));

bool _hasAssistantText(List<FaChatMessage> messages, Pattern needle) =>
    messages.any((m) => m.role == 'assistant' && m.content.contains(needle));

AssistantMessage _assistant(String text) => AssistantMessage(
  content: [TextContent(text: text)],
  api: _testModel.api,
  provider: _testModel.provider,
  model: _testModel.id,
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.now(),
);

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

/// Echoes every turn: the user text back, so the test sees exactly what
/// reached the model.
StreamFunction _echo() => (model, context, {cancelToken}) {
  final stream = AssistantMessageEventStream();
  final lastUser = [
    for (final message in context.messages.reversed)
      if (message is UserMessage)
        ...(() sync* {
          final content = message.content;
          if (content is String) {
            yield content;
          } else if (content is List<ContentBlock>) {
            for (final block in content) {
              if (block is TextContent) yield block.text;
            }
          }
        })(),
  ].firstOrNull ?? '';
  for (final event in _textEvents('echo: $lastUser')) {
    stream.push(event);
  }
  stream.end();
  return stream;
};

void _report(
  String message, {
  String appId = 'calc',
  String revision = 'aaaa1111aaaa1111',
  String kind = 'showError',
}) {
  JsAppErrorChannel.instance.reportAppError(
    JsAppErrorEvent(kind: kind, message: message, stack: 'at tap (widget.js:42)'),
    appId: appId,
    surface: 'app',
    sourceRevision: revision,
  );
}

Future<AgentService> _service() => AgentService.create(
  config: AgentConfig(
    providerKind: 'openai-completions',
    modelId: 'test-model',
    baseUrl: 'https://example.test',
    apiKey: '[REDACTED:Sensitive Value]',
  ),
  env: MemoryExecutionEnv(cwd: '/work'),
  streamFunction: _echo(),
);

Future<void> _waitFor(
  bool Function() condition, {
  String reason = 'condition',
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('timed out waiting: $reason');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'an idle session turns a JS app error into a fresh system-notice turn',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      final service = await _service();
      addTearDown(service.dispose);
      service.setApprovalMode(ApprovalMode.yolo);

      _report('boom: x is not defined', appId: 'calc');
      await _waitFor(
        () => _hasUserText(service.messages, 'calc') &&
            _hasAssistantText(service.messages, 'echo: <system-notice>'),
        reason: 'the error notice re-enters as a fresh turn',
      );

      final notice = service.messages
          .where((m) => m.role == 'user')
          .map((m) => m.content)
          .firstWhere((c) => c.contains('<system-notice>'));
      expect(notice, contains("JS app 'calc' reported an error"));
      expect(notice, contains('boom: x is not defined'));
      expect(notice, contains('widget.js:42'));
      expect(notice, contains('surface: app'));
      expect(notice, contains('source revision aaaa1111'));
      expect(notice, contains('fix the failing range'));
      await service.waitForIdle();
    },
  );

  test(
    'the channel gate dedups before delivery — no notice spam',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      final service = await _service();
      addTearDown(service.dispose);
      service.setApprovalMode(ApprovalMode.yolo);

      // A DIFFERENT app id per test isolates the global gate's state.
      for (var i = 0; i < 25; i++) {
        _report(
          'same frame bug',
          appId: 'notes-dedup',
          revision: 'bbbb2222',
        );
      }
      await _waitFor(
        () => _hasUserText(service.messages, 'notes-dedup'),
        reason: 'the single report arrives',
      );
      await service.waitForIdle();

      final notices = service.messages
          .where((m) => m.role == 'user')
          .where((m) => m.content.contains('same frame bug'))
          .length;
      expect(notices, 1, reason: '25 identical events deliver once (AC4)');
    },
  );
}

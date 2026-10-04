// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1164 Part B (AC5 + anti-spam): a gated JS-app error notice re-enters
/// the bound session through the shared channel — a fresh system-notice
/// turn while idle (sendText steers mid-run the same way) — and the gate
/// guarantees exactly one notice per error per source revision.
library;

import 'package:fa/apps/js_app_error_channel.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa_ui/fa_ui.dart' show FaChatMessage;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

StreamFunction _always(String text) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final message = AssistantMessage(
      content: [TextContent(text: text)],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.now(),
    );
    stream.push(DoneEvent(reason: StopReason.stop, message: message));
    stream.end();
    return stream;
  };
}

bool _hasUserText(List<FaChatMessage> messages, Pattern needle) =>
    messages.any((m) => m.role == 'user' && m.content.contains(needle));

Future<void> _waitFor(
  bool Function() condition, {
  String reason = 'condition',
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('timed out waiting for: $reason');
}

void main() {
  test(
    'an idle session turns a JS app error into a fresh system-notice turn '
    '(AC5)',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      JsAppErrorChannel.instance.disposeAndReset();
      final service = await AgentService.create(
        config: AgentConfig(
          providerKind: 'test',
          modelId: 'test-model',
          baseUrl: 'https://example.com',
          apiKey: '',
        ),
        env: MemoryExecutionEnv(cwd: '/work'),
        streamFunction: _always('error noted'),
      );
      addTearDown(service.dispose);

      expect(service.messages, isEmpty);
      // What the engine publishes after the gate accepted a NEW report.
      final delivered = JsAppErrorChannel.instance.publish(
        JsAppErrorNotice(
          event: const JsAppErrorEvent(
            kind: JsAppErrorKind.showError,
            message: 'boom from the widget',
            stack: 'at widget.js:3:1',
          ),
          appId: 'calc',
          surface: 'app',
          sourceRevision: 'rev-1',
          notice:
              "App 'calc' (app) reported a showError error:\n"
              'boom from the widget',
        ),
      );
      expect(delivered, isTrue, reason: 'the service must be subscribed');

      await _waitFor(
        () => _hasUserText(service.messages, 'boom from the widget'),
        reason: 'the system notice re-enters the idle session',
      );
      await service.waitForIdle();
    },
  );

  test(
    'the channel gate dedups before delivery — 100 identical errors, '
    'exactly one notice (AC4/AC6)',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      JsAppErrorChannel.instance.disposeAndReset();
      final service = await AgentService.create(
        config: AgentConfig(
          providerKind: 'test',
          modelId: 'test-model',
          baseUrl: 'https://example.com',
          apiKey: '',
        ),
        env: MemoryExecutionEnv(cwd: '/work'),
        streamFunction: _always('error noted'),
      );
      addTearDown(service.dispose);
      await service.waitForIdle();
      final baseline = service.messages.length;

      const event = JsAppErrorEvent(
        kind: JsAppErrorKind.callback,
        message: 'frame blew up',
        stack: 'at widget.js:9:5',
      );
      // What the ENGINE does per captured error: gate, then publish only
      // when the gate says deliver. 100 identical bursts collapse here.
      var deliveredCount = 0;
      final sub = JsAppErrorChannel.instance.onDeliver.listen((_) {
        deliveredCount++;
      });
      for (var i = 0; i < 100; i++) {
        final feedback = JsAppErrorChannel.instance.reportAppError(
          event,
          appId: 'calc',
          surface: 'app',
          sourceRevision: 'rev-1',
        );
        if (feedback != null && feedback.deliver) {
          JsAppErrorChannel.instance.publish(
            JsAppErrorNotice(
              event: event,
              appId: 'calc',
              surface: 'app',
              sourceRevision: 'rev-1',
              notice: feedback.notice,
            ),
          );
        }
      }
      await pumpEventQueue();
      await sub.cancel();
      expect(deliveredCount, 1, reason: 'anti-spam by construction (AC4)');

      await service.waitForIdle();
      final notices = service.messages
          .where(
            (m) => m.role == 'user' && m.content.contains('frame blew up'),
          )
          .length;
      expect(
        notices,
        1,
        reason: 'exactly one system-notice turn despite 100 errors',
      );
      expect(service.messages.length, greaterThan(baseline));
    },
  );
}

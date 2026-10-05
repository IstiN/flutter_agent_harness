// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1164 Part B (AC5 + anti-spam): a gated JS-app error notice re-enters
/// the bound session through the shared channel — a fresh system-notice
/// turn while idle (sendText steers mid-run the same way) — and the gate
/// guarantees exactly one notice per error per source revision.
library;

import 'dart:io' show File;

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
          .where((m) => m.role == 'user' && m.content.contains('frame blew up'))
          .length;
      expect(
        notices,
        1,
        reason: 'exactly one system-notice turn despite 100 errors',
      );
      expect(service.messages.length, greaterThan(baseline));
    },
  );

  test(
    'a notice for a BOUND app reaches only the bound session '
    '(gh-1164 review thread 3)',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      JsAppErrorChannel.instance.disposeAndReset();
      // Production shape: all sessions share ONE env.
      final env = MemoryExecutionEnv(cwd: '/work');
      AgentConfig config() => AgentConfig(
        providerKind: 'test',
        modelId: 'test-model',
        baseUrl: 'https://example.com',
        apiKey: '',
      );
      final bound = await AgentService.create(
        config: config(),
        env: env,
        streamFunction: _always('bound session note'),
      );
      addTearDown(bound.dispose);
      final other = await AgentService.create(
        config: config(),
        env: env,
        streamFunction: _always('other session note'),
      );
      addTearDown(other.dispose);
      await bound.initialize();
      await other.initialize();
      final boundId = bound.currentSessionId!;
      expect(other.currentSessionId, isNot(boundId));

      // The app-open path maintains this binding on disk.
      await env.writeFile(
        'apps/calc/session.json',
        '{"sessionId":"$boundId"}',
      );

      JsAppErrorChannel.instance.publish(
        JsAppErrorNotice(
          event: const JsAppErrorEvent(
            kind: JsAppErrorKind.showError,
            message: 'routed boom',
            stack: 'at widget.js:3:1',
          ),
          appId: 'calc',
          surface: 'app',
          sourceRevision: 'rev-1',
          notice: "App 'calc' (app) reported a showError error:\nrouted boom",
        ),
      );

      await _waitFor(
        () => _hasUserText(bound.messages, 'routed boom'),
        reason: 'the BOUND session turns the notice into a system notice',
      );
      // Let the OTHER service's async routing decision settle: it must
      // drop the notice (not its app — not its turn).
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await other.waitForIdle();
      expect(
        _hasUserText(other.messages, 'routed boom'),
        isFalse,
        reason: 'an unbound session must never turn on another app error',
      );
      // The other session's own pipeline still works: an UNBOUND app's
      // notice falls back to delivery (never a silent drop everywhere).
      JsAppErrorChannel.instance.publish(
        JsAppErrorNotice(
          event: const JsAppErrorEvent(
            kind: JsAppErrorKind.showError,
            message: 'unbound boom',
            stack: 'at widget.js:3:1',
          ),
          appId: 'other-app',
          surface: 'app',
          sourceRevision: 'rev-1',
          notice:
              "App 'other-app' (app) reported a showError error:\nunbound boom",
        ),
      );
      await _waitFor(
        () => _hasUserText(other.messages, 'unbound boom'),
        reason: 'no binding → broadcast fallback still delivers',
      );
    },
  );

  test(
    'a disposed service unsubscribes the JS-app error channel '
    '(gh-1164 review: dispose teardown stays single-source in the '
    'lifecycle part)',
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
        streamFunction: _always('disposed session note'),
      );
      await service.initialize();
      final sessionId = service.currentSessionId!;
      service.dispose();

      // Unbound app → routing fallback would deliver HERE if the
      // disposed service were still subscribed. It must be silent.
      JsAppErrorChannel.instance.publish(
        JsAppErrorNotice(
          event: const JsAppErrorEvent(
            kind: JsAppErrorKind.showError,
            message: 'post-dispose boom',
            stack: 'at widget.js:3:1',
          ),
          appId: 'post-dispose-app',
          surface: 'app',
          sourceRevision: 'rev-1',
          notice:
              "App 'post-dispose-app' (app) reported a showError error:\n"
              'post-dispose boom',
        ),
      );
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
        _hasUserText(service.messages, 'post-dispose boom'),
        isFalse,
        reason:
            'dispose() must cancel the channel subscription '
            '($sessionId is gone)',
      );
    },
  );

  group('gh-1164 review: dispose teardown stays single-source', () {
    // The bad merge of origin/main (687d0bce) inlined the lifecycle
    // teardown into AgentService.dispose() and left the part-file
    // _disposeService() dead code (flutter analyze: unused_element).
    // These guards pin main's structure so the two copies can never
    // silently diverge again (repo convention: source-structure tests,
    // cf. retired_seed_frozen_test.dart).
    String source(String path) =>
        File('lib/services/$path').readAsStringSync();

    String disposeBody() {
      final text = source('agent_service.dart');
      final start = text.indexOf('  void dispose() {');
      expect(start, isNonNegative, reason: 'AgentService.dispose not found');
      final end = text.indexOf('\n  }', start);
      return text.substring(start, end);
    }

    test('dispose() delegates to the lifecycle part, not an inline copy', () {
      final body = disposeBody();
      expect(
        body,
        contains('_disposeService();'),
        reason:
            'the bad-merge cleanup must not inline the teardown body — '
            'main has dispose() delegate to _disposeService() so the '
            'part file stays the single source',
      );
      expect(
        body,
        isNot(contains('_agent.abort()')),
        reason: 'teardown members must live in agent_service_lifecycle.dart',
      );
      expect(
        body,
        isNot(contains('_jsAppErrorSub')),
        reason:
            'the jsAppError subscription cancel belongs to the shared '
            'teardown, not a second copy in agent_service.dart',
      );
    });

    test('_disposeService() owns the full teardown incl. the channel sub', () {
      final lifecycle = source('agent_service_lifecycle.dart');
      final start = lifecycle.indexOf('  void _disposeService() {');
      expect(start, isNonNegative, reason: '_disposeService not found');
      final end = lifecycle.indexOf('\n  }', start);
      final body = lifecycle.substring(start, end);
      expect(body, contains('unawaited(_jsAppErrorSub?.cancel());'));
      expect(body, contains('_agent.abort();'));
      expect(body, contains('dynamicMessages.dispose();'));
    });
  });
}

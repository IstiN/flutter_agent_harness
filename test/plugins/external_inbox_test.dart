import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('ExternalInbox', () {
    test('registered inboxes are collected in order', () {
      final context = PluginContext(
        env: MemoryExecutionEnv(),
        io: _FakePluginIO(),
      );
      context
        ..registerExternalInbox(ExternalInbox(drain: _emptyDrain))
        ..registerExternalInbox(
          ExternalInbox(drain: _emptyDrain, hasPending: () async => true),
        );

      expect(context.externalInboxes, hasLength(2));
      expect(context.externalInboxes.first.hasPending, isNull);
      expect(context.externalInboxes.last.hasPending, isNotNull);
    });

    test('the collected list is unmodifiable', () {
      final context = PluginContext(
        env: MemoryExecutionEnv(),
        io: _FakePluginIO(),
      );

      expect(
        () => context.externalInboxes.add(ExternalInbox(drain: _emptyDrain)),
        throwsUnsupportedError,
      );
    });
  });
}

Future<List<AgentMessage>> _emptyDrain() async => const [];

class _FakePluginIO implements PluginIO {
  @override
  void write(String text) {}

  @override
  void writeln(String text) {}
}

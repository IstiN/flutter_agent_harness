@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter_agent_harness/src/a2a/a2a_client.dart';
import 'package:flutter_agent_harness/src/a2a/a2a_config.dart';
import 'package:flutter_agent_harness/src/a2a/a2a_manager.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

/// A mock http backend serving a card, a send response, and scripted
/// tasks/get responses (worked → completed).
http.Client _mockA2aBackend(List<String> taskGetStates) {
  var getCount = 0;
  return http_testing.MockClient((request) async {
    if (request.url.path.endsWith('/.well-known/agent.json')) {
      return http.Response(
        '{"name":"translator","description":"t","url":"https://x.example.com"}',
        200,
      );
    }
    final body = request.body;
    if (body.contains('"message/send"')) {
      return http.Response(
        '{"jsonrpc":"2.0","id":1,"result":{"id":"task-1",'
        '"status":{"state":"working"}}}',
        200,
      );
    }
    if (body.contains('"tasks/get"')) {
      final state =
          taskGetStates[getCount < taskGetStates.length
              ? getCount++
              : taskGetStates.length - 1];
      final completed = state == 'completed'
          ? ',"artifacts":[{"parts":[{"type":"text","text":"done!"}]}]'
          : '';
      return http.Response(
        '{"jsonrpc":"2.0","id":1,"result":{"id":"task-1",'
        '"status":{"state":"$state"}$completed}}',
        200,
      );
    }
    return http.Response('not found', 404);
  });
}

A2aManager _managerWith(List<String> taskGetStates) {
  final backend = _mockA2aBackend(taskGetStates);
  return A2aManager(
    A2aConfig(
      servers: {
        'remote': const A2aServerConfig(
          name: 'remote',
          url: 'https://x.example.com',
        ),
      },
    ),
    clientFactory: (config) =>
        A2aClient(baseUrl: config.url, token: config.token, client: backend),
  );
}

void main() {
  group('A2aManager with a mock backend', () {
    test('connect fetches the card and marks connected', () async {
      final manager = _managerWith(['completed']);
      final client = await manager.connect('remote');
      expect(client, isNotNull);
      final server = manager['remote']!;
      expect(server.status, A2aServerConnectionStatus.connected);
      expect(server.card?.name, 'translator');
    });

    test('connect failure marks failed with the error', () async {
      final failing = http_testing.MockClient((_) async {
        return http.Response('boom', 500);
      });
      final manager = A2aManager(
        A2aConfig(
          servers: {
            'bad': const A2aServerConfig(
              name: 'bad',
              url: 'https://x.example.com',
            ),
          },
        ),
        clientFactory: (config) =>
            A2aClient(baseUrl: config.url, client: failing),
      );
      expect(() => manager.connect('bad'), throwsA(anything));
      await Future<void>.delayed(Duration.zero);
      expect(manager['bad']!.status, A2aServerConnectionStatus.failed);
      expect(manager['bad']!.error, isNotNull);
    });

    test('send + waitForTask settles on completed with artifacts', () async {
      final manager = _managerWith(['working', 'completed']);
      final task = await manager.send('remote', 'do it');
      expect(task.state, A2aTaskState.working);
      final settled = await manager.waitForTask(
        'remote',
        task.id,
        pollInterval: Duration.zero,
      );
      expect(settled.state, A2aTaskState.completed);
      expect(A2aManager.renderArtifacts(settled), contains('done!'));
    });

    test('waitForTask settles early on input-required', () async {
      final manager = _managerWith(['working', 'input-required']);
      final task = await manager.send('remote', 'do it');
      final settled = await manager.waitForTask(
        'remote',
        task.id,
        pollInterval: Duration.zero,
      );
      expect(settled.state, A2aTaskState.inputRequired);
    });

    test('waitForTask times out on never-settling tasks', () async {
      final manager = _managerWith([
        'working',
        'working',
        'working',
        'working',
      ]);
      final task = await manager.send('remote', 'do it');
      expect(
        () => manager.waitForTask(
          'remote',
          task.id,
          timeout: Duration.zero,
          pollInterval: Duration.zero,
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('cancel calls tasks/cancel', () async {
      var cancelCalled = false;
      final backend = http_testing.MockClient((request) async {
        if (request.url.path.endsWith('/.well-known/agent.json')) {
          return http.Response(
            '{"name":"t","url":"https://x.example.com"}',
            200,
          );
        }
        if (request.body.contains('"tasks/cancel"')) {
          cancelCalled = true;
          return http.Response(
            '{"jsonrpc":"2.0","id":1,"result":{"id":"task-1",'
            '"status":{"state":"canceled"}}}',
            200,
          );
        }
        return http.Response(
          '{"jsonrpc":"2.0","id":1,"result":{"id":"task-1",'
          '"status":{"state":"working"}}}',
          200,
        );
      });
      final manager = A2aManager(
        A2aConfig(
          servers: {
            'remote': const A2aServerConfig(
              name: 'remote',
              url: 'https://x.example.com',
            ),
          },
        ),
        clientFactory: (config) =>
            A2aClient(baseUrl: config.url, client: backend),
      );
      await manager.cancel('remote', 'task-1');
      expect(cancelCalled, isTrue);
    });
  });
}

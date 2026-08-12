@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter_agent_harness/src/a2a/a2a_client.dart';
import 'package:flutter_agent_harness/src/a2a/a2a_server.dart';
import 'package:test/test.dart';

void main() {
  group('A2aRequestHandler', () {
    test('agentCardJson produces a valid card', () {
      final handler = A2aRequestHandler(
        runner: (_) async => 'ok',
        agentName: 'test-agent',
        agentDescription: 'A test agent',
        skills: [AgentSkill(id: 's1', name: 'Skill 1')],
      );
      final card = jsonDecode(handler.agentCardJson()) as Map<String, dynamic>;
      expect(card['name'], 'test-agent');
      expect(card['capabilities']['inputModes'], ['text']);
      expect(card['skills'], hasLength(1));
    });

    test('message/send runs the agent and returns completed task', () async {
      final handler = A2aRequestHandler(
        runner: (msg) async => 'echo: $msg',
        agentName: 'echo',
        agentDescription: 'Echo agent',
      );
      final response = await handler.handle(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'message/send',
          'params': {
            'message': {
              'role': 'user',
              'parts': [
                {'type': 'text', 'text': 'hello'},
              ],
            },
          },
          'id': 1,
        }),
      );
      final decoded = jsonDecode(response) as Map<String, dynamic>;
      expect(decoded['result']['status']['state'], 'completed');
      expect(decoded['result']['messages'], hasLength(2));
      expect(decoded['result']['messages'][1]['role'], 'agent');
      expect(
        decoded['result']['messages'][1]['parts'][0]['text'],
        'echo: hello',
      );
    });

    test('tasks/get returns the stored task', () async {
      final handler = A2aRequestHandler(
        runner: (_) async => 'done',
        agentName: 'a',
        agentDescription: 'd',
      );
      await handler.handle(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'message/send',
          'id': 1,
          'params': {
            'message': {
              'role': 'user',
              'parts': [
                {'type': 'text', 'text': 'hi'},
              ],
            },
          },
        }),
      );
      final response = await handler.handle(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'tasks/get',
          'id': 2,
          'params': {'taskId': 'task-1'},
        }),
      );
      final decoded = jsonDecode(response) as Map<String, dynamic>;
      expect(decoded['result']['id'], 'task-1');
      expect(decoded['result']['status']['state'], 'completed');
    });

    test('tasks/cancel sets state to canceled', () async {
      final handler = A2aRequestHandler(
        runner: (_) async => 'ok',
        agentName: 'a',
        agentDescription: 'd',
      );
      await handler.handle(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'message/send',
          'id': 1,
          'params': {
            'message': {
              'role': 'user',
              'parts': [
                {'type': 'text', 'text': 'hi'},
              ],
            },
          },
        }),
      );
      final response = await handler.handle(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'tasks/cancel',
          'id': 2,
          'params': {'taskId': 'task-1'},
        }),
      );
      final decoded = jsonDecode(response) as Map<String, dynamic>;
      expect(decoded['result']['status']['state'], 'canceled');
    });

    test('unknown method returns error', () async {
      final handler = A2aRequestHandler(
        runner: (_) async => 'ok',
        agentName: 'a',
        agentDescription: 'd',
      );
      final response = await handler.handle(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'bogus',
          'id': 1,
          'params': {},
        }),
      );
      final decoded = jsonDecode(response) as Map<String, dynamic>;
      expect(decoded['error'], isNotNull);
      expect(decoded['error']['message'], contains('unknown method'));
    });

    test('auth: wrong token rejects with -32001', () async {
      final handler = A2aRequestHandler(
        runner: (_) async => 'ok',
        agentName: 'a',
        agentDescription: 'd',
        token: 'secret',
      );
      final response = await handler.handle(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'message/send',
          'id': 1,
          'params': {},
        }),
        authHeader: 'Bearer wrong',
      );
      final decoded = jsonDecode(response) as Map<String, dynamic>;
      expect(decoded['error']['code'], -32001);
    });

    test('auth: correct token allows', () async {
      final handler = A2aRequestHandler(
        runner: (_) async => 'ok',
        agentName: 'a',
        agentDescription: 'd',
        token: 'secret',
      );
      final response = await handler.handle(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'message/send',
          'id': 1,
          'params': {
            'message': {
              'role': 'user',
              'parts': [
                {'type': 'text', 'text': 'hi'},
              ],
            },
          },
        }),
        authHeader: 'Bearer secret',
      );
      final decoded = jsonDecode(response) as Map<String, dynamic>;
      expect(decoded['result'], isNotNull);
    });
  });
}

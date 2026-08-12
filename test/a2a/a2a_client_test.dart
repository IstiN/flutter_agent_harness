@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter_agent_harness/src/a2a/a2a_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

void main() {
  group('AgentCard', () {
    test('parses a well-formed card', () {
      final card = AgentCard.fromJson({
        'name': 'translator',
        'description': 'Translates text',
        'url': 'https://agents.example.com/translator',
        'version': '1.0.0',
        'capabilities': {
          'inputModes': ['text', 'image'],
        },
        'skills': [
          {
            'id': 'translate',
            'name': 'Translate',
            'description': 'Any language',
          },
        ],
        'authentication': {
          'schemes': ['bearer'],
        },
      });
      expect(card.name, 'translator');
      expect(card.url, 'https://agents.example.com/translator');
      expect(card.modalities, contains('image'));
      expect(card.skills, hasLength(1));
      expect(card.skills.first.id, 'translate');
      expect(card.authSchemes, isNotEmpty);
    });

    test('handles missing fields gracefully', () {
      final card = AgentCard.fromJson({});
      expect(card.name, 'unknown');
      expect(card.description, '');
      expect(card.skills, isEmpty);
    });
  });

  group('A2aTask', () {
    test('parses a completed task with messages and artifacts', () {
      final task = A2aTask.fromJson({
        'id': 'task-1',
        'status': {'state': 'completed'},
        'messages': [
          {
            'role': 'user',
            'parts': [
              {'type': 'text', 'text': 'hello'},
            ],
          },
          {
            'role': 'agent',
            'parts': [
              {'type': 'text', 'text': 'hi there'},
            ],
          },
        ],
        'artifacts': [
          {
            'parts': [
              {'type': 'text', 'text': 'result text'},
            ],
          },
        ],
      });
      expect(task.id, 'task-1');
      expect(task.state, A2aTaskState.completed);
      expect(task.messages, hasLength(2));
      expect(task.messages.last.textContent, 'hi there');
      expect(task.artifacts.first.textContent, 'result text');
    });

    test('parses input-required state', () {
      final task = A2aTask.fromJson({
        'id': 't2',
        'status': {'state': 'input-required'},
      });
      expect(task.state, A2aTaskState.inputRequired);
    });
  });

  group('A2aClient', () {
    test('card fetches and caches the Agent Card', () async {
      var fetchCount = 0;
      final client = http_testing.MockClient((request) async {
        fetchCount++;
        return http.Response(
          jsonEncode({
            'name': 'test-agent',
            'description': 'A test agent',
            'url': 'https://a.test',
          }),
          200,
        );
      });
      final a2a = A2aClient(baseUrl: 'https://a.test', client: client);
      final card1 = await a2a.card;
      final card2 = await a2a.card;
      expect(card1.name, 'test-agent');
      expect(fetchCount, 1); // cached
      a2a.close();
    });

    test('sendMessage returns a task', () async {
      final client = http_testing.MockClient((request) async {
        expect(request.url.toString(), 'https://a.test');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['method'], 'message/send');
        return http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'result': {
              'id': 'task-abc',
              'status': {'state': 'completed'},
              'messages': [
                {
                  'role': 'agent',
                  'parts': [
                    {'type': 'text', 'text': 'done'},
                  ],
                },
              ],
            },
          }),
          200,
        );
      });
      final a2a = A2aClient(baseUrl: 'https://a.test', client: client);
      final task = await a2a.sendMessage('hello');
      expect(task.id, 'task-abc');
      expect(task.state, A2aTaskState.completed);
      expect(task.messages.first.textContent, 'done');
      a2a.close();
    });

    test('cancelTask sends cancel and returns canceled task', () async {
      final client = http_testing.MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['method'], 'tasks/cancel');
        expect(body['params']['taskId'], 't1');
        return http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'result': {
              'id': 't1',
              'status': {'state': 'canceled'},
            },
          }),
          200,
        );
      });
      final a2a = A2aClient(baseUrl: 'https://a.test', client: client);
      final task = await a2a.cancelTask('t1');
      expect(task.state, A2aTaskState.canceled);
      a2a.close();
    });

    test('error response throws A2aException', () async {
      final client = http_testing.MockClient((request) async {
        return http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'error': {'code': -32600, 'message': 'bad request'},
          }),
          200,
        );
      });
      final a2a = A2aClient(baseUrl: 'https://a.test', client: client);
      expect(() => a2a.sendMessage('hi'), throwsA(isA<A2aException>()));
      a2a.close();
    });

    test('bearer token is sent in authorization header', () async {
      String? authHeader;
      final client = http_testing.MockClient((request) async {
        authHeader = request.headers['authorization'];
        return http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'result': {
              'id': 't',
              'status': {'state': 'completed'},
            },
          }),
          200,
        );
      });
      final a2a = A2aClient(
        baseUrl: 'https://a.test',
        token: 'my-token',
        client: client,
      );
      await a2a.sendMessage('hi');
      expect(authHeader, 'Bearer my-token');
      a2a.close();
    });
  });
}

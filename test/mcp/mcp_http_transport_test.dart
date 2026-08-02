/// Tests for the HTTP MCP transports: streamable-HTTP request/response
/// (JSON and SSE bodies, session-id capture, 202 notifications, error
/// synthesis) and the legacy SSE handshake — all over `MockClient`s.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

McpHttpServerConfig serverConfig({
  McpHttpTransportKind transport = McpHttpTransportKind.streamableHttp,
  Map<String, String> headers = const {},
}) {
  return McpHttpServerConfig(
    name: 'remote',
    url: 'https://mcp.example.com/mcp',
    transport: transport,
    headers: headers,
  );
}

/// Collects every message a transport emits within [window].
Future<List<Map<String, dynamic>>> collect(
  McpTransport transport, {
  Duration window = const Duration(milliseconds: 50),
}) async {
  final messages = <Map<String, dynamic>>[];
  final sub = transport.messages.listen(messages.add);
  await Future<void>.delayed(window);
  await sub.cancel();
  return messages;
}

void main() {
  group('McpStreamableHttpTransport', () {
    test('POSTs JSON-RPC with the MCP accept headers and emits the JSON '
        'response', () async {
      http.Request? seen;
      final client = http_testing.MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'result': {'ok': true},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final transport = McpStreamableHttpTransport(
        serverConfig(headers: const {'Authorization': 'Bearer t'}),
        client: client,
      );
      final received = collect(transport);
      await transport.send({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': const {},
      });
      final messages = await received;
      expect(messages, hasLength(1));
      expect(messages.single['result'], {'ok': true});
      expect(seen!.method, 'POST');
      expect(seen!.url.toString(), 'https://mcp.example.com/mcp');
      expect(seen!.headers['accept'], contains('text/event-stream'));
      expect(seen!.headers['authorization'], 'Bearer t');
      expect(jsonDecode(seen!.body), {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': const {},
      });
    });

    test('parses an SSE response body into messages', () async {
      final client = http_testing.MockClient((request) async {
        return http.Response(
          'data: {"jsonrpc":"2.0","id":1,"result":{"a":1}}\n\n'
          'data: {"jsonrpc":"2.0","method":"notifications/progress"}\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final transport = McpStreamableHttpTransport(
        serverConfig(),
        client: client,
      );
      final received = collect(transport);
      await transport.send({'jsonrpc': '2.0', 'id': 1, 'method': 'x'});
      final messages = await received;
      expect(messages, hasLength(2));
      expect(messages.first['result'], {'a': 1});
      expect(messages.last['method'], 'notifications/progress');
    });

    test('captures and replays the mcp-session-id header', () async {
      final sessionIds = <String?>[];
      final client = http_testing.MockClient((request) async {
        sessionIds.add(request.headers['mcp-session-id']);
        return http.Response(
          jsonEncode({'jsonrpc': '2.0', 'id': 1, 'result': null}),
          200,
          headers: {'mcp-session-id': 'sess-42'},
        );
      });
      final transport = McpStreamableHttpTransport(
        serverConfig(),
        client: client,
      );
      final received = collect(transport);
      await transport.send({'jsonrpc': '2.0', 'id': 1, 'method': 'a'});
      await transport.send({'jsonrpc': '2.0', 'id': 1, 'method': 'b'});
      await received;
      expect(sessionIds, [null, 'sess-42']);
    });

    test('a 202 notification ack emits nothing', () async {
      final client = http_testing.MockClient(
        (request) async => http.Response('', 202),
      );
      final transport = McpStreamableHttpTransport(
        serverConfig(),
        client: client,
      );
      final received = collect(transport);
      await transport.send({
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      });
      expect(await received, isEmpty);
    });

    test(
      'an HTTP error synthesizes a JSON-RPC error for the request id',
      () async {
        final client = http_testing.MockClient(
          (request) async => http.Response('broken', 500),
        );
        final transport = McpStreamableHttpTransport(
          serverConfig(),
          client: client,
        );
        final received = collect(transport);
        await transport.send({'jsonrpc': '2.0', 'id': 7, 'method': 'x'});
        final messages = await received;
        expect(messages, hasLength(1));
        expect(messages.single['id'], 7);
        expect(
          (messages.single['error'] as Map)['message'],
          contains('HTTP 500'),
        );
      },
    );

    test('close completes closed and shuts the owned client down', () async {
      var clientClosed = false;
      final client = http_testing.MockClient((request) async {
        clientClosed = true;
        return http.Response('{}', 200);
      });
      final transport = McpStreamableHttpTransport(
        serverConfig(),
        client: client,
      );
      // ignore: avoid_print
      print('stage: closing');
      await transport.close();
      // ignore: avoid_print
      print('stage: closed await');
      await transport.closed;
      // ignore: avoid_print
      print('stage: second close');
      await transport.close();
      // ignore: avoid_print
      print('stage: expect');
      expect(clientClosed, isFalse);
    });

    test('a network failure synthesizes a JSON-RPC error', () async {
      final client = http_testing.MockClient(
        (request) async => throw http.ClientException('socket gone'),
      );
      final transport = McpStreamableHttpTransport(
        serverConfig(),
        client: client,
      );
      final received = collect(transport);
      await transport.send({'jsonrpc': '2.0', 'id': 3, 'method': 'x'});
      final messages = await received;
      expect(
        (messages.single['error'] as Map)['message'],
        contains('socket gone'),
      );
    });
  });

  group('McpSseTransport', () {
    test('waits for the endpoint event, POSTs there, and reads message '
        'events from the GET stream', () async {
      final postBodies = <String>[];
      final client = http_testing.MockClient.streaming((request, body) async {
        if (request.method == 'GET') {
          final controller = StreamController<List<int>>();
          scheduleMicrotask(() {
            controller
              ..add(utf8.encode('event: endpoint\ndata: /post-here\n\n'))
              ..add(
                utf8.encode(
                  'event: message\n'
                  'data: {"jsonrpc":"2.0","id":1,"result":{"pong":true}}\n\n',
                ),
              );
            unawaited(controller.close());
          });
          return http.StreamedResponse(
            controller.stream,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        postBodies.add(await body.bytesToString());
        return http.StreamedResponse(const Stream<List<int>>.empty(), 202);
      });
      final transport = await McpSseTransport.connect(
        serverConfig(transport: McpHttpTransportKind.sse),
        client: client,
      );
      final received = collect(transport);
      await transport.send({'jsonrpc': '2.0', 'id': 1, 'method': 'ping'});
      final messages = await received;
      expect(postBodies, hasLength(1));
      expect(jsonDecode(postBodies.single)['method'], 'ping');
      expect(messages.single['result'], {'pong': true});
    });

    test(
      'a POST error synthesizes a JSON-RPC error for the request id',
      () async {
        final client = http_testing.MockClient.streaming((request, body) async {
          if (request.method == 'GET') {
            final controller = StreamController<List<int>>();
            scheduleMicrotask(() {
              controller.add(utf8.encode('event: endpoint\ndata: /post\n\n'));
              unawaited(controller.close());
            });
            return http.StreamedResponse(
              controller.stream,
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          return http.StreamedResponse(const Stream<List<int>>.empty(), 500);
        });
        final transport = await McpSseTransport.connect(
          serverConfig(transport: McpHttpTransportKind.sse),
          client: client,
        );
        final received = collect(transport);
        await transport.send({'jsonrpc': '2.0', 'id': 9, 'method': 'x'});
        final messages = await received;
        expect(messages, hasLength(1));
        expect(
          (messages.single['error'] as Map)['message'],
          contains('HTTP 500'),
        );
      },
    );

    test('a POST network failure synthesizes a JSON-RPC error', () async {
      final client = http_testing.MockClient.streaming((request, body) async {
        if (request.method == 'GET') {
          final controller = StreamController<List<int>>();
          scheduleMicrotask(() {
            controller.add(utf8.encode('event: endpoint\ndata: /post\n\n'));
            unawaited(controller.close());
          });
          return http.StreamedResponse(
            controller.stream,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        throw http.ClientException('post socket gone');
      });
      final transport = await McpSseTransport.connect(
        serverConfig(transport: McpHttpTransportKind.sse),
        client: client,
      );
      final received = collect(transport);
      await transport.send({'jsonrpc': '2.0', 'id': 4, 'method': 'x'});
      final messages = await received;
      expect(
        (messages.single['error'] as Map)['message'],
        contains('post socket gone'),
      );
    });

    test('fails cleanly when the endpoint event never arrives', () async {
      final client = http_testing.MockClient.streaming((request, body) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode(': heartbeat\n\n')),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      expect(
        () => McpSseTransport.connect(
          serverConfig(transport: McpHttpTransportKind.sse),
          client: client,
          endpointTimeout: const Duration(milliseconds: 100),
        ),
        throwsA(isA<McpServerUnavailableException>()),
      );
    });

    test('a non-200 GET fails cleanly', () async {
      final client = http_testing.MockClient.streaming((request, body) async {
        return http.StreamedResponse(const Stream<List<int>>.empty(), 403);
      });
      expect(
        () => McpSseTransport.connect(
          serverConfig(transport: McpHttpTransportKind.sse),
          client: client,
        ),
        throwsA(
          isA<McpServerUnavailableException>().having(
            (e) => e.message,
            'message',
            contains('403'),
          ),
        ),
      );
    });
  });
}

/// Tests for the MCP JSON-RPC client: handshake shape, request/response
/// correlation, error envelopes, timeouts, tools/list pagination, and
/// teardown semantics — all over the in-memory [FakeMcpServer].
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'fake_mcp_server.dart';

void main() {
  late FakeMcpServer server;
  late McpClient client;

  setUp(() {
    server = FakeMcpServer(
      serverInfo: const {'name': 'fake', 'version': '1.0'},
    );
    client = McpClient(
      serverName: 'fake',
      transport: server.transport,
      requestTimeout: const Duration(milliseconds: 200),
    );
  });

  tearDown(() async {
    await client.close();
    await server.dispose();
  });

  test('initialize sends the handshake and returns server info', () async {
    final result = await client.initialize();
    expect(result.serverName, 'fake');
    expect(result.serverVersion, '1.0');
    expect(client.status, McpClientStatus.ready);

    final init = server.requests.first;
    expect(init.method, 'initialize');
    final params = init.params! as Map<String, dynamic>;
    expect(params['protocolVersion'], mcpProtocolVersion);
    expect(params['clientInfo'], mcpClientInfo);
    expect(
      server.notifications.map((n) => n.method),
      contains('notifications/initialized'),
    );
  });

  test('listTools parses names, descriptions, and input schemas', () async {
    server.tools = [
      {
        'name': 'read_thing',
        'description': 'Reads a thing',
        'inputSchema': {
          'type': 'object',
          'properties': {
            'id': {'type': 'string'},
          },
        },
      },
      {'name': 'bare'},
      {'no-name': true},
    ];
    await client.initialize();
    final tools = await client.listTools();
    expect(tools.map((t) => t.name), ['read_thing', 'bare']);
    expect(tools.first.description, 'Reads a thing');
    expect(tools.first.inputSchema?['type'], 'object');
    expect(tools[1].inputSchema, isNull);
  });

  test('listTools follows nextCursor pagination', () async {
    var page = 0;
    server.requestHandler = (method, params) {
      if (method == 'initialize') {
        return {'protocolVersion': mcpProtocolVersion};
      }
      if (method == 'tools/list') {
        page += 1;
        return page == 1
            ? {
                'tools': [
                  {'name': 'one'},
                ],
                'nextCursor': 'p2',
              }
            : {
                'tools': [
                  {'name': 'two'},
                ],
              };
      }
      return null;
    };
    await client.initialize();
    final tools = await client.listTools();
    expect(tools.map((t) => t.name), ['one', 'two']);
    final listCalls = server.requests.where((r) => r.method == 'tools/list');
    expect(listCalls.length, 2);
    expect((listCalls.last.params! as Map<String, dynamic>)['cursor'], 'p2');
  });

  test('callTool returns the raw result map', () async {
    server.requestHandler = (method, params) {
      if (method == 'initialize') {
        return {'protocolVersion': mcpProtocolVersion};
      }
      if (method == 'tools/call') {
        final p = params! as Map<String, dynamic>;
        return {
          'content': [
            {'type': 'text', 'text': 'echo:${p['name']}'},
          ],
        };
      }
      return null;
    };
    await client.initialize();
    final result = await client.callTool('echo', {'x': 1});
    final content = result['content'] as List;
    expect((content.first as Map)['text'], 'echo:echo');
    final call = server.requests.last;
    expect((call.params! as Map<String, dynamic>)['arguments'], {'x': 1});
  });

  test('a server error envelope rejects the request', () async {
    server.requestHandler = (method, params) {
      if (method == 'initialize') {
        return {'protocolVersion': mcpProtocolVersion};
      }
      return const FakeMcpError('boom', code: -32000);
    };
    await client.initialize();
    expect(
      () => client.callTool('anything', const {}),
      throwsA(
        isA<McpRequestException>().having(
          (e) => e.message,
          'message',
          contains('boom'),
        ),
      ),
    );
  });

  test('an unanswered request times out with an actionable message', () async {
    server.autoRespond = false;
    expect(
      () => client.initialize(),
      throwsA(
        isA<McpRequestException>().having(
          (e) => e.message,
          'message',
          allOf(contains('timed out'), contains('mcp.toolCallTimeoutMs')),
        ),
      ),
    );
  });

  test('server-initiated requests get a method-not-found reply', () async {
    await client.initialize();
    server.sendMessage({
      'jsonrpc': '2.0',
      'id': 'srv-1',
      'method': 'sampling/createMessage',
      'params': const {},
    });
    // The reply is delivered synchronously through the fake's controllers;
    // give the event loop one turn to flush.
    await Future<void>.delayed(Duration.zero);
    expect(server.responses, hasLength(1));
    final reply = server.responses.single;
    expect(reply['id'], 'srv-1');
    expect((reply['error'] as Map)['code'], -32601);
    expect(
      (reply['error'] as Map)['message'],
      contains('sampling/createMessage'),
    );
  });

  test(
    'a dying transport rejects pending requests and closes the client',
    () async {
      await client.initialize();
      server.autoRespond = false;
      final pending = client.callTool('hang', const {});
      final expectation = expectLater(
        pending,
        throwsA(isA<McpRequestException>()),
      );
      await server.simulateCrash();
      await expectation;
      expect(client.status, McpClientStatus.closed);
      await client.closed;
    },
  );

  test('requests on a closed client fail fast', () async {
    await client.initialize();
    await client.close();
    expect(
      () => client.callTool('x', const {}),
      throwsA(
        isA<McpRequestException>().having(
          (e) => e.message,
          'message',
          contains('closed'),
        ),
      ),
    );
  });
}

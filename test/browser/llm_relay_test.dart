// The relay transport (`relayOpenAiCompletion`): wire-call shape, SSE delta
// forwarding, tolerant chunk skipping, and loud failure paths — all over a
// `MockClient.streaming`, never the network.
@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

LlmRelayRequest _request([String baseUrl = 'https://api.z.ai/api/paas/v4']) =>
    LlmRelayRequest(
      baseUrl: baseUrl,
      model: 'glm-4.6',
      messages: [
        {'role': 'user', 'content': 'hi'},
      ],
    )..key = 'sk-test';

/// A 200 SSE response carrying [events] as `data:` frames.
http.Client _sseClient(String events) => http_testing.MockClient.streaming(
  (request, body) async =>
      http.StreamedResponse(Stream.value(utf8.encode(events)), 200),
);

String _chunk(Object? delta) =>
    'data: ${jsonEncode({
      'choices': [
        {'delta': delta},
      ],
    })}\n\n';

void main() {
  group('relayOpenAiCompletion', () {
    test('needs an injected key', () {
      expect(
        () => relayOpenAiCompletion(
          _request()..key = null,
          (_) {},
          client: _sseClient(''),
        ),
        throwsStateError,
      );
      expect(
        () => relayOpenAiCompletion(
          _request()..key = '',
          (_) {},
          client: _sseClient(''),
        ),
        throwsStateError,
      );
    });

    test('posts the streaming call to <baseUrl>/chat/completions', () async {
      http.BaseRequest? seen;
      String? body;
      final client = http_testing.MockClient.streaming((request, bodyStream) {
        seen = request;
        return bodyStream.bytesToString().then((b) {
          body = b;
          return http.StreamedResponse(Stream.value(utf8.encode('')), 200);
        });
      });
      final deltas = <String>[];
      await relayOpenAiCompletion(
        _request('https://api.z.ai/api/paas/v4/'),
        deltas.add,
        client: client,
      );
      expect(
        seen!.url.toString(),
        'https://api.z.ai/api/paas/v4/chat/completions',
      );
      expect(seen!.method, 'POST');
      expect(seen!.headers['authorization'], 'Bearer sk-test');
      expect(seen!.headers['content-type'], contains('application/json'));
      expect(jsonDecode(body!) as Map<String, dynamic>, {
        'model': 'glm-4.6',
        'messages': [
          {'role': 'user', 'content': 'hi'},
        ],
        'stream': true,
      });
      expect(deltas, isEmpty);
    });

    test('forwards content deltas until [DONE]', () async {
      final client = _sseClient(
        '${_chunk({'role': 'assistant'})}'
        '${_chunk({'content': 'Hel'})}'
        '${_chunk({'content': 'lo'})}'
        'data: [DONE]\n\n'
        '${_chunk({'content': 'never'})}',
      );
      final deltas = <String>[];
      await relayOpenAiCompletion(_request(), deltas.add, client: client);
      expect(deltas, ['Hel', 'lo']);
    });

    test(
      'skips keepalives and chunks it cannot trust, keeps streaming',
      () async {
        final client = _sseClient(
          ': ping\n\n'
          'data: not-json\n\n'
          'data: ["a", "list"]\n\n'
          'data: {}\n\n'
          'data: ${jsonEncode({'choices': []})}\n\n'
          '${_chunk({'tool_calls': []})}'
          '${_chunk({'content': 'ok'})}',
        );
        final deltas = <String>[];
        await relayOpenAiCompletion(_request(), deltas.add, client: client);
        expect(deltas, ['ok']);
      },
    );

    test('an HTTP error propagates as ProviderHttpError', () {
      final client = http_testing.MockClient(
        (request) async => http.Response('{"error": "nope"}', 401),
      );
      expect(
        relayOpenAiCompletion(_request(), (_) {}, client: client),
        throwsA(isA<ProviderHttpError>()),
      );
    });

    test('a network failure propagates', () {
      final client = http_testing.MockClient(
        (request) async => throw http.ClientException('socket gone'),
      );
      expect(
        relayOpenAiCompletion(_request(), (_) {}, client: client),
        throwsA(isA<http.ClientException>()),
      );
    });

    test('a mid-stream socket error propagates', () async {
      final controller = StreamController<List<int>>();
      final client = http_testing.MockClient.streaming((request, body) async {
        scheduleMicrotask(() {
          controller
            ..add(utf8.encode(_chunk({'content': 'partial'})))
            ..addError(http.ClientException('connection reset'))
            ..close();
        });
        return http.StreamedResponse(controller.stream, 200);
      });
      final deltas = <String>[];
      await expectLater(
        relayOpenAiCompletion(_request(), deltas.add, client: client),
        throwsA(isA<http.ClientException>()),
      );
      expect(deltas, ['partial']);
    });
  });
}

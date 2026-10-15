// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1624 IT — a bifrost-shaped translating proxy, end to end.
///
/// A loopback server plays bifrost: one host, an `/anthropic` path serving
/// the anthropic-messages dialect, "translating" a `vendor/model` id
/// (`zai/glm-5.3`) to its backend. The exact factory declaration that
/// exit-64'd on fa 1.0.576 (`FA_PROVIDER_TYPE=anthropic` + the proxy URL +
/// the zai-prefixed model) must BOOT — parse the `FA_PROVIDER_*`
/// preconfig, carry the prefix mismatch as a binding warning — and the
/// production stream factory (`providerStreamFunction('anthropic', …)`,
/// the same seam the boot pins) must complete a real request against it
/// over a socket. No external network; the server binds 127.0.0.1 on an
/// ephemeral port.
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// One request the fake bifrost captured.
final class _CapturedRequest {
  _CapturedRequest({
    required this.path,
    required this.apiKey,
    required this.bodyModel,
  });

  final String path;
  final String? apiKey;
  final String? bodyModel;
}

/// Anthropic-messages SSE frames answering one short text turn — the wire
/// shape a bifrost `/anthropic` path returns after translating.
const _translatedSse = '''
event: message_start
data: {"type":"message_start","message":{"id":"msg_bifrost","usage":{"input_tokens":10,"output_tokens":1}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"translated hello"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":10,"output_tokens":3}}

event: message_stop
data: {"type":"message_stop"}

''';

void main() {
  late HttpServer bifrost;
  final requests = <_CapturedRequest>[];

  setUp(() async {
    requests.clear();
    bifrost = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(
      bifrost.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        Object? bodyModel;
        try {
          bodyModel = (jsonDecode(body) as Map)['model'];
        } on FormatException {
          bodyModel = null;
        }
        requests.add(
          _CapturedRequest(
            path: request.uri.path,
            apiKey: request.headers.value('x-api-key'),
            bodyModel: bodyModel as String?,
          ),
        );
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.write(_translatedSse);
        await request.response.close();
      }).asFuture<void>(),
    );
  });
  tearDown(() async {
    await bifrost.close(force: true);
  });

  /// The factory declaration: `FA_PROVIDER_TYPE=anthropic` + the bifrost
  /// `/anthropic` path + the zai-prefixed model — the shape that exit-64'd
  /// on 1.0.576.
  EnvProviderPreconfig bootPreconfig({String? wire}) =>
      parseEnvProviderPreconfig(
        providerType: 'anthropic',
        providerName: null,
        providerConfig: jsonEncode({
          'baseUrl': 'http://127.0.0.1:${bifrost.port}/anthropic',
          'model': 'zai/glm-5.3',
          'apiKeyEnvVar': 'BIFROST_KEY',
          'wire': ?wire,
        }),
        providerConfigBase64: null,
        envVarValue: (name) => name == 'BIFROST_KEY' ? 'sk-bifrost' : null,
        takenNames: const [],
      )!;

  group('gh-1624 AC4 — bifrost-shaped translating proxy', () {
    test('the factory declaration boots with a binding warning (was exit '
        '64 on 1.0.576)', () {
      final pre = bootPreconfig();
      expect(pre.binding.providerKind, 'anthropic');
      expect(pre.baseUrl, 'http://127.0.0.1:${bifrost.port}/anthropic');
      expect(pre.binding.wireOverride, isFalse);
      expect(pre.binding.warnings, hasLength(1));
      expect(
        pre.binding.warnings.single,
        allOf(
          contains('zai/glm-5.3'),
          contains('http://127.0.0.1:${bifrost.port}/anthropic'),
          contains('routing key'),
        ),
      );
    });

    test('the pinned model completes a streamed request through the '
        'production anthropic adapter', () async {
      final pre = bootPreconfig();
      final stream =
          providerStreamFunction(pre.binding.providerKind, 'sk-bifrost')(
            Model(
              id: pre.modelId,
              name: 'zai/glm-5.3 (bifrost)',
              api: pre.spec.api,
              provider: pre.spec.name,
              baseUrl: pre.baseUrl,
              contextWindow: pre.spec.contextWindow,
              maxTokens: pre.spec.maxTokens,
            ),
            Context(messages: [UserMessage.text('Say hello in three words.')]),
          );

      final events = await stream.toList();
      final deltas = events.whereType<TextDeltaEvent>().toList();
      expect(deltas, isNotEmpty);
      expect(deltas.map((d) => d.delta).join(), 'translated hello');
      final done = events.last;
      expect(done, isA<DoneEvent>());
      expect((done as DoneEvent).reason, StopReason.stop);
      final message = await stream.result;
      expect(message.stopReason, StopReason.stop);

      // The proxy saw the anthropic wire on ITS path, keyed, carrying the
      // translated vendor/model id — the bifrost shape end to end.
      expect(requests, hasLength(1));
      expect(requests.single.path, '/anthropic/v1/messages');
      expect(requests.single.apiKey, 'sk-bifrost');
      expect(requests.single.bodyModel, 'zai/glm-5.3');
    });

    test('the equal-kind `wire:` caveat neither unblocks nor bricks — the '
        'checks run and the warning is still carried (gh-1624 AC3)', () {
      final pre = bootPreconfig(wire: 'anthropic');
      expect(pre.binding.wireOverride, isFalse);
      expect(pre.binding.warnings, hasLength(1));
    });
  });
}

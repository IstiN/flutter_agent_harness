// SEC-01 (security review 2026-09-22): the browser relay must never send a
// stored key to a client-chosen address.
//
// Trust boundary: a paired relay client chooses WHAT (provider id); the
// server alone decides WHERE (endpoint) and WITH WHAT (key). A
// client-supplied `baseUrl` is never an independent input to a keyed
// request — a named provider must byte-match its saved record BEFORE any
// network call, an unknown name is a named rejection, and the anonymous
// (unnamed) mode is relayed keyless: no stored key may ever attach to a
// client-chosen URL.
@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

const _recordZai = 'https://api.z.ai/api/paas/v4';
const _recordOr = 'https://openrouter.ai/api/v1';
const _attacker = 'https://attacker.example/v1';

/// The saved-provider table the server resolves against.
final List<CustomProviderEntry> _records = [
  CustomProviderEntry(
    name: 'zai',
    apiType: 'openai',
    baseUrl: _recordZai,
    modelId: 'glm-4.6',
    keyName: 'FA_KEY_SEC_ZAI',
  ),
  CustomProviderEntry(
    name: 'orai',
    apiType: 'openai',
    baseUrl: _recordOr,
    modelId: 'default',
    keyName: 'FA_KEY_SEC_OR',
  ),
  CustomProviderEntry(
    name: 'lanbox',
    apiType: 'openai',
    baseUrl: 'https://lan.example/v1',
    modelId: 'm',
  ),
];

/// A fake key pocket: the stored key per provider name.
String? _resolveKey(CustomProviderEntry entry) => switch (entry.name) {
  'zai' => 'sk-zai-secret',
  'orai' => 'sk-or-secret',
  _ => null,
};

/// The production-shaped resolver over [_records].
LlmRelayTarget? _resolver(LlmRelayRequest request) => resolveLlmRelayTarget(
  request,
  providers: _records,
  resolveKey: _resolveKey,
);

/// An HTTP client that records every outbound request; [responder]
/// overrides the default 200-empty-SSE answer (redirect fixtures).
final class _CountingClient extends http.BaseClient {
  _CountingClient([this.responder]);

  Future<http.StreamedResponse> Function(http.BaseRequest request)? responder;

  final requests = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final respond = responder;
    if (respond != null) return respond(request);
    return http.StreamedResponse(Stream.value(utf8.encode('')), 200);
  }
}

LlmRelayRequest _req(String baseUrl, {String? provider}) => LlmRelayRequest(
  baseUrl: baseUrl,
  model: 'glm-4.6',
  messages: [
    {'role': 'user', 'content': 'hi'},
  ],
  provider: provider,
);

BridgeFrame _llmReqFrame(LlmRelayRequest request) => BridgeFrame(
  id: 'f-1',
  op: BridgeOps.llmReq,
  fields: {
    'req': {
      'baseUrl': request.baseUrl,
      'model': request.model,
      'messages': request.messages,
      if (request.provider != null) 'provider': request.provider,
    },
  },
);

/// Runs one frame through [BridgeLlmRelay.handle] with the REAL transport
/// over [client]; returns the llmRes frames the client saw.
Future<List<BridgeFrame>> _handle(
  LlmRelayRequest request,
  http.Client client,
) async {
  final sent = <BridgeFrame>[];
  final glue = BridgeLlmRelay(
    relay: (relayRequest, onDelta) =>
        relayOpenAiCompletion(relayRequest, onDelta, client: client),
    resolveTarget: _resolver,
  );
  await glue.handle(_llmReqFrame(request), (frame) async => sent.add(frame));
  return sent;
}

void main() {
  group('resolveLlmRelayTarget — the SEC-01 server-side resolution', () {
    test('a named provider resolves endpoint AND key from the SAME record', () {
      final target = _resolver(_req(_recordZai, provider: 'zai'));
      expect(target, isNotNull);
      expect(target!.rejected, isFalse);
      expect(target.baseUrl, _recordZai);
      expect(target.key, 'sk-zai-secret');
    });

    test('a named provider with a client-chosen baseUrl is rejected', () {
      final target = _resolver(_req(_attacker, provider: 'zai'));
      expect(target!.rejected, isTrue);
      expect(target.error, contains('zai'));
    });

    test('an unknown provider name is a named rejection', () {
      final target = _resolver(_req(_recordZai, provider: 'ghost'));
      expect(target!.rejected, isTrue);
      expect(target.error, contains('ghost'));
    });

    test('an unnamed request resolves to null (anonymous, keyless)', () {
      expect(_resolver(_req(_attacker)), isNull);
    });

    test('a keyless record resolves with a null key (frame glue rejects)', () {
      final target = _resolver(
        _req('https://lan.example/v1', provider: 'lanbox'),
      );
      expect(target!.rejected, isFalse);
      expect(target.baseUrl, 'https://lan.example/v1');
      expect(target.key, isNull);
    });
  });

  group(
    'SEC-01 AC1 — a keyed request never goes to a client-chosen address',
    () {
      test('provider=X + baseUrl=attacker → zero outbound requests + named '
          'error', () async {
        final client = _CountingClient();
        final frames = await _handle(_req(_attacker, provider: 'zai'), client);
        expect(
          client.requests,
          isEmpty,
          reason: 'the rejection must happen BEFORE any network call',
        );
        expect(frames, hasLength(1));
        expect(frames.single.op, BridgeOps.llmRes);
        expect(frames.single.fields['error'], contains('zai'));
        expect(frames.single.fields['error'], contains('attacker.example'));
      });

      test('unknown provider → zero outbound requests + named error', () async {
        final client = _CountingClient();
        final frames = await _handle(
          _req(_recordZai, provider: 'ghost'),
          client,
        );
        expect(client.requests, isEmpty);
        expect(frames.single.fields['error'], contains('ghost'));
      });

      test('named provider without a stored key → zero outbound + no-key '
          'error', () async {
        final client = _CountingClient();
        final frames = await _handle(
          _req('https://lan.example/v1', provider: 'lanbox'),
          client,
        );
        expect(client.requests, isEmpty);
        expect(frames.single.fields['error'], contains('lanbox'));
        expect(frames.single.fields['error'], contains('no key'));
      });
    },
  );

  group('SEC-01 AC2 — a named provider request goes to the record', () {
    test(
      'the record baseUrl is used verbatim with the record key attached',
      () async {
        final client = _CountingClient();
        final frames = await _handle(_req(_recordZai, provider: 'zai'), client);
        expect(client.requests, hasLength(1));
        expect(
          client.requests.single.url.toString(),
          '$_recordZai/chat/completions',
        );
        expect(
          client.requests.single.headers['authorization'],
          'Bearer sk-zai-secret',
        );
        expect(frames.last.fields['done'], isTrue);
      },
    );

    test('a second named record resolves to ITS OWN endpoint', () async {
      final client = _CountingClient();
      await _handle(_req(_recordOr, provider: 'orai'), client);
      expect(
        client.requests.single.url.toString(),
        '$_recordOr/chat/completions',
      );
      expect(
        client.requests.single.headers['authorization'],
        'Bearer sk-or-secret',
      );
    });

    test(
      'the anonymous mode is relayed keyless — never a stored key',
      () async {
        final client = _CountingClient();
        // Anonymous requests to the record baseUrl AND to the attacker both
        // go out WITHOUT an Authorization header.
        for (final url in [_recordZai, _attacker]) {
          final frames = await _handle(_req(url), client);
          expect(frames.last.fields['done'], isTrue);
        }
        expect(client.requests, hasLength(2));
        expect(
          client.requests.map((r) => r.headers['authorization']),
          everyElement(isNull),
        );
      },
    );
  });

  group('SEC-01 AC3 — cross-origin redirect strips the relayed auth', () {
    test(
      'a 302 to another host fails; no request re-sent, no auth leaked',
      () async {
        final client = _CountingClient((request) async {
          if (request.url.toString() == '$_recordZai/chat/completions') {
            return http.StreamedResponse(
              Stream.value(utf8.encode('')),
              302,
              headers: {'location': '$_attacker/steal'},
            );
          }
          return http.StreamedResponse(Stream.value(utf8.encode('')), 200);
        });
        final frames = await _handle(_req(_recordZai, provider: 'zai'), client);
        // Exactly ONE request left: the original. The attacker host never
        // saw anything.
        expect(client.requests, hasLength(1));
        expect(frames.single.fields['error'], isNotNull);
      },
    );
  });

  group('REG (SEC-01 AC4) — no Bearer may leave to a non-record address', () {
    /// The whole relay surface as llmReq fixtures: every input a paired
    /// client could send, honest or malicious. Expected per fixture: how
    /// many requests may leave and whether an error frame must come back.
    final fixtures = <String, (LlmRelayRequest, int, bool)>{
      'named+record': (_req(_recordZai, provider: 'zai'), 1, false),
      'named+attacker': (_req(_attacker, provider: 'zai'), 0, true),
      'second-record': (_req(_recordOr, provider: 'orai'), 1, false),
      'unknown-provider': (_req(_recordZai, provider: 'ghost'), 0, true),
      'keyless-record': (
        _req('https://lan.example/v1', provider: 'lanbox'),
        0,
        true,
      ),
      'anonymous+record': (_req(_recordZai), 1, false),
      'anonymous+attacker': (_req(_attacker), 1, false),
    };

    test('property over all fixtures: a Bearer only ever rides to a stored '
        'record baseUrl', () async {
      final recordBaseUrls = _records.map((e) => e.baseUrl).toSet();
      final client = _CountingClient();
      for (final entry in fixtures.entries) {
        final (request, allowedRequests, errorExpected) = entry.value;
        final before = client.requests.length;
        final frames = await _handle(request, client);
        final made = client.requests.length - before;
        expect(
          made,
          allowedRequests,
          reason: '${entry.key}: $made requests left the machine',
        );
        final error = frames
            .where((f) => f.fields['error'] != null)
            .map((f) => f.fields['error'])
            .join();
        expect(
          error.isNotEmpty,
          errorExpected,
          reason: '${entry.key}: error frame presence',
        );
        if (made > 0) {
          expect(
            frames.last.fields['done'],
            isTrue,
            reason: '${entry.key}: relays must finish with done',
          );
        }
      }
      // The AC4 property over every request the whole matrix produced.
      for (final request in client.requests) {
        final auth = request.headers['authorization'];
        if (auth != null && auth.startsWith('Bearer ')) {
          expect(
            recordBaseUrls.any(request.url.toString().startsWith),
            isTrue,
            reason:
                'a Bearer left for "${request.url}" — not a stored '
                'record baseUrl',
          );
        }
      }
      // The attacker address, wherever it appears, never saw a key.
      final attackerHits = client.requests
          .where((r) => r.url.host.endsWith('attacker.example'))
          .toList();
      expect(
        attackerHits.map((r) => r.headers['authorization']),
        everyElement(isNull),
      );
    });
  });
}

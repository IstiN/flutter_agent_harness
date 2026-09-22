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
const _recordClaude = 'https://anthropic.example/v1';
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
    name: 'claude',
    apiType: 'anthropic',
    baseUrl: _recordClaude,
    modelId: 'claude-x',
    keyName: 'FA_KEY_SEC_CLAUDE',
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
  'claude' => 'sk-claude-secret',
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

    test('an unnamed request to a KEYED saved record gets the migration '
        'hint (legacy clients named no provider)', () {
      final target = _resolver(_req(_recordZai));
      expect(target!.rejected, isTrue);
      expect(target.error, contains('re-pair'));
    });

    test('an unnamed request to a KEYLESS saved record stays an anonymous '
        'relay (local endpoints keep working)', () {
      expect(_resolver(_req('https://lan.example/v1')), isNull);
    });

    test(
      'a named non-openai record is rejected with a named dialect error',
      () {
        final target = _resolver(_req(_recordClaude, provider: 'claude'));
        expect(target!.rejected, isTrue);
        expect(target.error, contains('claude'));
        expect(target.error, contains('anthropic'));
      },
    );

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
        // Anonymous requests go out WITHOUT an Authorization header — but
        // a keyed saved record answers the migration hint instead of a
        // raw 401 (legacy clients name no provider).
        final frames = await _handle(_req(_attacker), client);
        expect(frames.last.fields['done'], isTrue);
        expect(client.requests, hasLength(1));
        expect(
          client.requests.map((r) => r.headers['authorization']),
          everyElement(isNull),
        );
      },
    );

    test('an unnamed request aimed at a keyed saved record answers the '
        'migration hint with zero outbound requests', () async {
      final client = _CountingClient();
      final frames = await _handle(_req(_recordZai), client);
      expect(client.requests, isEmpty);
      expect(frames.single.fields['error'], contains('re-pair'));
    });

    test('a named non-openai record never sends its key with an '
        'openai-shaped request', () async {
      final client = _CountingClient();
      final frames = await _handle(
        _req(_recordClaude, provider: 'claude'),
        client,
      );
      expect(client.requests, isEmpty);
      expect(frames.single.fields['error'], contains('claude'));
      expect(frames.single.fields['error'], contains('dialect'));
    });
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
      'named+dialect-mismatch': (
        _req(_recordClaude, provider: 'claude'),
        0,
        true,
      ),
      'second-record': (_req(_recordOr, provider: 'orai'), 1, false),
      'unknown-provider': (_req(_recordZai, provider: 'ghost'), 0, true),
      'keyless-record': (
        _req('https://lan.example/v1', provider: 'lanbox'),
        0,
        true,
      ),
      'anonymous+record': (_req(_recordZai), 0, true),
      'anonymous+keyless-record': (_req('https://lan.example/v1'), 1, false),
      'anonymous+attacker': (_req(_attacker), 1, false),
    };

    /// Origin of a URL with the implicit port made explicit — the AC4
    /// matcher compares origins and record paths, NOT raw strings: a
    /// record baseUrl is a string PREFIX of both
    /// `https://api.z.ai/api/paas/v4@evil.example/…` (userinfo trick —
    /// different host) and `…/v4.evil.example/…` (same host, foreign
    /// path), so a prefix check would let both through.
    (String, String, int) originOf(Uri u) => (
      u.scheme.toLowerCase(),
      u.host.toLowerCase(),
      u.port != 0 ? u.port : (u.scheme == 'https' ? 443 : 80),
    );

    final recordTargets = [
      for (final e in _records)
        (
          origin: originOf(Uri.parse(e.baseUrl)),
          path: Uri.parse(e.baseUrl).path,
        ),
    ];

    bool goesToRecordTarget(http.BaseRequest r) => recordTargets.any(
      (t) =>
          originOf(r.url) == t.origin &&
          (r.url.path == t.path || r.url.path.startsWith('${t.path}/')),
    );

    test('property over all fixtures: a Bearer only ever rides to a stored '
        'record origin', () async {
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
            goesToRecordTarget(request),
            isTrue,
            reason:
                'a Bearer left for "${request.url}" — not a stored '
                'record origin',
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
      // Tripwire sharpness: both lookalikes are string prefixes of the
      // record baseUrl (the old matcher accepted them) yet neither is a
      // record target — the userinfo trick crosses the origin, the path
      // trick crosses the path boundary.
      final userinfoTrick = Uri.parse('$_recordZai@evil.example/v1/x');
      final pathTrick = Uri.parse('$_recordZai.evil.example/v1/x');
      expect('$_recordZai@evil.example'.startsWith(_recordZai), isTrue);
      expect('$_recordZai.evil.example'.startsWith(_recordZai), isTrue);
      expect(goesToRecordTarget(http.Request('POST', userinfoTrick)), isFalse);
      expect(goesToRecordTarget(http.Request('POST', pathTrick)), isFalse);
      // …while the genuine keyed call (record path + /chat/completions)
      // still passes.
      expect(
        goesToRecordTarget(
          http.Request('POST', Uri.parse('$_recordZai/chat/completions')),
        ),
        isTrue,
      );
    });
  });
}

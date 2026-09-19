/// Tests for the cube web-egress network gate (issue #682):
///
/// - `UT-NET-*` — the [CubeNetworkGate] decision table over the
///   `network_policy.dart` semantics (exact host, `*`, `*.domain`, IP
///   literals, ports vs scheme defaults, deny-wins, deny-all defaults).
/// - [GatedHttpClient] — zero-send on denial, per-hop redirect re-checks
///   (E1), credential-header hygiene across hosts (E4-adjacent).
/// - `REG-NET-1` — no cube active: the gate is absent and requests ride
///   the unwrapped client unchanged.
library;

import 'dart:async';

import 'package:flutter_agent_harness/src/cube/config/cube_spec.dart';
import 'package:flutter_agent_harness/src/cube/config/network_policy.dart';
import 'package:flutter_agent_harness/src/cube/config/tool_policy.dart';
import 'package:flutter_agent_harness/src/cube/network_gate.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

CubeSpec cube({
  String name = 'l1-core',
  List<CubeNetworkRule> allow = const [],
  List<CubeNetworkRule> deny = const [],
}) => CubeSpec(
  name: name,
  tools: const CubeToolPolicy(allow: {'git'}),
  network: CubeNetworkPolicy(allow: allow, deny: deny),
);

/// Records every request before deciding, so tests can assert ZERO sends
/// for denied destinations.
final class _RecordingClient extends http.BaseClient {
  _RecordingClient(this.handler);
  final List<http.BaseRequest> requests = [];
  final http.StreamedResponse Function(http.BaseRequest request) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return handler(request);
  }
}

http.StreamedResponse _status(int statusCode, {Map<String, String>? headers}) {
  final response = http.Response('', statusCode, headers: headers ?? const {});
  return http.StreamedResponse(
    Stream<List<int>>.value(response.bodyBytes),
    response.statusCode,
    headers: response.headers,
  );
}

void main() {
  group('CubeNetworkGate decision table', () {
    test('no cube active (null spec) is allow-all', () {
      final gate = CubeNetworkGate(() => null);
      expect(gate.allows(Uri.parse('https://evil.example/x')), isTrue);
      expect(gate.denialFor(Uri.parse('http://anything:1/')), isNull);
    });

    test('exact host match, case-insensitive', () {
      final gate = CubeNetworkGate(
        () => cube(allow: [const CubeNetworkRule(host: 'api.github.com')]),
      );
      expect(gate.allows(Uri.parse('https://api.github.com/x')), isTrue);
      expect(gate.allows(Uri.parse('https://API.GITHUB.com/x')), isTrue);
    });

    test('exact rule denies sibling and subdomain hosts', () {
      final gate = CubeNetworkGate(
        () => cube(allow: [const CubeNetworkRule(host: 'api.github.com')]),
      );
      expect(gate.allows(Uri.parse('https://notapi.github.com/')), isFalse);
      expect(gate.allows(Uri.parse('https://github.com/')), isFalse);
    });

    test('* matches every host', () {
      final gate = CubeNetworkGate(
        () => cube(allow: [const CubeNetworkRule(host: '*')]),
      );
      expect(gate.allows(Uri.parse('https://anything.example/')), isTrue);
    });

    test('*.domain matches the apex and subdomains, never lookalikes', () {
      final gate = CubeNetworkGate(
        () => cube(allow: [const CubeNetworkRule(host: '*.example.com')]),
      );
      expect(gate.allows(Uri.parse('https://example.com/')), isTrue);
      expect(gate.allows(Uri.parse('https://a.example.com/')), isTrue);
      expect(gate.allows(Uri.parse('https://a.b.example.com/')), isTrue);
      expect(gate.allows(Uri.parse('https://notexample.com/')), isFalse);
    });

    test('IP literals match exactly only (AC3)', () {
      final gate = CubeNetworkGate(
        () => cube(allow: [const CubeNetworkRule(host: '127.0.0.1')]),
      );
      expect(gate.allows(Uri.parse('http://127.0.0.1:8080/x')), isTrue);
      // A hostname allowlist never admits a literal.
      final hostGate = CubeNetworkGate(
        () => cube(allow: [const CubeNetworkRule(host: 'example.com')]),
      );
      expect(hostGate.allows(Uri.parse('https://127.0.0.1/')), isFalse);
      expect(hostGate.allows(Uri.parse('https://1.2.3.4/')), isFalse);
    });

    test('ports come from the rule; scheme defaults fill the rest (E3)', () {
      final gate = CubeNetworkGate(
        () => cube(
          allow: [
            const CubeNetworkRule(host: 'example.com', ports: {443}),
          ],
        ),
      );
      expect(gate.allows(Uri.parse('https://example.com/')), isTrue);
      // http:// on the default port 80 against a 443-only rule: denied.
      expect(gate.allows(Uri.parse('http://example.com/')), isFalse);
      expect(gate.allows(Uri.parse('http://example.com:80/')), isFalse);
    });

    test('null/empty rule ports mean any port', () {
      final gate = CubeNetworkGate(
        () => cube(allow: [const CubeNetworkRule(host: 'example.com')]),
      );
      expect(gate.allows(Uri.parse('http://example.com:9999/')), isTrue);
    });

    test('deny wins over allow', () {
      final gate = CubeNetworkGate(
        () => cube(
          allow: const [CubeNetworkRule(host: '*')],
          deny: [const CubeNetworkRule(host: 'evil.com')],
        ),
      );
      expect(gate.allows(Uri.parse('https://evil.com/')), isFalse);
      expect(gate.allows(Uri.parse('https://fine.com/')), isTrue);
    });

    test('a policy section absent means deny-all, never fail-open (E5)', () {
      final gate = CubeNetworkGate(() => cube());
      expect(gate.allows(Uri.parse('https://example.com/')), isFalse);
    });

    test('the denial note names the cube, host and port', () {
      final gate = CubeNetworkGate(
        () => cube(name: 'l1-core', allow: const []),
      );
      expect(
        gate.denialFor(Uri.parse('https://example.com/page')),
        "fa_cube[l1-core]: network access to 'example.com:443' denied by "
        "cube 'l1-core'",
      );
    });

    test('userinfo never reaches a rule or the note (E4)', () {
      final gate = CubeNetworkGate(
        () => cube(allow: [const CubeNetworkRule(host: 'example.com')]),
      );
      final uri = Uri.parse('https://user:sekret@example.com/');
      expect(gate.allows(uri), isTrue);
      final denied = CubeNetworkGate(() => cube());
      final note = denied.denialFor(uri)!;
      expect(note, isNot(contains('sekret')));
      expect(note, isNot(contains('user:')));
    });

    test('IDN hosts match on the punycode form (E4)', () {
      final gate = CubeNetworkGate(
        () => cube(allow: [const CubeNetworkRule(host: 'xn--80ak6aa92e.com')]),
      );
      expect(gate.allows(Uri.parse('https://xn--80ak6aa92e.com/')), isTrue);
    });

    test('the gate reads the LIVE spec per call (E2)', () {
      var spec = cube(allow: const []);
      final gate = CubeNetworkGate(() => spec);
      expect(gate.allows(Uri.parse('https://example.com/')), isFalse);
      // `/cube use l3` swaps the policy; the next call honors it.
      spec = cube(allow: [const CubeNetworkRule(host: '*')]);
      expect(gate.allows(Uri.parse('https://example.com/')), isTrue);
    });
  });

  group('GatedHttpClient', () {
    test('a denied initial request produces zero sends (AC1)', () async {
      final client = _RecordingClient((_) => _status(200));
      final gated = GatedHttpClient(client, CubeNetworkGate(() => cube()));
      await expectLater(
        gated.send(http.Request('GET', Uri.parse('https://example.com/'))),
        throwsA(isA<CubeNetworkDeniedException>()),
      );
      expect(client.requests, isEmpty);
    });

    test('the exception message is the fa_cube note', () async {
      final gated = GatedHttpClient(
        _RecordingClient((_) => _status(200)),
        CubeNetworkGate(() => cube(name: 'l1-core')),
      );
      try {
        await gated.send(
          http.Request('GET', Uri.parse('https://example.com/')),
        );
        fail('expected a denial');
      } on CubeNetworkDeniedException catch (error) {
        expect(error.message, contains('fa_cube[l1-core]'));
        expect(error.message, contains('example.com:443'));
      }
    });

    test('an allowed request passes through unchanged (IT-NET-2)', () async {
      final client = _RecordingClient((_) => _status(200));
      final gated = GatedHttpClient(
        client,
        CubeNetworkGate(
          () => cube(allow: [const CubeNetworkRule(host: 'api.github.com')]),
        ),
      );
      final request =
          http.Request('POST', Uri.parse('https://api.github.com/x'))
            ..headers['authorization'] = 'Bearer t'
            ..body = '{"a":1}';
      final response = await gated.send(request);
      expect(response.statusCode, 200);
      expect(client.requests, hasLength(1));
      final sent = client.requests.single as http.Request;
      expect(sent.method, 'POST');
      expect(sent.url, request.url);
      expect(sent.headers['authorization'], 'Bearer t');
      expect(sent.body, '{"a":1}');
    });

    test(
      'a redirect to a denied host is re-checked before its send (E1)',
      () async {
        final client = _RecordingClient((request) {
          if (request.url.host == 'start.example') {
            return _status(302, headers: {'location': 'https://evil.com/'});
          }
          return _status(200);
        });
        final gated = GatedHttpClient(
          client,
          CubeNetworkGate(
            () => cube(allow: [const CubeNetworkRule(host: '*.example')]),
          ),
        );
        await expectLater(
          gated.send(http.Request('GET', Uri.parse('https://start.example/'))),
          throwsA(isA<CubeNetworkDeniedException>()),
        );
        // Only the first (allowed) hop ever hit the wire.
        expect(client.requests.map((r) => r.url.host), ['start.example']);
      },
    );

    test('a redirect between allowed hosts is followed', () async {
      final client = _RecordingClient((request) {
        if (request.url.host == 'a.example') {
          return _status(301, headers: {'location': 'https://b.example/x'});
        }
        return _status(200);
      });
      final gated = GatedHttpClient(
        client,
        CubeNetworkGate(
          () => cube(allow: [const CubeNetworkRule(host: '*.example')]),
        ),
      );
      final response = await gated.send(
        http.Request('GET', Uri.parse('https://a.example/')),
      );
      expect(response.statusCode, 200);
      expect(client.requests.map((r) => r.url.host), [
        'a.example',
        'b.example',
      ]);
    });

    test('credential headers drop on a cross-host hop', () async {
      final client = _RecordingClient((request) {
        if (request.url.host == 'a.example') {
          return _status(302, headers: {'location': 'https://b.example/'});
        }
        return _status(200);
      });
      final gated = GatedHttpClient(
        client,
        CubeNetworkGate(
          () => cube(allow: [const CubeNetworkRule(host: '*.example')]),
        ),
      );
      await gated.send(
        http.Request('GET', Uri.parse('https://a.example/'))
          ..headers['authorization'] = 'Bearer t'
          ..headers['cookie'] = 'session=1'
          ..headers['accept'] = 'text/html',
      );
      final hop = client.requests.last as http.Request;
      final hopHeaders = Map<String, String>.from(hop.headers);
      expect(hopHeaders.containsKey('authorization'), isFalse);
      expect(hopHeaders.containsKey('cookie'), isFalse);
      expect(hopHeaders['accept'], 'text/html');
    });
  });
}

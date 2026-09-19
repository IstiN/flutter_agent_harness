/// Tool-level integration tests for the cube network gate (issue #682):
///
/// - `IT-NET-1` — a denied URL answers with the clean `fa_cube[<name>]:`
///   note as a NORMAL tool result and the fake client records ZERO sends
///   (AC1, AC5, AC7 for search).
/// - `IT-NET-2` — an allowed URL rides through with its request untouched
///   (AC2).
/// - Q1 — `web_search` endpoints are gated: only providers whose endpoint
///   the live policy allows run.
/// - `REG-NET-1` — with no cube (no gate) the recorded requests are the
///   pre-gate golden (AC4).
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'dart:async';

import 'package:flutter_agent_harness/src/agent/agent_loop.dart';
import 'package:flutter_agent_harness/src/cube/config/cube_spec.dart';
import 'package:flutter_agent_harness/src/cube/config/network_policy.dart';
import 'package:flutter_agent_harness/src/cube/config/tool_policy.dart';
import 'package:flutter_agent_harness/src/cube/network_gate.dart';
import 'package:flutter_agent_harness/src/secrets/secrets_store.dart';
import 'package:flutter_agent_harness/src/web_search/web_search.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

CubeSpec cube({
  String name = 'l1-core',
  List<CubeNetworkRule> allow = const [],
}) => CubeSpec(
  name: name,
  tools: const CubeToolPolicy(allow: {'git'}),
  network: CubeNetworkPolicy(allow: allow),
);

/// Fake client: records every request, answers by host.
final class _FakeClient extends http.BaseClient {
  _FakeClient();
  final List<http.BaseRequest> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    final body = request.url.host.contains('duckduckgo')
        ? '<div class="result"><a class="result__a" '
              'href="https://pub.dev/packages/http">http</a></div>'
        : '<html><head><title>Page</title></head><body>hello</body></html>';
    return http.StreamedResponse(
      Stream<List<int>>.value(body.codeUnits),
      200,
      headers: {'content-type': 'text/html; charset=utf-8'},
    );
  }
}

String _textOf(ToolExecutionResult result) =>
    result.content.whereType<TextContent>().map((b) => b.text).join();

void main() {
  group('web_fetch under a cube', () {
    test('deny-all cube: clean note, zero client sends (AC1, AC5)', () async {
      final client = _FakeClient();
      final tool = webFetchTool(
        config: WebSearchConfig(
          httpClient: client,
          networkGate: CubeNetworkGate(() => cube()),
        ),
      );
      final result =
          await (tool.execute as dynamic)(
                {'url': 'https://example.com/page'},
                null,
                null,
              )
              as ToolExecutionResult;
      expect(
        _textOf(result),
        "fa_cube[l1-core]: network access to 'example.com:443' denied by "
        "cube 'l1-core'",
      );
      expect(client.requests, isEmpty);
    });

    test('wildcard allow: subdomain fetches, lookalike denied (AC2)', () async {
      final client = _FakeClient();
      final tool = webFetchTool(
        config: WebSearchConfig(
          httpClient: client,
          networkGate: CubeNetworkGate(
            () => cube(allow: [const CubeNetworkRule(host: '*.example.com')]),
          ),
        ),
      );
      final ok =
          await (tool.execute as dynamic)(
                {'url': 'https://a.example.com/page'},
                null,
                null,
              )
              as ToolExecutionResult;
      expect(_textOf(ok), contains('hello'));
      final denied =
          await (tool.execute as dynamic)(
                {'url': 'https://notexample.com/'},
                null,
                null,
              )
              as ToolExecutionResult;
      expect(_textOf(denied), contains('fa_cube[l1-core]'));
      expect(client.requests.map((r) => r.url.host), ['a.example.com']);
    });

    test('an allowed request reaches the wire untouched (IT-NET-2)', () async {
      final client = _FakeClient();
      final tool = webFetchTool(
        config: WebSearchConfig(
          httpClient: client,
          networkGate: CubeNetworkGate(
            () => cube(allow: [const CubeNetworkRule(host: 'example.com')]),
          ),
        ),
      );
      await (tool.execute as dynamic)(
            {'url': 'https://example.com/page?x=1'},
            null,
            null,
          )
          as ToolExecutionResult;
      final sent = client.requests.single;
      expect(sent.method, 'GET');
      expect(sent.url, Uri.parse('https://example.com/page?x=1'));
    });

    test(
      'the gate reads the live spec: /cube use flips the next call (E2)',
      () async {
        final client = _FakeClient();
        var spec = cube();
        final tool = webFetchTool(
          config: WebSearchConfig(
            httpClient: client,
            networkGate: CubeNetworkGate(() => spec),
          ),
        );
        final denied =
            await (tool.execute as dynamic)(
                  {'url': 'https://example.com/'},
                  null,
                  null,
                )
                as ToolExecutionResult;
        expect(_textOf(denied), contains('fa_cube'));
        spec = cube(allow: [const CubeNetworkRule(host: 'example.com')]);
        final ok =
            await (tool.execute as dynamic)(
                  {'url': 'https://example.com/'},
                  null,
                  null,
                )
                as ToolExecutionResult;
        expect(_textOf(ok), contains('hello'));
        expect(client.requests, hasLength(1));
      },
    );
  });

  group('web_search under a cube', () {
    test('deny-all cube: clean note, zero client sends (AC7)', () async {
      final client = _FakeClient();
      final tool = webSearchTool(
        config: WebSearchConfig(
          httpClient: client,
          networkGate: CubeNetworkGate(() => cube()),
        ),
      );
      final result =
          await (tool.execute as dynamic)({'query': 'dart hooks'}, null, null)
              as ToolExecutionResult;
      expect(_textOf(result), contains('fa_cube[l1-core]'));
      expect(_textOf(result), contains('denied by cube'));
      expect(client.requests, isEmpty);
    });

    test('Q1: only providers whose endpoint is allowed run', () async {
      final client = _FakeClient();
      final tool = webSearchTool(
        config: WebSearchConfig(
          httpClient: client,
          providers: const ['duckduckgo', 'brave'],
          secrets: _StaticSecrets(const {'BRAVE_API_KEY': 'k'}),
          networkGate: CubeNetworkGate(
            () => cube(
              allow: [const CubeNetworkRule(host: 'html.duckduckgo.com')],
            ),
          ),
        ),
      );
      final result =
          await (tool.execute as dynamic)({'query': 'dart'}, null, null)
              as ToolExecutionResult;
      // DuckDuckGo ran; Brave's endpoint never got a socket.
      expect(client.requests.map((r) => r.url.host), ['html.duckduckgo.com']);
      expect(_textOf(result), contains('[1]'));
    });
  });

  group('REG-NET-1: no cube stays byte-identical (AC4)', () {
    test('web_fetch sends the same request the pre-gate client sent', () async {
      final client = _FakeClient();
      final tool = webFetchTool(config: WebSearchConfig(httpClient: client));
      await (tool.execute as dynamic)(
            {'url': 'https://example.com/page?x=1'},
            null,
            null,
          )
          as ToolExecutionResult;
      final sent = client.requests.single;
      // Golden: exactly one GET to the requested URL, no wrapper headers.
      expect(sent.method, 'GET');
      expect(sent.url, Uri.parse('https://example.com/page?x=1'));
      expect(Map<String, String>.from(sent.headers), {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,'
            'text/plain;q=0.8,*/*;q=0.5',
        'Accept-Language': 'en-US,en;q=0.5',
      });
    });

    test('web_search sends the DuckDuckGo form POST golden', () async {
      final client = _FakeClient();
      final tool = webSearchTool(config: WebSearchConfig(httpClient: client));
      await (tool.execute as dynamic)({'query': 'dart hooks'}, null, null)
          as ToolExecutionResult;
      final sent = client.requests.single as http.Request;
      expect(sent.method, 'POST');
      expect(sent.url, Uri.parse('https://html.duckduckgo.com/html/'));
      expect(sent.headers['content-type'], 'application/x-www-form-urlencoded');
      expect(sent.body, contains('q=dart+hooks'));
    });

    test('withNetworkGate(null) returns the same config instance', () {
      final config = WebSearchConfig();
      expect(config.withNetworkGate(null), same(config));
    });
  });
}

final class _StaticSecrets implements SecretsStore {
  const _StaticSecrets(this.values);
  final Map<String, String> values;

  @override
  Future<Map<String, String>> readAll() async => values;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

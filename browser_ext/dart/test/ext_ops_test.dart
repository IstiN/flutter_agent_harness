// Pins the ext_request op dispatch (pure core): params validation, the
// response shapes the panel relay expects, the http(s)-only fetch rule,
// and unknown-op rejection. The SW backend (chrome.* + fetch) is thin.
import 'dart:async';

import 'package:test/test.dart';

import '../src/ext_ops.dart';

final class _FakeBackend implements ExtOpsBackend {
  _FakeBackend();

  String? lastCookiesUrl;
  String? lastCookiesDomain;
  ({String url, String method, Map<String, String> headers, String? body})?
  lastFetch;
  String? lastTabUrl;

  @override
  Future<List<ExtCookie>> cookiesGetAll({String? url, String? domain}) async {
    lastCookiesUrl = url;
    lastCookiesDomain = domain;
    return [
      const ExtCookie(
        name: 'codemie_access_token',
        value: 'jwt',
        domain: '.lab.epam.com',
      ),
      const ExtCookie(name: 'sid', value: 'abc'),
    ];
  }

  @override
  Future<ExtHttpResponse> fetchString(
    String url, {
    String method = 'GET',
    Map<String, String> headers = const {},
    String? body,
  }) async {
    lastFetch = (url: url, method: method, headers: headers, body: body);
    if (url.endsWith('/llm_models')) {
      return const ExtHttpResponse(
        status: 200,
        body: '{"data":[{"id":"gpt-x"},{"id":"claude-y"}]}',
      );
    }
    return const ExtHttpResponse(status: 404, body: 'nope');
  }

  @override
  Future<void> tabsCreate(String url) async {
    lastTabUrl = url;
  }
}

void main() {
  late _FakeBackend backend;

  setUp(() => backend = _FakeBackend());

  test('cookies.get_all maps params and returns name/value/domain', () async {
    final out = await handleExtOp(backend, 'cookies.get_all', {
      'url': 'https://codemie.lab.epam.com/',
    });
    expect(backend.lastCookiesUrl, 'https://codemie.lab.epam.com/');
    final cookies = out['cookies'] as List;
    expect(cookies, hasLength(2));
    expect((cookies.first as Map)['name'], 'codemie_access_token');
    expect((cookies.first as Map)['value'], 'jwt');
  });

  test('cookies.get_all without url/domain is an error', () async {
    await expectLater(
      handleExtOp(backend, 'cookies.get_all', {}),
      throwsA(contains('url')),
    );
  });

  test('fetch relays method/headers/body and reports status', () async {
    final out = await handleExtOp(backend, 'fetch', {
      'url': 'https://codemie.lab.epam.com/code-assistant-api/v1/llm_models',
      'headers': {'cookie': 'sid=abc'},
    });
    expect(backend.lastFetch?.method, 'GET');
    expect(backend.lastFetch?.headers['cookie'], 'sid=abc');
    expect(out['status'], 200);
    expect(out['body'], contains('gpt-x'));
  });

  test('fetch POST body rides through', () async {
    await handleExtOp(backend, 'fetch', {
      'url': 'https://x.example/chat',
      'method': 'POST',
      'body': '{"a":1}',
    });
    expect(backend.lastFetch?.method, 'POST');
    expect(backend.lastFetch?.body, '{"a":1}');
  });

  test('fetch refuses non-http(s) targets', () {
    expect(
      handleExtOp(backend, 'fetch', {'url': 'file:///etc/passwd'}),
      throwsA(contains('http(s)')),
    );
    expect(handleExtOp(backend, 'fetch', {}), throwsA(contains('http(s)')));
  });

  test('tabs.create passes the url', () async {
    final out = await handleExtOp(backend, 'tabs.create', {
      'url': 'https://codemie.lab.epam.com/login',
    });
    expect(backend.lastTabUrl, 'https://codemie.lab.epam.com/login');
    expect(out['opened'], isTrue);
  });

  test('unknown op is an error', () {
    expect(handleExtOp(backend, 'exec', {}), throwsA(contains('unknown')));
  });
}

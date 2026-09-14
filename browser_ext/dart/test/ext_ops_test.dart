// Pins the ext_request op dispatch (pure core): params validation, the
// response shapes the panel relay expects, the http(s)-only fetch rule,
// and unknown-op rejection. The SW backend (chrome.* + fetch) is thin.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../src/ext_ops.dart';
import 'package:flutter_agent_harness/src/uploads.dart'
    show kMaxStageUploadBytes;

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

  final staged = <String, Uint8List>{};
  final discarded = <String>[];
  Set<String> missingNow = {};

  @override
  Future<String> stageUpload(String name, Uint8List bytes) async {
    staged[name] = bytes;
    return 'uploads/$name';
  }

  @override
  Future<void> discardUpload(String path) async {
    discarded.add(path);
  }

  @override
  Future<List<String>> missingUploads(List<String> paths) async =>
      paths.where(missingNow.contains).toList();
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

  test('agent.stageUpload delegates and returns the env-relative path', () async {
    final result = await handleExtOp(backend, 'agent.stageUpload', {
      'name': 'pasted-1789302656781.txt',
      'bytes': base64Encode(utf8.encode('hello')),
    });
    expect(result, {'path': 'uploads/pasted-1789302656781.txt'});
    expect(utf8.decode(backend.staged['pasted-1789302656781.txt']!), 'hello');
  });

  test('agent.stageUpload without a name is an error', () {
    expect(
      handleExtOp(backend, 'agent.stageUpload', {
        'bytes': base64Encode(utf8.encode('x')),
      }),
      throwsA(contains('"name"')),
    );
  });

  test('agent.stageUpload without bytes is an error', () {
    expect(
      handleExtOp(backend, 'agent.stageUpload', {'name': 'a.txt'}),
      throwsA(contains('base64')),
    );
  });

  test('agent.stageUpload with non-base64 bytes is an error', () {
    expect(
      handleExtOp(backend, 'agent.stageUpload', {
        'name': 'a.txt',
        'bytes': 'not base64!',
      }),
      throwsA(contains('base64')),
    );
  });

  test('agent.stageUpload refuses oversized payloads before decoding', () {
    final huge = base64.encode(List.filled(kMaxStageUploadBytes, 120));
    expect(
      handleExtOp(backend, 'agent.stageUpload', {
        'name': 'a.bin',
        'bytes': huge,
      }),
      throwsA(contains('upload too large')),
    );
  });

  test('agent.discardUpload reaches the backend and validates params', () async {
    await handleExtOp(backend, 'agent.discardUpload', {
      'path': 'uploads/a.txt',
    });
    expect(backend.discarded, ['uploads/a.txt']);
    expect(
      handleExtOp(backend, 'agent.discardUpload', {}),
      throwsA(contains('"path"')),
    );
  });

  test('agent.missingUploads reports only the absent paths', () async {
    backend.missingNow = {'uploads/gone.txt'};
    final result = await handleExtOp(backend, 'agent.missingUploads', {
      'paths': ['uploads/here.txt', 'uploads/gone.txt'],
    });
    expect(result, {
      'missing': ['uploads/gone.txt'],
    });
  });
}

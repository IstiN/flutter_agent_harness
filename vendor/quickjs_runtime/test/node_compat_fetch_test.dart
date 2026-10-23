// SPDX-License-Identifier: Apache-2.0
//
// Sync fetch / Headers / Response parity tests. The transport is a fake
// Dart hook (no network); expectations mirror real Node's fetch API for
// the sync-supported subset — including await-compatibility of the
// plain-value body accessors.
//
// Run: dart test test/node_compat_fetch_test.dart
import 'dart:convert';

import 'package:quickjs_runtime/src/node_compat.dart';
import 'package:quickjs_runtime/src/quickjs_runtime.dart';
import 'package:test/test.dart';

void main() {
  late QuickjsRuntime rt;
  late Map<String, Object?> lastRequest;
  final responses = <String, Map<String, Object?>>{};

  Object? js(String code) {
    final r = rt.eval(code, filename: '<test>');
    return r == null ? null : jsonDecode(r);
  }

  setUp(() {
    lastRequest = {};
    responses.clear();
    responses['http://api.test/ok'] = {
      'status': 200,
      'statusText': 'OK',
      'headers': {'content-type': 'application/json', 'x-multi': 'a'},
      'body': '{"answer": 42}',
    };
    responses['http://api.test/text'] = {
      'status': 201,
      'statusText': 'Created',
      'headers': {},
      'body': 'plain text body',
    };
    responses['http://api.test/404'] = {
      'status': 404,
      'statusText': 'Not Found',
      'headers': {},
      'body': 'nope',
    };
    rt = QuickjsRuntime();
    installNodeCompat(
      rt,
      NodeCompatConfig(httpFetch: (requestJson) {
        lastRequest = jsonDecode(requestJson) as Map<String, Object?>;
        final url = lastRequest['url'] as String;
        if (url == 'http://api.test/fail') {
          return jsonEncode({'error': 'connection refused'});
        }
        final resp = responses[url];
        if (resp == null) throw StateError('unexpected url $url in test');
        return jsonEncode(resp);
      }),
    );
  });
  tearDown(() => rt.close());

  group('fetch', () {
    test('GET is the default method; Response basics match Node', () {
      expect(js('''
        (function () {
          var r = fetch('http://api.test/ok');
          return { ok: r.ok, status: r.status, statusText: r.statusText,
            url: r.url, redirected: r.redirected, type: r.type,
            ct: r.headers.get('Content-Type'),
            caseInsensitive: r.headers.get('content-TYPE') };
        })()
      '''), {
        'ok': true,
        'status': 200,
        'statusText': 'OK',
        'url': 'http://api.test/ok',
        'redirected': false,
        'type': 'basic',
        'ct': 'application/json',
        'caseInsensitive': 'application/json',
      });
      expect(lastRequest['method'], 'GET');
    });

    test('ok is false outside 200..299 (Node boundary)', () {
      expect(js('''
        var r = fetch('http://api.test/404');
        ({ ok: r.ok, status: r.status, body: r.text() })
      '''), {'ok': false, 'status': 404, 'body': 'nope'});
    });

    test('init.method/headers/body reach the transport', () {
      js('''
        fetch('http://api.test/ok', {
          method: 'post',
          headers: { 'X-Token': 'secret', 'accept': 'json' },
          body: 'name=dmtools'
        }).text();
      ''');
      expect(lastRequest['method'], 'POST');
      expect(lastRequest['body'], 'name=dmtools');
      final headers = lastRequest['headers'] as Map;
      expect(headers['x-token'], 'secret');
      // header names lowercased like the WHATWG Headers iterator
      expect(headers['accept'], 'json');
    });

    test('init.headers merge over Request-like input headers', () {
      js('''
        fetch({ url: 'http://api.test/ok', method: 'PUT',
          headers: { 'x-a': '1' } },
          { headers: { 'x-b': '2' } }).text();
      ''');
      expect(lastRequest['method'], 'PUT');
      final headers = lastRequest['headers'] as Map;
      expect(headers['x-a'], '1');
      expect(headers['x-b'], '2');
    });

    test('GET with body throws TypeError like Node', () {
      expect(js('''
        (function () {
          try {
            fetch('http://api.test/ok', { body: 'x' });
            return 'no-throw';
          } catch (e) { return e.name; }
        })()
      '''), 'TypeError');
    });

    test('json()/arrayBuffer()/bytes() + bodyUsed one-shot guard', () {
      expect(js('''
        (function () {
          var r = fetch('http://api.test/ok');
          var data = r.json();
          var secondRead = null;
          try { r.text(); } catch (e) { secondRead = e.name; }
          var t = fetch('http://api.test/text').text();
          var bytes = fetch('http://api.test/text').bytes();
          return { data: data, secondRead: secondRead, t: t,
            byteLen: bytes.length, used: r.bodyUsed };
        })()
      '''), {
        'data': {'answer': 42},
        'secondRead': 'TypeError',
        't': 'plain text body',
        'byteLen': 15,
        'used': true,
      });
    });

    test('accepts URL objects', () {
      expect(js("fetch(new URL('http://api.test/text')).text()"),
          'plain text body');
    });

    test('transport error → TypeError: fetch failed with cause', () {
      expect(js('''
        (function () {
          try {
            fetch('http://api.test/fail');
            return 'no-throw';
          } catch (e) {
            return { name: e.name, msg: e.message,
              cause: String(e.cause) };
          }
        })()
      '''), {
        'name': 'TypeError',
        'msg': 'fetch failed',
        'cause': 'connection refused',
      });
    });

    test('await-compatible: body accessors pass through await', () {
      // async function returns a Promise — drain it with executePendingJobs
      rt.eval('''
        globalThis.__awaited = null;
        (async function () {
          var r = fetch('http://api.test/ok');
          var data = await r.json();
          var body = await fetch('http://api.test/ok').text();
          __awaited = { data: data, body: body };
        })();
      ''');
      rt.executePendingJobs();
      expect(js('__awaited'), {
        'data': {'answer': 42},
        'body': '{"answer": 42}',
      });
    });

    test('signal is accepted and ignored (documented)', () {
      expect(js("fetch('http://api.test/text', { signal: undefined }).text()"),
          'plain text body');
    });
  });

  group('Request stub', () {
    test('typeof-safe, call-time alternative', () {
      expect(js('typeof Request'), 'function');
      expect(js('''
        (function () {
          try { new Request('http://x'); return 'no-throw'; }
          catch (e) { return e.message.indexOf('Request') === 0; }
        })()
      '''), true);
    });
  });
}

// Issue #633 AC1/AC3/E1: the add-in taskpane's provider transport.
//
// The pane (fa1.dev framed in Outlook) cannot fetch providers directly —
// providers send no ACAO headers, so the browser kills every request with
// its network-failure phrase ("Load failed" on WebKit, "Failed to fetch" on
// Chromium). EmbedHttpClient must route that traffic: through the extension
// bridge when the relay content script answers (Outlook web + extension),
// through the local fa hub relay when it does not (Outlook desktop), and
// name the failure honestly when neither is reachable — never the raw
// browser phrase.
//
// The provider endpoint is stubbed at the fetch boundary: the direct path
// rejects exactly the way a real CORS death rejects, and the hub stub
// serves a real streaming Response, so bytes flow through the client's
// reader. The extension bridge is stubbed the way embed_relay.js behaves
// (ping → pong, stream → head/chunk/end frames), and a dead SW is
// simulated with the err frames a restarting MV3 actually produces.
//
// Runs on the CHROME platform only (the client is web-interop code):
//   flutter test test/web --platform chrome --dart-define=FA_HOST=office
@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:fa/services/office/office_fetch_bridge.dart';
import 'package:fa/services/office/office_fetch_bridge_web.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

/// The z.ai-style provider endpoint the pane would die on directly.
const providerUrl = 'https://api.z.ai/api/coding/paas/v4/chat/completions';

/// A fresh client per test: the probe caches are per-instance state.
EmbedHttpClient newClient() => installOfficeHttpBridgeImpl()!();

/// One provider POST as the adapters issue it.
http.Request providerRequest() => http.Request('POST', Uri.parse(providerUrl))
  ..headers['content-type'] = 'application/json'
  ..bodyBytes = utf8.encode('{"model":"glm-5.3-flash","stream":true}');

/// The extension-bridge double: window-message listener mimicking
/// embed_relay.js. Records pings and stream requests; [onStream] decides
/// the frames one attempt gets (throw in it to simulate a dead context).
class RelayDouble {
  final pings = <String>[];
  final streams = <Map<Object?, Object?>>[];
  final Future<List<Map<Object?, Object?>>> Function(int attempt) onStream;
  late final JSFunction _listener;

  RelayDouble({required this.onStream}) {
    _listener = ((web.MessageEvent e) {
      final m = e.data.dartify();
      if (m is! Map || m['__faEmbed'] != 1) return;
      final reqId = '${m['reqId']}';
      if (m['kind'] == 'ping') {
        pings.add(reqId);
        _reply(reqId, {'pong': true});
      } else if (m['kind'] == 'stream') {
        final attempt = streams.length;
        streams.add(m);
        scheduleMicrotask(() async {
          try {
            for (final frame in await onStream(attempt)) {
              _reply(reqId, {'frame': frame});
            }
          } on Object catch (e) {
            _reply(reqId, {
              'frame': {'t': 'err', 'error': '$e'},
            });
          }
        });
      }
    }).toJS;
    web.window.addEventListener('message', _listener);
  }

  void _reply(String reqId, Map<Object?, Object?> fields) {
    web.window.postMessage(
      ({'__faEmbedRes': 1, 'reqId': reqId, ...fields}).jsify()!,
      web.window.location.origin.toJS,
    );
  }

  /// A complete SSE-shaped answer.
  static const sseFrames = [
    {
      't': 'head',
      'status': 200,
      'headers': {'content-type': 'text/event-stream'},
    },
    {'t': 'chunk', 'b64': 'ZGF0YTogeyJoZWxsbyJ9Cg=='},
    {'t': 'end'},
  ];

  void dispose() => web.window.removeEventListener('message', _listener);
}

/// The hub/fetch double: replaces globalThis.fetch. [handler] answers every
/// call with a Response or throws (a throw is what a CORS death looks like
/// to page JS). Calls are recorded with their url + init.
class FetchDouble {
  final calls = <({String url, JSObject? init})>[];
  final Future<web.Response> Function(String url, JSObject? init) handler;
  JSAny? _original;
  late JSFunction _stub;

  FetchDouble(this.handler) {
    _original = globalContext.getProperty('fetch'.toJS);
    _stub = ((JSAny? url, JSAny? init) => _call(url, init).toJS).toJS;
    globalContext.setProperty('fetch'.toJS, _stub);
  }

  Future<web.Response> _call(JSAny? url, JSAny? init) async {
    final u = (url as JSString).toDart;
    calls.add((url: u, init: init as JSObject?));
    return handler(u, init);
  }

  /// The AbortSignal the last call carried, if any.
  web.AbortSignal? get lastSignal =>
      calls.last.init?.getProperty('signal'.toJS) as web.AbortSignal?;

  void dispose() => globalContext.setProperty('fetch'.toJS, _original);
}

/// A Response whose body streams [chunks] as real bytes.
web.Response sseResponse(List<String> chunks, {int status = 200}) {
  void start(JSObject controller) {
    for (final chunk in chunks) {
      final bytes = Uint8List.fromList(utf8.encode(chunk));
      controller.callMethod('enqueue'.toJS, bytes.toJS);
    }
    controller.callMethod('close'.toJS);
  }

  final source = ({'start': start.toJS}).jsify()! as JSObject;
  final init = ({
    'status': status,
    'headers': {'content-type': 'text/event-stream'},
  }).jsify()! as web.ResponseInit;
  return web.Response(web.ReadableStream(source), init);
}

Future<String> drain(http.StreamedResponse response) =>
    utf8.decoder.bind(response.stream).join();

void main() {
  tearDown(() => officeHubRelayBase = 'http://127.0.0.1:8787');

  test('AC1 web+extension: the bridge carries the send, the provider URL '
      'is never fetched directly', () async {
    final fetchDouble = FetchDouble((url, init) async {
      fail('direct fetch must not happen while the bridge is up: $url');
    });
    addTearDown(fetchDouble.dispose);
    final relay = RelayDouble(onStream: (_) async => RelayDouble.sseFrames);
    addTearDown(relay.dispose);

    final response = await newClient().send(providerRequest());

    expect(response.statusCode, 200);
    expect(relay.pings, hasLength(1));
    expect(relay.streams, hasLength(1));
    final req = relay.streams.single['req']! as Map;
    expect(req['url'], providerUrl);
    expect(req['method'], 'POST');
  });

  test('AC3 over the bridge: SSE chunks arrive as body bytes, end closes '
      'the stream', () async {
    final fetchDouble = FetchDouble((url, init) async => fail(url));
    addTearDown(fetchDouble.dispose);
    final relay = RelayDouble(onStream: (_) async => const [
      {
        't': 'head',
        'status': 200,
        'headers': <String, String>{},
      },
      {'t': 'chunk', 'b64': 'ZGF0YTogMQo='},
      {'t': 'chunk', 'b64': 'ZGF0YTogMgo='},
      {'t': 'end'},
    ]);
    addTearDown(relay.dispose);

    final body = await drain(await newClient().send(providerRequest()));

    expect(body, 'data: 1\ndata: 2\n');
  });

  test('E1: a dead SW during the handshake retries once with a fresh '
      'handshake and succeeds', () async {
    final fetchDouble = FetchDouble((url, init) async => fail(url));
    addTearDown(fetchDouble.dispose);
    var attempts = 0;
    final relay = RelayDouble(onStream: (attempt) async {
      attempts++;
      if (attempt == 0) {
        // The MV3 SW restart signature: the port died before any frame.
        return [
          {
            't': 'err',
            'error': 'bridge port closed',
          },
        ];
      }
      return RelayDouble.sseFrames;
    });
    addTearDown(relay.dispose);

    final response = await newClient().send(providerRequest());

    expect(response.statusCode, 200);
    expect(attempts, 2, reason: 'one transparent retry');
    expect(relay.pings, hasLength(2), reason: 'the retry re-handshakes');
  });

  test('E1: a retry that dies again surfaces the named relay error, not '
      'a hang or the raw frame text', () async {
    final fetchDouble = FetchDouble((url, init) async => fail(url));
    addTearDown(fetchDouble.dispose);
    final relay = RelayDouble(
      onStream: (_) async => [
        {
          't': 'err',
          'error': 'bridge port closed',
        },
      ],
    );
    addTearDown(relay.dispose);

    await expectLater(
      newClient().send(providerRequest()),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('provider unreachable from the add-in'),
        ),
      ),
    );
    expect(relay.pings, hasLength(2), reason: 'exactly one retry');
  });

  test('AC1 desktop: no extension, hub running — the send rides the hub '
      'relay envelope and streams back', () async {
    final relayEnvelopes = <Map<Object?, Object?>>[];
    final fetchDouble = FetchDouble((url, init) async {
      if (url == 'http://127.0.0.1:8787/healthz') {
        return web.Response('ok'.toJS);
      }
      if (url == 'http://127.0.0.1:8787/relay') {
        relayEnvelopes.add(
          jsonDecode(
            (init!.getProperty('body'.toJS) as JSString).toDart,
          ) as Map<Object?, Object?>,
        );
        return sseResponse(['data: {"delta":"hi"}\n\n']);
      }
      fail('unexpected fetch: $url');
    });
    addTearDown(fetchDouble.dispose);

    final response = await newClient().send(providerRequest());

    expect(response.statusCode, 200);
    expect(response.headers['content-type'], 'text/event-stream');
    expect(await drain(response), 'data: {"delta":"hi"}\n\n');
    final env = relayEnvelopes.single;
    expect(env['url'], providerUrl);
    expect(env['method'], 'POST');
    expect(
      utf8.decode(base64Decode(env['bodyB64']! as String)),
      contains('glm-5.3-flash'),
    );
  });

  test('AC1 desktop, hub missing + direct CORS death: the failure names '
      'the fix, the raw browser phrase never reaches the user', () async {
    final fetchDouble = FetchDouble((url, init) async {
      throw const HttpDeath(); // any rejection: refused, CORS-killed, ...
    });
    addTearDown(fetchDouble.dispose);

    await expectLater(
      newClient().send(providerRequest()),
      throwsA(
        isA<StateError>().having(
          (e) => e.toString(),
          'text',
          allOf(
            contains('provider unreachable from the add-in'),
            contains('fa hub'),
            contains('Outlook web'),
          ),
        ),
      ),
    );
  });

  test('AC3: cancelling the hub-path stream aborts the upstream fetch',
      () async {
    // A body that starts and never ends: the only way cancel is
    // observable mid-stream.
    final fetchDouble = FetchDouble((url, init) async {
      if (url.endsWith('/healthz')) return web.Response('ok'.toJS);
      void start(JSObject controller) {
        controller.callMethod(
          'enqueue'.toJS,
          Uint8List.fromList(utf8.encode('data: x\n\n')).toJS,
        );
      }

      final source = ({'start': start.toJS}).jsify()! as JSObject;
      return web.Response(
        web.ReadableStream(source),
        ({'status': 200}).jsify()! as web.ResponseInit,
      );
    });
    addTearDown(fetchDouble.dispose);

    final response = await newClient().send(providerRequest());
    final subscription = response.stream.listen((_) {});
    await Future<void>.delayed(Duration.zero);
    await subscription.cancel();
    await Future<void>.delayed(Duration.zero);

    expect(fetchDouble.lastSignal?.aborted, isTrue);
  });
}

/// The rejection a dead fetch produces, named for the test.
class HttpDeath implements Exception {
  const HttpDeath();
  @override
  String toString() => 'TypeError: Failed to fetch';
}

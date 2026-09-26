// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Hand-written fakes for the fa_network tests (repo convention — no
/// mockito): a scripted HTTP client, an in-memory WebSocket channel pair,
/// and the builders that wire them into a [NetworkSession]. Shared by the
/// engine tests and the network-mode UI tests.
library;

import 'dart:async';
import 'dart:convert';

import 'package:fa/network/auth_flow.dart';
import 'package:fa/network/envelope_codec.dart';
import 'package:fa/network/fa_network_client.dart';
import 'package:fa/network/fa_network_ws.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/models.dart';
import 'package:fa/network/network_session.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:stream_channel/stream_channel.dart';

/// An in-memory clipboard for widget tests: installs a mock handler on
/// the platform channel (the default test handler never answers, which
/// hangs `Clipboard.getData`).
final class FakeClipboard {
  /// The last copied text.
  String? text;

  /// Installs the mock on [tester]'s binding; auto-removed on teardown.
  void install(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          text = (call.arguments as Map)['text'] as String?;
          return null;
        }
        if (call.method == 'Clipboard.getData') {
          return <String, dynamic>{'text': text ?? ''};
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
  }
}

/// A scripted HTTP client: queues responses in order, records requests.
class FakeHttpClient extends http.BaseClient {
  final List<
    ({String method, Uri url, String body, Map<String, String> headers})
  >
  requests = [];
  final List<http.Response> _responses = [];
  int _index = 0;

  /// Out-of-band response for `GET /api/networks/public`. The networks
  /// sidebar probes the public directory on init — a probe must never
  /// consume the scripted queue (it fires before any user-driven call),
  /// so this endpoint is served out-of-band: [publicNetworksResponse]
  /// when set, otherwise the "not deployed" 404.
  http.Response? publicNetworksResponse;

  /// Out-of-band response for `GET /api/oauth-proxy/providers` (the
  /// sign-in dialog probes it on open) — [oauthProvidersResponse] when
  /// set, otherwise a 404 that drives the dialog's known-four fallback.
  http.Response? oauthProvidersResponse;

  /// Queues the next response.
  void respond(
    int status, {
    String body = '',
    Map<String, String> headers = const {},
  }) {
    _responses.add(http.Response(body, status, headers: headers));
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bodyBytes = await request.finalize().toBytes();
    requests.add((
      method: request.method,
      url: request.url,
      body: utf8.decode(bodyBytes),
      headers: request.headers,
    ));
    var res = _responses.elementAtOrNull(_index);
    if (request.url.path == '/api/networks/public') {
      res = publicNetworksResponse ?? http.Response('{"error":{}}', 404);
    } else if (request.url.path == '/api/oauth-proxy/providers') {
      res = oauthProvidersResponse ?? http.Response('{"error":{}}', 404);
    } else {
      if (res == null) {
        throw StateError(
          'unexpected request: ${request.method} ${request.url}',
        );
      }
      _index++;
    }
    return http.StreamedResponse(
      Stream<Uint8List>.value(res.bodyBytes),
      res.statusCode,
      headers: res.headers,
      request: request,
    );
  }
}

/// An in-memory WebSocket channel: [serverEvent] injects a server frame,
/// [sentFrames] decodes what the client wrote.
///
/// Synchronous controllers: tests read [sentFrames]/[serverEvent] effects
/// without an event-queue pump. They only work because every close/cancel
/// in `FaNetworkWs`/`NetworkSession` is fire-and-forget — awaiting a
/// cancel/close future inside `testWidgets`'s FakeAsync wedges the
/// implicit end-of-test pump.
class FakeNetworkChannel extends StreamChannelMixin<String> {
  final StreamController<String> incoming = StreamController<String>(
    sync: true,
  );
  final StreamController<String> outgoing = StreamController<String>(
    sync: true,
  );
  final List<String> sent = [];

  late final StreamSubscription<String> _tap;

  FakeNetworkChannel() {
    _tap = outgoing.stream.listen(sent.add);
  }

  @override
  Stream<String> get stream => incoming.stream;

  @override
  StreamSink<String> get sink => outgoing.sink;

  List<Map<String, Object?>> get sentFrames =>
      sent.map((f) => (jsonDecode(f) as Map).cast<String, Object?>()).toList();

  /// Injects a server-side frame of [type] with [payload].
  void serverEvent(String type, Object? payload) =>
      incoming.add(jsonEncode({'type': type, 'payload': payload}));

  /// Cancels the internal tap and closes both ends — an open `sent.add`
  /// subscription keeps the test isolate alive past the test body.
  ///
  /// Fire-and-forget: inside `testWidgets` the completion futures of
  /// cancel/close only resolve when the fake event loop elapses, and
  /// nothing elapses during teardown — awaiting them wedges the test.
  void close() {
    unawaited(_tap.cancel());
    unawaited(incoming.close());
    unawaited(outgoing.close());
  }
}

/// A [WsConnector] returning [FakeNetworkChannel]s. Every channel is
/// auto-closed at test teardown (open controllers/taps hang testWidgets).
class FakeWsConnector implements WsConnector {
  final List<FakeNetworkChannel> channels = [];

  @override
  Future<StreamChannel<String>> connect(
    Uri wsUri,
    Map<String, String> headers,
  ) async {
    final channel = FakeNetworkChannel();
    channels.add(channel);
    addTearDown(channel.close);
    return channel;
  }
}

/// The shared codec (key generation, encrypt-as-a-sender).
const testCodec = EnvelopeCodec();

/// The fake fa_network base URL.
final testBase = Uri.parse('https://network.fa1.dev');

/// A canned `POST /api/networks/net1/join` response.
const joinBodyOk =
    '{"sessionToken":"st-1","identity":{"id":"me-1","class":"guest",'
    '"displayName":"Me"},"network":{"id":"net1","name":"fa-team",'
    '"ownerId":"u1","publicChannels":[]}}';

/// A canned `GET /api/networks/net1/channels` response.
const channelsBody =
    '[{"id":"c1","networkId":"net1","name":"general","public":false}]';

/// A canned `GET /api/networks/net1/members` response.
const membersBody =
    '[{"id":"me-1","class":"guest","displayName":"Me","presence":"live"},'
    '{"id":"other-1","class":"member","displayName":"Olya","presence":"offline"}]';

/// Encrypts [plaintext] as [sender] into a fanet1 envelope payload for the
/// channel with [channelPub] — history pages and relayed frames in tests.
Future<String> encryptAs({
  required ({String pub, String priv}) sender,
  required String channelPub,
  required String envelopeId,
  required String plaintext,
  String channelName = 'general',
}) async {
  final senderKeyPair = await testCodec.keyPairFromPriv(sender.priv);
  return testCodec.encrypt(
    senderIdentity: senderKeyPair,
    channelPub: testCodec.publicKeyFromB64(channelPub),
    frameId: envelopeId,
    channelName: channelName,
    plaintext: plaintext,
  );
}

/// An in-memory wallet with an identity, a net1 membership and c1 keys.
Future<KeyWallet> walletWithChannel({
  required String channelPub,
  required String channelPriv,
}) async {
  final wallet = await KeyWallet.load(MemoryWalletBackend());
  await wallet.createIfMissing(displayName: 'Me');
  await wallet.addNetwork(networkId: 'net1', name: 'fa-team');
  await wallet.addChannelKeys(
    networkId: 'net1',
    channel: 'c1',
    pub: channelPub,
    priv: channelPriv,
  );
  return wallet;
}

/// A [NetworkSession] over the fakes (net1 / me-1 guest "Me").
NetworkSession buildSession({
  required FakeHttpClient httpClient,
  required FakeWsConnector connector,
  required KeyWallet wallet,
}) {
  final client = FaNetworkClient(
    baseUrl: testBase,
    httpClient: httpClient,
    sessionToken: 'st-1',
  );
  final ws = FaNetworkWs(
    baseUrl: testBase,
    connector: connector,
    sessionToken: () => 'st-1',
  );
  return NetworkSession(
    networkId: 'net1',
    identity: const JoinedIdentity(
      id: 'me-1',
      memberClass: MemberClass.guest,
      displayName: 'Me',
    ),
    client: client,
    ws: ws,
    wallet: wallet,
  );
}

/// A fake OAuth callback receiver (auth_flow seam): fixed loopback
/// redirect URI, [callback] resolves with [callbackUri] (or throws
/// [callbackError]); [closed] records teardown.
class FakeOAuthReceiver implements OAuthCallbackReceiver {
  FakeOAuthReceiver({this.callbackUri, this.callbackError});

  /// The URI [callback] resolves with (null → a null URI completes).
  final Uri? callbackUri;

  /// When set, [callback] throws it instead of resolving.
  final Object? callbackError;

  @override
  final Uri redirectUri = Uri.parse('http://127.0.0.1:5555/callback');

  bool closed = false;

  @override
  Future<Uri> get callback {
    final error = callbackError;
    if (error != null) return Future.error(error);
    return Future.value(callbackUri);
  }

  @override
  void close() => closed = true;
}

/// The default well-formed callback URI for sign-in tests.
final Uri kFakeOAuthCallback = Uri.parse(
  'http://127.0.0.1:5555/callback?code=temp-1&state=st-1',
);

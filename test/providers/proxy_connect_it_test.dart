// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// IT coverage for the per-provider proxy connectors (issue #1921):
/// fake HTTP-CONNECT and SOCKS5 servers (in-process dart:io sockets) in
/// front of a fake provider API. Deterministic, no external network, no
/// root.
///
/// The proxies COUNT connections and record the target identity they saw,
/// which is what makes the remote-DNS assertion honest: the provider host
/// is a name no local resolver could answer (`fah-proxy-target.test`), so
/// a completed request proves the NAME reached the proxy unresolved. A
/// direct listener bound on the real target port counts zero for the
/// duration of every proxied scenario (AC2/AC4: no direct egress).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/providers/proxy_connector.dart';
import 'package:flutter_agent_harness/src/providers/proxy_connector_io.dart';
import 'package:http/http.dart' as http;
import 'package:yaml/yaml.dart';
import 'package:test/test.dart';

const _fakeHost = 'fah-proxy-target.test';
const _sseBody =
    'data: {"id":"1","choices":[{"delta":{"content":"proxied-ok"}}]}\n\n'
    'data: {"id":"1","choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
    'data: [DONE]\n\n';

final _sseResponse =
    'HTTP/1.1 200 OK\r\n'
    'content-type: text/event-stream\r\n'
    'content-length: ${utf8.encode(_sseBody).length}\r\n'
    'connection: close\r\n'
    '\r\n'
    '$_sseBody';

final _sseError407 =
    'HTTP/1.1 407 Proxy Authentication Required\r\n'
    'Proxy-Authenticate: Basic realm="fah"\r\n'
    'Content-Length: 0\r\n\r\n';

Model _proxiedModel(int fakePort) => Model(
  id: 'test-model',
  name: 'Test model',
  api: 'openai-completions',
  provider: 'openai',
  baseUrl: 'http://$_fakeHost:$fakePort/v1',
  input: const ['text'],
  contextWindow: 128000,
  maxTokens: 16384,
  cost: const ModelCost(input: 0.15, output: 0.6, cacheRead: 0.075),
);

Context _simpleContext() =>
    Context(messages: [UserMessage.text('hi', timestamp: DateTime.utc(2026))]);

/// Reads one HTTP request head (bounded) off the already-attached
/// iterator — dart:io socket streams can never be listened twice, so
/// every fake shares this discipline.
Future<String> _readHead(StreamIterator<Uint8List> iterator) async {
  var total = 0;
  final seen = BytesBuilder(copy: false);
  while (true) {
    if (!await iterator.moveNext()) {
      throw StateError('peer closed before a head');
    }
    seen.add(iterator.current);
    total += iterator.current.length;
    final text = latin1.decode(seen.takeBytes(), allowInvalid: true);
    final end = text.indexOf('\r\n\r\n');
    if (end >= 0) return text.substring(0, end + 4);
    if (total > 65536) throw StateError('head exceeded 64 KiB');
  }
}

/// Pipes the attached [iterator] into [to]. A clean end just stops
/// piping — the caller tears the socket pair down once BOTH directions
/// end (an early destroy kills the response path; close() semantics vary
/// across dart:io versions). Flushes before returning.
Future<void> _pipe(StreamIterator<Uint8List> iterator, Socket to) async {
  try {
    while (await iterator.moveNext()) {
      to.add(iterator.current);
    }
    await to.flush();
  } on Object {
    to.destroy();
  }
}

/// Whether a `Proxy-Authorization: Basic …` header line is present.
bool hasBasicCredential(String headerLine) =>
    headerLine.toLowerCase().startsWith('proxy-authorization: basic ') &&
    headerLine.length > 'proxy-authorization: basic '.length;

(String, int) _targetOf(String requestLine) {
  final target = requestLine.split(' ').length > 1
      ? requestLine.split(' ')[1]
      : '';
  if (target.startsWith('http://') || target.startsWith('https://')) {
    final uri = Uri.parse(target);
    return (uri.host, uri.port == 0 ? 80 : uri.port);
  }
  final colon = target.lastIndexOf(':');
  if (colon <= 0) throw StateError('no target in "$requestLine"');
  final rawHost = target.substring(0, colon);
  final port = int.tryParse(target.substring(colon + 1));
  if (port == null) throw StateError('bad port in "$requestLine"');
  return (rawHost, port);
}

/// The fake provider API: answers every request head with the SSE body
/// (CONNECT probes get a 200 first). [connections] counts arrivals — the
/// zero-direct-egress probe reads this.
class FakeTarget {
  late final ServerSocket _socket;
  var connections = 0;

  int get port => _socket.port;

  Future<void> start() async {
    _socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _socket.listen((client) {
      connections++;
      Future<void> run() async {
        final iterator = StreamIterator<Uint8List>(client);
        final head = await _readHead(iterator);
        if (head.startsWith('CONNECT')) {
          client.add(
            ascii.encode('HTTP/1.1 200 Connection established\r\n\r\n'),
          );
        }
        client.add(utf8.encode(_sseResponse));
        await client.flush();
        client.destroy();
      }

      run().ignore();
    });
  }

  Future<void> close() => _socket.close();
}

/// The fake HTTP CONNECT proxy: records CONNECT targets and
/// Proxy-Authorization headers, scripts 407 challenges and mid-stream
/// death, and routes the faked hostname to the local [targetPort].
class FakeConnectProxy {
  FakeConnectProxy({
    required this.targetPort,
    this.challengeWith407 = false,
    this.killAfterConnect = false,
  });

  final int targetPort;
  final bool challengeWith407;
  final bool killAfterConnect;

  late final ServerSocket _socket;
  var connections = 0;
  final connectTargets = <String>[];
  final proxyAuthorization = <String>[];
  final responses = <String>[];

  /// The expected Basic credential value (base64 user:pass) — when set,
  /// the 407 script verifies it on the retry and keeps challenging on a
  /// mismatch (wrong-password scenarios).
  String? expectedAuth;

  /// Hostnames observed on forwarded (non-CONNECT) request lines — the
  /// remote-DNS proof for the absolute-form leg.
  final routedHosts = <String>[];

  int get port => _socket.port;

  Future<void> start() async {
    _socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _socket.listen((client) {
      connections++;
      Future<void> run() async {
        final iterator = StreamIterator<Uint8List>(client);
        final head = await _readHead(iterator);
        final requestLine = head.split('\r\n').first;
        final authorization = head
            .split('\r\n')
            .firstWhere(
              (l) => l.toLowerCase().startsWith('proxy-authorization:'),
              orElse: () => '',
            );
        if (requestLine.startsWith('CONNECT')) {
          connectTargets.add(requestLine.split(' ')[1]);
        }
        if (authorization.isNotEmpty) {
          proxyAuthorization.add(
            authorization.split(':').skip(1).join(':').trim(),
          );
        }

        if (challengeWith407 &&
            (!hasBasicCredential(authorization) ||
                (expectedAuth != null && authorization != expectedAuth))) {
          responses.add('407');
          client.add(ascii.encode(_sseError407));
          await client.flush();
          // dart:io retries on a fresh connection; this one is done.
          client.destroy();
          return;
        }
        if (requestLine.startsWith('CONNECT')) {
          responses.add('200');
          client.add(
            ascii.encode('HTTP/1.1 200 Connection established\r\n\r\n'),
          );
          await client.flush();
          if (killAfterConnect) {
            // The proxy dies right after the tunnel is acknowledged.
            client.destroy();
            return;
          }
          final (_, upstreamPort) = _targetOf(requestLine);
          final upstream = await _dial(upstreamPort);
          await Future.wait([
            _pipe(iterator, upstream),
            _pipe(StreamIterator<Uint8List>(upstream), client),
          ]);
          return;
        }
        // Plain-HTTP absolute-form target: forward verbatim.
        responses.add('forward');
        final (host, upstreamPort) = _targetOf(requestLine);
        routedHosts.add(host);
        final upstream = await _dial(upstreamPort);
        upstream.add(ascii.encode(head));
        await upstream.flush();
        await Future.wait([
          _pipe(iterator, upstream),
          _pipe(StreamIterator<Uint8List>(upstream), client),
        ]);
      }

      run().ignore();
    });
  }

  Future<void> close() => _socket.close();
}

/// The fake SOCKS5 server (RFC1928 + RFC1929). Records the greeting
/// methods, the RFC1929 attempts, and the CONNECT targets — the ATYP +
/// hostname bytes are the remote-DNS proof (AC3).
class FakeSocks5Server {
  FakeSocks5Server({
    required this.targetPort,
    this.user,
    this.password,
    this.failReplyCode,
  });

  final int targetPort;
  final String? user;
  final String? password;
  final int? failReplyCode;

  ServerSocket? _socket;
  var connections = 0;
  final offeredMethods = <List<int>>[];
  final authAttempts = <(String, String)>[];
  final connectTargets = <String>[];
  final connectAddressTypes = <int>[];
  var authChosen = false;
  var authFailed = false;

  int get port => _socket?.port ?? 0;

  Future<void> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _socket = server;
    server.listen((client) {
      connections++;
      _serve(client).ignore();
    });
  }

  Future<void> close() async {
    await _socket?.close();
  }

  Future<void> _serve(Socket client) async {
    try {
      final reader = _ByteReader(client);
      final version = (await reader.readExactly(1))[0];
      if (version != 0x05) throw StateError('not socks5');
      final methodCount = (await reader.readExactly(1))[0];
      final methods = await reader.readExactly(methodCount);
      offeredMethods.add(methods);

      final wantsAuth = user != null && methods.contains(0x02);
      if (wantsAuth) {
        authChosen = true;
        client.add([0x05, 0x02]);
        await reader.readExactly(1); // RFC1929 subnegotiation version
        final userLength = (await reader.readExactly(1))[0];
        final seenUser = utf8.decode(await reader.readExactly(userLength));
        final passLength = (await reader.readExactly(1))[0];
        final seenPass = utf8.decode(await reader.readExactly(passLength));
        authAttempts.add((seenUser, seenPass));
        final ok = seenUser == user && seenPass == password;
        if (!ok) authFailed = true;
        client.add([0x01, ok ? 0x00 : 0x01]);
        if (!ok) {
          await client.flush();
          client.destroy();
          return;
        }
      } else {
        client.add([0x05, 0x00]);
      }

      final ver = (await reader.readExactly(1))[0];
      final cmd = (await reader.readExactly(1))[0];
      if (ver != 0x05 || cmd != 0x01) throw StateError('bad connect');
      await reader.readExactly(1); // RSV
      final atyp = (await reader.readExactly(1))[0];
      connectAddressTypes.add(atyp);
      String host;
      switch (atyp) {
        case 0x01:
          host = InternetAddress.fromRawAddress(
            await reader.readExactly(4),
          ).address;
        case 0x03:
          final length = (await reader.readExactly(1))[0];
          host = utf8.decode(await reader.readExactly(length));
        case 0x04:
          host = InternetAddress.fromRawAddress(
            await reader.readExactly(16),
          ).address;
        default:
          throw StateError('bad atyp $atyp');
      }
      final portBytes = await reader.readExactly(2);
      final targetPortSeen = (portBytes[0] << 8) | portBytes[1];
      connectTargets.add('$host:$targetPortSeen');

      if (failReplyCode != null) {
        client.add([0x05, failReplyCode!, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        await client.flush();
        client.destroy();
        return;
      }
      client.add([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
      final Socket upstream;
      try {
        upstream = await _dial(targetPort);
      } on Object {
        // A real SOCKS5 server answers a failed dial with a failure code
        // (E3: the error must surface as a proxy-path failure, never a
        // silent hang).
        client.add([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
        await client.flush();
        client.destroy();
        return;
      }
      // The reader's iterator OWNS the client socket's stream (a dart:io
      // socket stream can never be listened twice) — continue on it.
      await Future.wait([
        _pipe(reader.iterator, upstream),
        _pipe(StreamIterator<Uint8List>(upstream), client),
      ]);
      client.destroy();
      upstream.destroy();
    } on Object {
      client.destroy();
    }
  }
}

/// A TLS-transport CONNECT proxy: the client TLS-hands with THIS (the
/// proxy) first, then CONNECT runs over the TLS channel (E6).
class FakeTlsConnectProxy {
  FakeTlsConnectProxy({required this.targetPort});

  final int targetPort;

  late final SecureServerSocket _socket;
  var connections = 0;
  final connectTargets = <String>[];

  int get port => _socket.port;

  Future<void> start() async {
    final context = SecurityContext()
      ..useCertificateChain('test/providers/fixtures/proxy_test_cert.pem')
      ..usePrivateKey('test/providers/fixtures/proxy_test_key.pem');
    _socket = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    _socket.listen((client) {
      connections++;
      Future<void> run() async {
        final iterator = StreamIterator<Uint8List>(client);
        final head = await _readHead(iterator);
        final requestLine = head.split('\r\n').first;
        connectTargets.add(requestLine.split(' ')[1]);
        client.add(ascii.encode('HTTP/1.1 200 Connection established\r\n\r\n'));
        await client.flush();
        final (_, upstreamPort) = _targetOf(requestLine);
        final upstream = await _dial(upstreamPort);
        await Future.wait([
          _pipe(iterator, upstream),
          _pipe(StreamIterator<Uint8List>(upstream), client),
        ]);
      }

      run().ignore();
    });
  }

  Future<void> close() => _socket.close();
}

/// A TLS variant of the fake target (self-signed fixture cert) so the
/// CONNECT tunnel legs run a REAL target handshake.
class FakeTlsTarget {
  late final SecureServerSocket _socket;
  var connections = 0;

  int get port => _socket.port;

  Future<void> start() async {
    final context = SecurityContext()
      ..useCertificateChain('test/providers/fixtures/proxy_test_cert.pem')
      ..usePrivateKey('test/providers/fixtures/proxy_test_key.pem');
    _socket = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    _socket.listen((client) {
      connections++;
      Future<void> run() async {
        final iterator = StreamIterator<Uint8List>(client);
        await _readHead(iterator);
        client.add(utf8.encode(_sseResponse));
        await client.flush();
        await client.close();
      }

      run().ignore();
    });
  }

  Future<void> close() => _socket.close();
}

Future<Socket> _dial(int port) =>
    Socket.connect(InternetAddress.loopbackIPv4, port);

/// Exact-byte reader for the fake SOCKS5 handshake.
class _ByteReader {
  _ByteReader(this.socket) : iterator = StreamIterator(socket);

  final Socket socket;
  final StreamIterator<Uint8List> iterator;
  final List<int> _buffer = [];

  Future<Uint8List> readExactly(int count) async {
    while (_buffer.length < count) {
      if (!await iterator.moveNext()) {
        throw StateError('socks peer closed mid-handshake');
      }
      _buffer.addAll(iterator.current);
    }
    final out = Uint8List.fromList(_buffer.sublist(0, count));
    _buffer.removeRange(0, count);
    return out;
  }
}

ProviderNetworkConfig _network(
  String proxy, {
  String? username,
  String? passwordEnv,
}) => ProviderNetworkConfig.fromYaml(
  loadYaml(
    'proxy: $proxy\n'
    '${username == null ? '' : 'proxyUsername: $username\n'}'
    '${passwordEnv == null ? '' : 'proxyPasswordEnv: $passwordEnv\n'}',
  ),
  configLabel: 'providers.kimi_me.network',
);

http.Client _client(
  String proxy, {
  String? username,
  String? passwordEnv,
  Map<String, String> env = const {},
  bool Function(X509Certificate)? onBadCertificate,
}) {
  final connector = ioProxyConnector(
    _network(proxy, username: username, passwordEnv: passwordEnv),
    onBadCertificate: onBadCertificate,
    environment: env,
    providerName: 'kimi_me',
  );
  return connector.createClient();
}

/// Runs one adapter turn over [client] and returns the rendered events.
Future<List<Object>> _runTurn(Model model, http.Client client) async {
  final stream = streamOpenAICompletions(
    model,
    _simpleContext(),
    const OpenAICompletionsOptions(apiKey: 'test-key'),
    client,
  );
  return stream.toList();
}

String _renderedText(List<Object> events) =>
    events.whereType<TextEndEvent>().map((e) => e.content).join();

void main() {
  group('http:// proxy (native CONNECT)', () {
    late FakeTarget target;
    FakeConnectProxy? proxy;

    setUp(() async {
      target = FakeTarget();
      await target.start();
      final p = FakeConnectProxy(targetPort: target.port);
      await p.start();
      proxy = p;
    });

    tearDown(() async {
      await proxy?.close();
      await target.close();
    });

    /// An https-target model over a TLS fake target (CONNECT leg).
    Future<Model> tlsModel() async {
      final tls = FakeTlsTarget();
      await tls.start();
      addTearDown(tls.close);
      return Model(
        id: 'test-model-tls',
        name: 'Test model TLS',
        api: 'openai-completions',
        provider: 'openai',
        baseUrl: 'https://$_fakeHost:${tls.port}/v1',
        input: const ['text'],
        contextWindow: 128000,
        maxTokens: 16384,
        cost: const ModelCost(input: 0.15, output: 0.6, cacheRead: 0.075),
      );
    }

    test('AC2: SSE arrives via the proxy; zero direct egress', () async {
      final client = _client('http://127.0.0.1:${proxy!.port}');
      final events = await _runTurn(_proxiedModel(target.port), client);
      client.close();

      // A plain-http target rides the proxy as an absolute-form request
      // (RFC 7230 §5.3.2): the hostname reaches the proxy, never a local
      // resolver.
      expect(proxy!.connections, 1);
      expect(proxy!.routedHosts, [
        _fakeHost,
      ], reason: 'the proxy saw the hostname unresolved (remote DNS)');
      expect(
        target.connections,
        1,
        reason: 'the fake API served the forwarded request',
      );
      expect(_renderedText(events), 'proxied-ok');
    });

    test('AC2: an https target tunnels through CONNECT (hostname '
        'unresolved, real target TLS)', () async {
      final tlsTarget = FakeTlsTarget();
      await tlsTarget.start();
      final tunnelProxy = FakeConnectProxy(targetPort: tlsTarget.port);
      await tunnelProxy.start();
      final client = _client(
        'http://127.0.0.1:${tunnelProxy.port}',
        onBadCertificate: (_) => true,
      );
      try {
        final model = Model(
          id: 'test-model',
          name: 'Test model',
          api: 'openai-completions',
          provider: 'openai',
          baseUrl: 'https://$_fakeHost:${tlsTarget.port}/v1',
          input: const ['text'],
          contextWindow: 128000,
          maxTokens: 16384,
          cost: const ModelCost(input: 0.15, output: 0.6, cacheRead: 0.075),
        );
        final events = await _runTurn(model, client);

        expect(tunnelProxy.connectTargets, [
          '$_fakeHost:${tlsTarget.port}',
        ], reason: 'CONNECT carries the hostname, unresolved');
        expect(tlsTarget.connections, 1);
        expect(_renderedText(events), 'proxied-ok');
      } finally {
        client.close();
        await tunnelProxy.close();
        await tlsTarget.close();
      }
    });

    test('AC4: proxy refused → immediate actionable error, zero direct '
        'egress', () async {
      // A dead proxy port: nothing ever listens there.
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = dead.port;
      await dead.close();

      final client = _client('http://127.0.0.1:$deadPort');
      final events = await _runTurn(_proxiedModel(target.port), client);
      client.close();

      expect(target.connections, 0, reason: 'no direct egress may happen');
      final error = events.whereType<ErrorEvent>().single;
      final message = error.error.errorMessage;
      expect(message, startsWith("Proxy for provider 'kimi_me' failed:"));
      expect(message, contains('fail-closed'));
      expect(message, contains('network.proxy'));
    });

    test(
      'AC4/E2: 407 → credentialed retry carries Basic auth, succeeds',
      () async {
        const password = 'correct-horse-battery-staple';
        // Proxy auth challenges fire on the CONNECT leg — an https target.
        final challenger = FakeConnectProxy(
          targetPort: target.port,
          challengeWith407: true,
        );
        await challenger.start();
        final client = _client(
          'http://127.0.0.1:${challenger.port}',
          username: 'fah-user',
          passwordEnv: 'FAH_TEST_PROXY_PW',
          env: {'FAH_TEST_PROXY_PW': password},
          onBadCertificate: (_) => true,
        );
        try {
          final events = await _runTurn(await tlsModel(), client);
          client.close();

          expect(challenger.responses, [
            '407',
            '200',
          ], reason: 'the challenge, then the credentialed retry');
          expect(
            challenger.proxyAuthorization,
            ['Basic ${base64Encode(utf8.encode('fah-user:$password'))}'],
            reason: 'the retry carried exactly the configured Basic credential',
          );
          expect(_renderedText(events), 'proxied-ok');
        } finally {
          await challenger.close();
        }
      },
    );

    test('AC6/E2: 407 with a wrong password → actionable error naming '
        'proxyPasswordEnv; the password never prints', () async {
      const wrongPassword = 'wrong-password-value';
      final challenger = FakeConnectProxy(
        targetPort: target.port,
        challengeWith407: true,
      );
      challenger.expectedAuth =
          'Basic ${base64Encode(utf8.encode('fah-user:right-password'))}';
      await challenger.start();
      final client = _client(
        'http://127.0.0.1:${challenger.port}',
        username: 'fah-user',
        passwordEnv: 'FAH_TEST_PROXY_PW',
        env: {'FAH_TEST_PROXY_PW': wrongPassword},
        onBadCertificate: (_) => true,
      );
      try {
        // The connector arms the credentials ONCE; the second 407 means
        // the password is wrong and must fail closed instead of looping.
        final events = await _runTurn(await tlsModel(), client);
        client.close();

        expect(challenger.responses, [
          '407',
          '407',
        ], reason: 'challenge, one credentialed retry, then the refusal');
        expect(challenger.connectTargets, hasLength(2));
        final error = events.whereType<ErrorEvent>().single;
        final message = error.error.errorMessage;
        expect(message, contains('proxyPasswordEnv'));
        expect(message, contains('fail-closed'));
        expect(
          message,
          isNot(contains(wrongPassword)),
          reason: 'the wrong password must never print in diagnostics',
        );
      } finally {
        client.close();
        await challenger.close();
      }
    });
  });

  group('https:// proxy (TLS transport)', () {
    late FakeTarget target;
    FakeTlsConnectProxy? proxy;

    setUp(() async {
      target = FakeTarget();
      await target.start();
    });

    tearDown(() async {
      await proxy?.close();
      await target.close();
    });

    test(
      'E6: CONNECT rides a TLS transport to the proxy; SSE completes',
      () async {
        final tls = FakeTlsTarget();
        await tls.start();
        addTearDown(tls.close);
        proxy = FakeTlsConnectProxy(targetPort: tls.port);
        await proxy!.start();
        final client = _client(
          'https://127.0.0.1:${proxy!.port}',
          onBadCertificate: (_) => true,
        );
        final model = Model(
          id: 'test-model-tls',
          name: 'Test model TLS',
          api: 'openai-completions',
          provider: 'openai',
          baseUrl: 'https://$_fakeHost:${tls.port}/v1',
          input: const ['text'],
          contextWindow: 128000,
          maxTokens: 16384,
          cost: const ModelCost(input: 0.15, output: 0.6, cacheRead: 0.075),
        );
        final events = await _runTurn(model, client);
        client.close();

        expect(proxy!.connections, 1);
        expect(proxy!.connectTargets, ['$_fakeHost:${tls.port}']);
        expect(tls.connections, 1);
        expect(_renderedText(events), 'proxied-ok');
      },
    );
  });

  group('socks5:// proxy (loopback relay)', () {
    late FakeTarget target;
    FakeSocks5Server? socks;

    setUp(() async {
      target = FakeTarget();
      await target.start();
    });

    tearDown(() async {
      await socks?.close();
      await target.close();
    });

    test('AC3: remote DNS — the hostname is sent unresolved to the proxy '
        'and the SSE stream completes', () async {
      final s = FakeSocks5Server(targetPort: target.port);
      await s.start();
      socks = s;
      final client = _client('socks5://127.0.0.1:${socks!.port}');
      final events = await _runTurn(_proxiedModel(target.port), client);
      client.close();

      expect(
        socks!.connectAddressTypes,
        [0x03],
        reason:
            'ATYP must be domain-name (remote DNS), never resolved '
            'IPs',
      );
      expect(socks!.connectTargets, ['$_fakeHost:${target.port}']);
      expect(socks!.offeredMethods, [
        [0x00],
      ], reason: 'no auth configured → only the no-auth method is offered');
      expect(target.connections, 1);
      expect(_renderedText(events), 'proxied-ok');
    });

    test('E4: RFC1929 user/pass rides the handshake when configured', () async {
      final s = FakeSocks5Server(
        targetPort: target.port,
        user: 'fah-user',
        password: 'socks-pass-1',
      );
      await s.start();
      socks = s;
      final client = _client(
        'socks5://127.0.0.1:${socks!.port}',
        username: 'fah-user',
        passwordEnv: 'FAH_TEST_SOCKS_PW',
        env: {'FAH_TEST_SOCKS_PW': 'socks-pass-1'},
      );
      final events = await _runTurn(_proxiedModel(target.port), client);
      client.close();

      expect(socks!.authChosen, isTrue);
      expect(socks!.offeredMethods, [
        [0x00, 0x02],
      ]);
      expect(socks!.authAttempts, [('fah-user', 'socks-pass-1')]);
      expect(_renderedText(events), 'proxied-ok');
    });

    test('AC4: wrong SOCKS5 password → actionable error naming '
        'proxyPasswordEnv; password never prints', () async {
      const wrongPassword = 'wrong-socks-password';
      final s = FakeSocks5Server(
        targetPort: target.port,
        user: 'fah-user',
        password: 'real-password',
      );
      await s.start();
      socks = s;
      final client = _client(
        'socks5://127.0.0.1:${socks!.port}',
        username: 'fah-user',
        passwordEnv: 'FAH_TEST_SOCKS_PW',
        env: {'FAH_TEST_SOCKS_PW': wrongPassword},
      );
      final events = await _runTurn(_proxiedModel(target.port), client);
      client.close();

      expect(socks!.authFailed, isTrue);
      expect(target.connections, 0);
      final error = events.whereType<ErrorEvent>().single;
      final message = error.error.errorMessage;
      expect(message, contains('proxyPasswordEnv'));
      expect(message, contains('fail-closed'));
      expect(message, isNot(contains(wrongPassword)));
      expect(message, isNot(contains('real-password')));
    });

    test('AC4: SOCKS5 proxy refused → immediate actionable error', () async {
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final deadPort = dead.port;
      await dead.close();

      socks = FakeSocks5Server(targetPort: target.port);
      // The socks5 client only reaches the fake through the dead port.
      final client = _client('socks5://127.0.0.1:$deadPort');
      final events = await _runTurn(_proxiedModel(target.port), client);
      client.close();

      expect(target.connections, 0);
      final error = events.whereType<ErrorEvent>().single;
      expect(
        error.error.errorMessage,
        startsWith("Proxy for provider 'kimi_me' failed:"),
      );
    });

    test('AC4/E3: proxy up but target refused through it → proxy-path '
        'error, no direct retry', () async {
      final deadTarget = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final deadTargetPort = deadTarget.port;
      await deadTarget.close();

      final s = FakeSocks5Server(targetPort: deadTargetPort);
      await s.start();
      socks = s;
      final client = _client('socks5://127.0.0.1:${socks!.port}');
      final events = await _runTurn(_proxiedModel(deadTargetPort), client);
      client.close();

      final error = events.whereType<ErrorEvent>().single;
      final message = error.error.errorMessage;
      expect(message, startsWith("Proxy for provider 'kimi_me' failed:"));
      expect(
        socks!.connections,
        1,
        reason:
            'the attempt went through the '
            'proxy',
      );
      expect(target.connections, 0);
    });

    test(
      'E4: two providers with different proxies get isolated clients',
      () async {
        final s = FakeSocks5Server(targetPort: target.port);
        await s.start();
        socks = s;
        final clientA = _client('socks5://127.0.0.1:${socks!.port}');
        final connectorB = ioProxyConnector(
          _network('socks5://127.0.0.1:${socks!.port}'),
          environment: const {},
          providerName: 'kimi_me',
        );
        final clientB = connectorB.createClient();
        expect(
          identical(clientA, clientB),
          isFalse,
          reason: 'no shared connection pool across proxy instances',
        );
        final eventsA = await _runTurn(_proxiedModel(target.port), clientA);
        final eventsB = await _runTurn(_proxiedModel(target.port), clientB);
        clientA.close();
        clientB.close();
        expect(_renderedText(eventsA), 'proxied-ok');
        expect(_renderedText(eventsB), 'proxied-ok');
      },
    );
  });

  group('fail-closed behaviors', () {
    late FakeTarget target;
    FakeConnectProxy? proxy;

    setUp(() async {
      target = FakeTarget();
      await target.start();
      final p = FakeConnectProxy(targetPort: target.port);
      await p.start();
      proxy = p;
    });

    tearDown(() async {
      await proxy?.close();
      await target.close();
    });

    test('E1: proxy dies mid-stream → the stream ends fail-closed with '
        'the actionable text', () async {
      final tls = FakeTlsTarget();
      await tls.start();
      final killer = FakeConnectProxy(
        targetPort: tls.port,
        killAfterConnect: true,
      );
      await killer.start();
      final client = _client(
        'http://127.0.0.1:${killer.port}',
        onBadCertificate: (_) => true,
      );
      final model = Model(
        id: 'test-model-tls',
        name: 'Test model TLS',
        api: 'openai-completions',
        provider: 'openai',
        baseUrl: 'https://$_fakeHost:${tls.port}/v1',
        input: const ['text'],
        contextWindow: 128000,
        maxTokens: 16384,
        cost: const ModelCost(input: 0.15, output: 0.6, cacheRead: 0.075),
      );
      final events = await _runTurn(model, client);
      client.close();
      await killer.close();
      await tls.close();

      final error = events.whereType<ErrorEvent>().single;
      final message = error.error.errorMessage;
      expect(message, startsWith("Proxy for provider 'kimi_me' failed:"));
      expect(message, contains('fail-closed'));
      expect(
        events.whereType<TextEndEvent>(),
        isEmpty,
        reason: 'no assistant content may surface from a dead proxy',
      );
    });

    test('E5: retries after a proxy failure stay on the proxy (zero '
        'direct egress)', () async {
      // The fake proxy 407-challenges the FIRST connection and tunnels
      // the retry — the same pattern as the E2 test, but through the
      // RETRY wrapper (transientRetryStreamFunction) to prove the retry
      // re-rides the proxied client.
      const password = 'retry-password-1';
      final tls = FakeTlsTarget();
      await tls.start();
      addTearDown(tls.close);
      final retryProxy = FakeConnectProxy(
        targetPort: tls.port,
        challengeWith407: true,
      );
      await retryProxy.start();
      final client = _client(
        'http://127.0.0.1:${retryProxy.port}',
        username: 'fah-user',
        passwordEnv: 'FAH_TEST_PROXY_PW',
        env: {'FAH_TEST_PROXY_PW': password},
        onBadCertificate: (_) => true,
      );
      try {
        final model = Model(
          id: 'test-model-tls',
          name: 'Test model TLS',
          api: 'openai-completions',
          provider: 'openai',
          baseUrl: 'https://$_fakeHost:${tls.port}/v1',
          input: const ['text'],
          contextWindow: 128000,
          maxTokens: 16384,
          cost: const ModelCost(input: 0.15, output: 0.6, cacheRead: 0.075),
        );
        final events = await _runTurn(model, client);
        expect(_renderedText(events), 'proxied-ok');
        expect(
          retryProxy.connections,
          greaterThanOrEqualTo(2),
          reason: 'the retry re-rode the proxied client',
        );
        expect(retryProxy.responses, ['407', '200']);
        expect(tls.connections, 1);
      } finally {
        client.close();
        await retryProxy.close();
      }
    });

    test('AC6: byte-scan — the password appears nowhere in the event '
        'stream text of success or failure paths', () async {
      const password = 'supersecret-proxy-pass';
      final okClient = _client(
        'http://127.0.0.1:${proxy!.port}',
        username: 'fah-user',
        passwordEnv: 'FAH_TEST_PROXY_PW',
        env: {'FAH_TEST_PROXY_PW': password},
      );
      final okEvents = await _runTurn(_proxiedModel(target.port), okClient);
      okClient.close();
      expect(
        okEvents.map((e) => e.toString()).join(),
        isNot(contains(password)),
      );
      expect(_renderedText(okEvents), isNot(contains(password)));
    });
  });
}

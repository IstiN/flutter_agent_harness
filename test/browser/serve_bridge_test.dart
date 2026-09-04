// The loopback bridge server end-to-end: pairing, mail relay both ways,
// keepalive, browserReq/browserRes correlation, teardown, and the loopback/
// origin/token-file invariants. Real dart:io WebSocket client against a
// real HttpServer on an ephemeral port; the fabric is a FileMessaging-
// Repository over a MemoryExecutionEnv.
@TestOn('vm')
@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../../bin/serve_bridge.dart';

const _messagesRoot = '/work/messages';
const _token =
    'abababababababababababababababababababababababababababababababab';

void main() {
  late MemoryExecutionEnv env;
  late FileMessagingRepository repo;
  late BridgeServer server;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    repo = FileMessagingRepository(env: env, root: _messagesRoot);
  });

  tearDown(() async {
    await server.stop();
    await server.done;
  });

  /// Starts a bridge server with fast timers and an ephemeral port.
  Future<BridgeServer> spin({
    Duration pollInterval = const Duration(milliseconds: 40),
    Duration heartbeatInterval = const Duration(milliseconds: 60),
    Duration dispatchTimeout = const Duration(milliseconds: 800),
    void Function(BridgeConnection)? onClient,
  }) async {
    final started = BridgeServer(
      messaging: repo,
      root: '/work',
      token: _token,
      version: '9.9.9',
      port: 0,
      pollInterval: pollInterval,
      heartbeatInterval: heartbeatInterval,
      dispatchTimeout: dispatchTimeout,
      onClient: onClient,
    );
    await started.start();
    return started;
  }

  /// A tiny scripted WebSocket extension client collecting inbound frames.
  Future<_ExtClient> connect({
    String? origin,
    String? token = _token,
    String agentId = 'e1',
  }) async {
    final socket = await WebSocket.connect(
      server.url,
      headers: origin == null ? null : {'origin': origin},
    );
    final client = _ExtClient(socket);
    client.send({
      'v': 1,
      'id': '1-hello1',
      'op': 'hello',
      'agentId': agentId,
      'name': 'Test Ext',
      'proto': 1,
      'token': ?token,
      'caps': ['tabs'],
    });
    return client;
  }

  group('pairing', () {
    test(
      'a valid hello is welcomed with the derived mailbox and capabilities',
      () async {
        server = await spin();
        final client = await connect();
        final welcome = await client.next();
        expect(welcome['op'], 'welcome');
        expect(welcome['id'], '1-hello1');
        expect(welcome['mailbox'], 'browser-ext/e1');
        expect(welcome['server'], 'fa/9.9.9');
        expect(welcome['capabilities'], ['mail', 'browser']);
        // The fabric mailbox is registered: the .id marker names it.
        final marker = await env
            .readTextFile('$_messagesRoot/browser-ext_e1/.id')
            .then((r) => r.getOrThrow());
        expect(marker, 'browser-ext/e1');
        await client.close();
      },
    );

    test('a hello without an agentId derives a random one', () async {
      server = await spin();
      final socket = await WebSocket.connect(server.url);
      final client = _ExtClient(socket);
      client.send({
        'v': 1,
        'id': '1-hello2',
        'op': 'hello',
        'proto': 1,
        'token': _token,
      });
      final welcome = await client.next();
      expect(welcome['mailbox'], startsWith('browser-ext/'));
      expect(
        (welcome['mailbox'] as String).substring('browser-ext/'.length),
        hasLength(8),
      );
      await client.close();
    });

    for (final (name, token) in [
      ('a wrong token', 'ff' * 32),
      ('an absent token', null),
    ]) {
      test('$name is rejected with bad_token and close 4401', () async {
        server = await spin();
        final client = await connect(token: token);
        final error = await client.next();
        expect(error['op'], 'error');
        expect(error['code'], 'bad_token');
        await client.done;
        expect(client.closeCode, bridgeBadTokenCloseCode);
      });
    }

    test('a hello with a mismatching proto is a proto error + close', () async {
      server = await spin();
      final socket = await WebSocket.connect(server.url);
      final client = _ExtClient(socket);
      client.send({
        'v': 1,
        'id': '1-hello3',
        'op': 'hello',
        'proto': 2,
        'token': _token,
      });
      final error = await client.next();
      expect(error['code'], 'proto');
      await client.done;
    });

    test('a non-hello first frame is rejected and the socket closed', () async {
      server = await spin();
      final socket = await WebSocket.connect(server.url);
      final client = _ExtClient(socket);
      client.send({'v': 1, 'id': '1-mail0', 'op': 'mail', 'to': 'main'});
      final error = await client.next();
      expect(error['code'], 'bad_frame');
      await client.done;
    });

    test('an envelope with a wrong version is a proto error + close', () async {
      server = await spin();
      final socket = await WebSocket.connect(server.url);
      final client = _ExtClient(socket);
      client.send({'v': 2, 'id': '1-x', 'op': 'ping'});
      final error = await client.next();
      expect(error['code'], 'proto');
      await client.done;
    });

    test(
      'an unknown op after pairing is a bad_op error, connection lives',
      () async {
        server = await spin();
        final client = await connect();
        await client.next(); // welcome
        client.send({'v': 1, 'id': '2-wat', 'op': 'wat'});
        final error = await client.next();
        expect(error['op'], 'error');
        expect(error['code'], 'bad_op');
        // Still alive: ping answers.
        client.send({'v': 1, 'id': '3-ping1', 'op': 'ping'});
        final pong = await client.next();
        expect(pong['op'], 'pong');
        expect(pong['id'], '3-ping1');
        await client.close();
      },
    );

    test('a non-loopback bind fails fast in the constructor', () {
      expect(
        () => BridgeServer(
          messaging: repo,
          root: '/work',
          token: _token,
          address: InternetAddress.anyIPv4,
        ),
        throwsArgumentError,
      );
    });

    test('an http origin is rejected before the upgrade', () async {
      server = await spin();
      await expectLater(
        WebSocket.connect(server.url, headers: {'origin': 'http://evil.test'}),
        throwsA(anything),
      );
      // A chrome-extension origin upgrades fine (the pairing tests rely on
      // the default origin-less client; here the allowed scheme).
      final ok = await WebSocket.connect(
        server.url,
        headers: {'origin': 'chrome-extension://abcdefg'},
      );
      await ok.close();
    });
  });

  group('mail relay', () {
    test('extension → fabric delivers and acks', () async {
      server = await spin();
      final client = await connect();
      await client.next(); // welcome
      client.send({
        'v': 1,
        'id': '2-mail1',
        'op': 'mail',
        'to': 'main',
        'text': 'hello from the extension',
      });
      final ack = await client.next();
      expect(ack['op'], 'acked');
      expect(ack['id'], '2-mail1');
      // The file fabric holds the message for the recipient.
      final inbox = await repo.peek('main');
      expect(inbox, hasLength(1));
      expect(inbox.single.fromId, 'browser-ext/e1');
      expect(inbox.single.text, 'hello from the extension');
      await client.close();
    });

    test('extension mail with kind=user is preserved', () async {
      server = await spin();
      final client = await connect();
      await client.next();
      client.send({
        'v': 1,
        'id': '2-mail2',
        'op': 'mail',
        'to': 'main',
        'text': 'user turn',
        'kind': 'user',
      });
      await client.next(); // ack
      final inbox = await repo.peek('main');
      expect(inbox.single.kind, AgentMessageKind.user);
      await client.close();
    });

    test('mail without text is a bad_args error', () async {
      server = await spin();
      final client = await connect();
      await client.next();
      client.send({'v': 1, 'id': '2-mail3', 'op': 'mail', 'to': 'main'});
      final error = await client.next();
      expect(error['op'], 'error');
      expect(error['code'], 'bad_args');
      expect(error['id'], '2-mail3');
      await client.close();
    });

    test('fabric → extension forwards with msgId and dedupes', () async {
      server = await spin();
      final client = await connect();
      await client.next(); // welcome
      await repo.send(
        AgentMessage(
          id: 'msg-1',
          fromId: 'main',
          toId: 'browser-ext/e1',
          text: 'first',
          sentAt: '2026-01-01T00:00:00.000Z',
        ),
      );
      final mail = await client.next();
      expect(mail['op'], 'mail');
      expect(mail['from'], 'main');
      expect(mail['text'], 'first');
      expect(mail['msgId'], 'msg-1');
      expect(mail['ts'], '2026-01-01T00:00:00.000Z');
      // The same fabric id again is NOT forwarded (bounded LRU dedupe).
      await repo.send(
        AgentMessage(
          id: 'msg-1',
          fromId: 'main',
          toId: 'browser-ext/e1',
          text: 'dupe',
          sentAt: '2026-01-01T00:00:01.000Z',
        ),
      );
      expect(
        await client.nextOrNull(const Duration(milliseconds: 250)),
        isNull,
        reason: 'duplicate msgId must not be forwarded',
      );
      await client.close();
    });

    test('the offline queue drains immediately on welcome', () async {
      server = await spin();
      // Mail arrives BEFORE the extension connects.
      await repo.send(
        AgentMessage(
          id: 'msg-early',
          fromId: 'main',
          toId: 'browser-ext/early',
          text: 'while you were away',
          sentAt: '2026-01-01T00:00:00.000Z',
        ),
      );
      final client = await connect(agentId: 'early');
      final welcome = await client.next();
      expect(welcome['op'], 'welcome');
      final mail = await client.next();
      expect(mail['op'], 'mail');
      expect(mail['msgId'], 'msg-early');
      await client.close();
    });
  });

  group('liveness', () {
    test('the heartbeat rewrites .heartbeat while connected', () async {
      server = await spin();
      final client = await connect();
      await client.next(); // welcome
      Future<String> heartbeatMs() async => env
          .readTextFile('$_messagesRoot/browser-ext_e1/.heartbeat')
          .then((r) => r.getOrThrow());
      final first = await heartbeatMs();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final second = await heartbeatMs();
      expect(int.parse(second), greaterThanOrEqualTo(int.parse(first)));
      await client.close();
    });

    test(
      'mail to a fresh fabric address acks and creates the mailbox',
      () async {
        server = await spin();
        final client = await connect();
        await client.next();
        client.send({
          'v': 1,
          'id': '2-mail4',
          'op': 'mail',
          'to': 'somewhere/new',
          'text': 'into the void',
        });
        final ack = await client.next();
        // The file fabric is at-least-once into directories: a fresh address
        // is a mailbox on disk, drained by whoever owns it later.
        expect(ack['op'], 'acked');
        final created = await repo.peek('somewhere/new');
        expect(created, hasLength(1));
        await client.close();
      },
    );
  });

  group('browserReq / browserRes', () {
    test(
      'dispatch correlates the flat browserRes on the envelope id',
      () async {
        BridgeConnection? connection;
        server = await spin(onClient: (c) => connection = c);
        final client = await connect();
        await client.next(); // welcome
        final future = connection!.dispatch('navigate', {'url': 'https://x'});
        final request = await client.next();
        expect(request['op'], 'browserReq');
        expect(request['id'], isNotEmpty);
        expect(request['req'], 'navigate');
        expect(request['args'], {'url': 'https://x'});
        // Flat reply: envelope id IS the correlation id (amended contract).
        client.send({
          'v': 1,
          'id': request['id'],
          'op': 'browserRes',
          'ok': true,
          'result': {'tabId': 7, 'url': 'https://x'},
        });
        expect(await future, {
          'ok': true,
          'result': {'tabId': 7, 'url': 'https://x'},
        });
        await client.close();
      },
    );

    test('a failed op resolves with the error result', () async {
      BridgeConnection? connection;
      server = await spin(onClient: (c) => connection = c);
      final client = await connect();
      await client.next();
      final future = connection!.dispatch('click', {'selector': '#gone'});
      final request = await client.next();
      client.send({
        'v': 1,
        'id': request['id'],
        'op': 'browserRes',
        'ok': false,
        'error': 'no tab',
        'code': 'no_tab',
      });
      expect(await future, {'ok': false, 'error': 'no tab', 'code': 'no_tab'});
      await client.close();
    });

    test('a hung client hits the dispatch timeout', () async {
      BridgeConnection? connection;
      server = await spin(
        onClient: (c) => connection = c,
        dispatchTimeout: const Duration(milliseconds: 120),
      );
      final client = await connect();
      await client.next();
      final future = connection!.dispatch('tabs', {});
      await client.next(); // the browserReq
      expect(await future, {
        'ok': false,
        'error': contains('timed out'),
        'code': 'timeout',
      });
      await client.close();
    });

    test(
      'a disconnect resolves pending dispatches with a clean error',
      () async {
        BridgeConnection? connection;
        server = await spin(onClient: (c) => connection = c);
        final client = await connect();
        await client.next();
        final future = connection!.dispatch('eval', {'code': '1+1'});
        await client.next(); // the browserReq
        await client.close();
        final result = await future;
        expect(result['ok'], isFalse);
        expect(result['error'], contains('disconnected'));
        expect(result['code'], 'no_target');
      },
    );

    test(
      'dispatch on an unpaired connection is a no_target error result',
      () async {
        BridgeConnection? connection;
        server = await spin(onClient: (c) => connection = c);
        final client = await connect(token: null); // never sends hello
        await Future<void>.delayed(const Duration(milliseconds: 50));
        final result = await connection!.dispatch('tabs', {});
        expect(result['ok'], isFalse);
        expect(result['error'], contains('no browser extension connected'));
        expect(result['code'], 'no_target');
        await client.close();
      },
    );

    test('task_end routes through the same dispatch path', () async {
      BridgeConnection? connection;
      server = await spin(onClient: (c) => connection = c);
      final client = await connect();
      await client.next();
      final future = connection!.dispatch('task_end', {});
      final request = await client.next();
      expect(request['req'], 'task_end');
      expect(request['args'], {});
      client.send({
        'v': 1,
        'id': request['id'],
        'op': 'browserRes',
        'ok': true,
        'result': {'cleaned': true},
      });
      expect(await future, {
        'ok': true,
        'result': {'cleaned': true},
      });
      await client.close();
    });
  });

  group('token file', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('bridge_tok'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('ensure mints once at mode 0600 and rotate replaces', () async {
      final tokens = BridgeTokenFile(temp.path);
      expect(tokens.path, '${temp.path}/.fah/bridge/token');
      final first = await tokens.ensure();
      expect(first, matches(RegExp(r'^[0-9a-f]{64}$')));
      final stat = FileStat.statSync(tokens.path);
      expect(stat.mode & 0x3FF, 384 /* 0600 octal */);
      // Mint-if-absent: the second read returns the same token.
      expect(await tokens.ensure(), first);
      // Rotate-on-demand: a fresh token, still 0600.
      final rotated = await tokens.rotate();
      expect(rotated, isNot(first));
      expect(await tokens.ensure(), rotated);
      expect(FileStat.statSync(tokens.path).mode & 0x3FF, 384 /* 0600 octal */);
    });

    test('ensure reuses an existing token file', () async {
      final dir = Directory.systemTemp.createTempSync('bridge_tok2');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/.fah/bridge/token')
        ..createSync(recursive: true)
        ..writeAsStringSync('${'cd' * 32}\n');
      expect(await BridgeTokenFile(dir.path).ensure(), 'cd' * 32);
    });
  });
}

/// Scripted extension client: collects frames, supports bounded waits and
/// quiet-window assertions.
final class _ExtClient {
  _ExtClient(this.socket) {
    _subscription = socket.listen(
      (data) => _frames.add(jsonDecode(data as String) as Map<String, dynamic>),
      onDone: () {
        if (!_done.isCompleted) _done.complete();
      },
      onError: (Object error) {
        if (!_done.isCompleted) _done.completeError(error);
      },
      cancelOnError: true,
    );
  }

  final WebSocket socket;
  final List<Map<String, dynamic>> _frames = [];
  final Completer<void> _done = Completer();
  StreamSubscription<dynamic>? _subscription;

  /// The close code observed by the server-side close handshake.
  int? get closeCode => socket.closeCode;

  void send(Map<String, dynamic> frame) => socket.add(jsonEncode(frame));

  /// The next inbound frame, failing after [timeout].
  Future<Map<String, dynamic>> next({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_frames.isNotEmpty) return _frames.removeAt(0);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw TimeoutException('no frame arrived; buffered: $_frames');
  }

  /// The next inbound frame, or null when the channel stays quiet.
  Future<Map<String, dynamic>?> nextOrNull(Duration quiet) async {
    try {
      return await next(timeout: quiet);
    } on TimeoutException {
      return null;
    }
  }

  Future<void> get done => _done.future;

  Future<void> close() async {
    await _subscription?.cancel();
    await socket.close();
  }
}

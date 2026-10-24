// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

@TestOn('vm || chrome')
library;

import 'dart:async';
import 'dart:convert';

import 'package:fa/sandbox/fs_persistence.dart';
import 'package:fa/sandbox/persistent_web_env.dart';
import 'package:fa/services/agent_network_transport.dart' as platform;
import 'package:fa/services/agent_network_transport_web.dart';
import 'package:fa/services/dap_enrollment_service.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  const credential = 'test only + browser credential &';
  const channel =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

  test('conditional platform export has a real supported transport', () {
    expect(platform.agentNetworkSupported, isTrue);
    expect(platform.platformHubTransport, isNotNull);
  });

  test(
    'browser bearer uses token and keyless public join still works',
    () async {
      final socket = _FakeSocket();
      Uri? dialed;
      final transport = WebHubTransport(
        connector: (url) async {
          dialed = url;
          return socket;
        },
      );
      final repository = HubMessagingRepository(
        url: Uri.parse('wss://hub.fa1.dev/ws?existing=a%20b'),
        transport: transport,
        identity: await HubIdentity.generate(),
        clientSecret: credential,
      );
      addTearDown(repository.dispose);

      await repository.start();
      await repository.joinChannel(channel);

      expect(dialed!.queryParameters['token'], credential);
      expect(dialed!.queryParameters['existing'], 'a b');
      final join = socket.frames.singleWhere((frame) => frame['op'] == 'join');
      expect(join['channel'], channel);
      expect(join['chanPubkey'], isEmpty);
      expect(repository.isConnected, isTrue);
    },
  );

  test('unauthenticated browser dial does not invent a credential', () async {
    Uri? dialed;
    final transport = WebHubTransport(
      connector: (url) async {
        dialed = url;
        return _FakeSocket();
      },
    );
    await transport.connect(Uri.parse('wss://hub.fa1.dev/ws'));
    expect(dialed!.hasQuery, isFalse);
  });

  test('dial failures never expose the credentialed URL', () async {
    final transport = WebHubTransport(
      connector: (url) async => throw StateError('dial failed for $url'),
    );
    final url = Uri.parse('wss://hub.fa1.dev/ws');
    final error = await transport
        .connectWithBearer(url, credential)
        .then<Object?>((_) => null)
        .catchError((Object error) => error);
    expect(error, isA<StateError>());
    expect(error.toString(), 'Bad state: hub WebSocket connection failed');
    expect(error.toString().contains(credential), isFalse);
    expect(error.toString().contains(url.toString()), isFalse);
  });

  test('browser socket filters binary frames and tracks close', () async {
    final channel = _FakeWebSocketChannel();
    final socket = WebHubSocket(channel);
    final received = <String>[];
    final subscription = socket.messages.listen(received.add);
    addTearDown(subscription.cancel);

    channel.inbound.add('hello');
    channel.inbound.add(<int>[1, 2, 3]);
    await socket.send('outbound');
    await Future<void>.delayed(Duration.zero);
    expect(received, ['hello']);
    expect(channel.fakeSink.added, ['outbound']);
    expect(socket.isOpen, isTrue);

    await channel.inbound.close();
    await Future<void>.delayed(Duration.zero);
    expect(socket.isOpen, isFalse);
    await socket.close();
  });

  test('web identity and enrollment survive a sandbox restore', () async {
    final snapshots = InMemoryFsSnapshotStore();
    final env = await PersistentWebExecutionEnv.restore(
      MemoryExecutionEnv(cwd: '/app'),
      snapshots,
      persistDelay: Duration.zero,
    );
    final path = identityPathFor('/app/dap/project-scope')!;
    final created = await loadOrCreateIdentity(env, path);
    final enrollments = await DapEnrollmentStore.load(
      env,
      projectCwd: '/work/project',
    );
    final bundle = parseDapJoinBundle(
      "fa dap import 'wss://hub.fa1.dev/ws?channel=$channel' && "
      'DAP_HUB_URL=wss://hub.fa1.dev/ws '
      "DAP_CLIENT_SECRET='$credential' DAP_AGENT_NAME=web-agent fa",
    );
    await enrollments.save(bundle);
    await env.flush();
    env.dispose();

    final restoredEnv = await PersistentWebExecutionEnv.restore(
      MemoryExecutionEnv(cwd: '/app'),
      snapshots,
      persistDelay: Duration.zero,
    );
    addTearDown(restoredEnv.dispose);
    final restored = await loadOrCreateIdentity(restoredEnv, path);
    final restoredEnrollments = await DapEnrollmentStore.load(
      restoredEnv,
      projectCwd: '/work/project',
    );

    expect(restored!.agentId, created!.agentId);
    expect(restored.signingPubkeyB64, created.signingPubkeyB64);
    expect(restored.dhPubkeyB64, created.dhPubkeyB64);
    expect(restoredEnrollments.enrollment?.invite.channel, channel);
    expect(restoredEnrollments.enrollment?.clientSecret, credential);
    expect(restoredEnrollments.enrollment?.agentName, 'web-agent');
  });
}

final class _FakeSocket implements HubSocket {
  final _messages = StreamController<String>.broadcast();
  final frames = <Map<String, dynamic>>[];
  bool _open = true;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  bool get isOpen => _open;

  @override
  Future<void> send(String text) async {
    final frame = (jsonDecode(text) as Map).cast<String, dynamic>();
    frames.add(frame);
    switch (frame['op']) {
      case 'hello':
        _messages.add(jsonEncode({'op': 'welcome', 'agentId': 'fake-agent'}));
      case 'join':
        _messages.add(
          jsonEncode({'op': 'joined', 'channel': frame['channel']}),
        );
      case 'flush':
        _messages.add(jsonEncode({'op': 'flushed', 'count': 0}));
    }
  }

  @override
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    await _messages.close();
  }
}

final class _FakeWebSocketChannel implements WebSocketChannel {
  final inbound = StreamController<Object?>();
  final fakeSink = _FakeWebSocketSink();

  @override
  Future<void> get ready => Future.value();

  @override
  Stream<Object?> get stream => inbound.stream;

  @override
  WebSocketSink get sink => fakeSink;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeWebSocketSink implements WebSocketSink {
  final added = <Object?>[];
  final _done = Completer<void>();
  bool closed = false;

  @override
  void add(Object? data) => added.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<Object?> stream) => stream.forEach(add);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    if (closed) return;
    closed = true;
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;
}

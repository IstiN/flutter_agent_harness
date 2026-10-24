// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:fa/services/agent_network_controller.dart';
import 'package:fa/services/dap_enrollment_service.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  const credential = 'test-only-enrollment-credential';
  const invite = 'wss://hub.fa1.dev/ws?channel=$channel';

  test(
    'native enrollment joins keyless, persists, and wires the live fabric',
    () async {
      final env = MemoryExecutionEnv(cwd: '/app');
      final file = _fileLayer(env);
      final fabric = SwappableMessagingRepository(file);
      final transport = _FakeTransport(expectedCredential: credential);
      final identityPaths = <String?>[];
      final enrollments = DapEnrollmentStore.inMemory();
      final controller = AgentNetworkController(
        env: env,
        fileLayer: file,
        fileFabric: fabric,
        transport: transport,
        loadIdentity: (path) async {
          identityPaths.add(path);
          return HubIdentity.generate();
        },
        enrollmentStore: enrollments,
        projectCwd: '/work/project',
      );
      addTearDown(controller.dispose);

      await controller.joinEnrollment(
        parseDapJoinBundle(
          "fa dap import '$invite' && DAP_HUB_URL=wss://hub.fa1.dev/ws "
          "DAP_CLIENT_SECRET='$credential' DAP_AGENT_NAME=app-agent fa",
        ),
      );

      expect(controller.state, HubLinkState.connected);
      expect(transport.acceptedCredential, isTrue);
      expect(transport.unauthenticatedDials, 0);
      final socket = transport.sockets.single;
      final join = socket.frames.singleWhere((frame) => frame['op'] == 'join');
      expect(join['channel'], channel);
      expect(join['chanPubkey'], isEmpty, reason: 'public join mints no key');
      expect(enrollments.enrollment, isNotNull);
      expect(
        identityPaths.single!.contains(
          dapEnrollmentProjectScope('/work/project'),
        ),
        isTrue,
      );

      // Outbound agent_message routing uses the same composite fabric.
      await fabric.send(
        AgentMessage(
          id: 'outbound-1',
          fromId: 'main',
          toId: '#$channel',
          text: 'hello channel',
          sentAt: '2026-01-01T00:00:00Z',
        ),
      );
      final sent = socket.frames.singleWhere((frame) => frame['op'] == 'send');
      expect(sent['channel'], channel);
      final publicPayload = jsonDecode(
        utf8.decode(base64Decode(sent['ciphertext'] as String)),
      );
      expect(publicPayload, {'text': 'hello channel'});

      // Inbound public mail arrives through the existing primary mailbox.
      socket.emit({
        'op': 'msg',
        'id': 'inbound-1',
        'from': 'peer-agent',
        'ts': 1767225600000,
        'channel': channel,
        'ciphertext': base64Encode(
          utf8.encode(jsonEncode({'text': 'channel reply'})),
        ),
      });
      await _waitUntil(() async => (await fabric.peek('main')).isNotEmpty);
      final mail = await fabric.drain('main');
      expect(mail.single.text, 'channel reply');
      expect(mail.single.toId, '#$channel');
    },
  );

  test('private invite imports pub/priv into the join frame', () async {
    final env = MemoryExecutionEnv(cwd: '/app');
    final file = _fileLayer(env);
    final fabric = SwappableMessagingRepository(file);
    final transport = _FakeTransport();
    final controller = AgentNetworkController(
      env: env,
      fileLayer: file,
      fileFabric: fabric,
      transport: transport,
      loadIdentity: (_) async => HubIdentity.generate(),
      enrollmentStore: DapEnrollmentStore.inMemory(),
      projectCwd: '/work/project',
    );
    addTearDown(controller.dispose);
    final pub = base64Encode(List<int>.filled(32, 1));
    final priv = base64Encode(List<int>.filled(32, 2));

    await controller.joinEnrollment(
      parseDapJoinBundle('$invite#pub=$pub&priv=$priv'),
    );

    final join = transport.sockets.single.frames.singleWhere(
      (frame) => frame['op'] == 'join',
    );
    expect(join['chanPubkey'], pub);
    expect(transport.unauthenticatedDials, 1);
  });
}

FileMessagingRepository _fileLayer(MemoryExecutionEnv env) =>
    FileMessagingRepository(
      env: env,
      root: '/sessions/--work--/messages',
      homeDir: null,
      decodeSessionCwd: decodeSessionCwd,
    );

Future<void> _waitUntil(FutureOr<bool> Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!await predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('condition did not arrive');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

final class _FakeTransport implements HubTransport, HubBearerTransport {
  _FakeTransport({this.expectedCredential});

  final String? expectedCredential;
  final sockets = <_FakeSocket>[];
  bool acceptedCredential = false;
  int unauthenticatedDials = 0;

  @override
  Future<HubSocket> connect(Uri url) async {
    unauthenticatedDials++;
    return _open();
  }

  @override
  Future<HubSocket> connectWithBearer(Uri url, String secret) async {
    acceptedCredential = secret == expectedCredential;
    return _open();
  }

  _FakeSocket _open() {
    final socket = _FakeSocket();
    sockets.add(socket);
    return socket;
  }
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
        emit({'op': 'welcome', 'agentId': 'fake-agent'});
      case 'join':
        emit({'op': 'joined', 'channel': frame['channel']});
      case 'presence_query':
        emit({'op': 'presence', 'replyTo': frame['id'], 'agents': const []});
      case 'flush':
        emit({'op': 'flushed', 'count': 0});
    }
  }

  void emit(Map<String, dynamic> frame) => _messages.add(jsonEncode(frame));

  @override
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    await _messages.close();
  }
}

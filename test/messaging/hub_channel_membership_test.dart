// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/messaging/hub_crypto.dart';
import 'package:test/test.dart';

void main() {
  const channel =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  const credential = 'test-only-enrollment-credential';

  test(
    'public membership: auth, resolve, outbound/inbound, own-echo drop',
    () async {
      final identity = await HubIdentity.generate();
      final transport = _FakeTransport(expectedCredential: credential);
      final repo = _repo(identity, transport, clientSecret: credential);
      addTearDown(repo.dispose);
      await repo.start();
      await repo.joinChannel(channel);

      expect(transport.acceptedCredential, isTrue);
      expect(transport.unauthenticatedDials, 0);
      expect(await repo.resolveTarget('#$channel'), '#$channel');
      expect(await repo.resolveTarget('#not-a-member'), isNull);
      final socket = transport.sockets.single;
      final join = socket.frames.singleWhere((frame) => frame['op'] == 'join');
      expect(join['chanPubkey'], isEmpty, reason: 'keyless means no chankey');

      await repo.send(_message(channel, 'public outbound'));
      final sent = socket.frames.singleWhere((frame) => frame['op'] == 'send');
      expect(sent['channel'], channel);
      expect(_publicDecode(sent['ciphertext'] as String), 'public outbound');

      // Own fan-out is not steering. A following peer frame must be the only
      // inbox entry after both asynchronous handlers have settled.
      socket.emit(_publicFrame(channel, identity.agentId, 'own echo', 'own-1'));
      socket.emit(_publicFrame(channel, 'peer', 'public inbound', 'peer-1'));
      await _waitUntil(() async => (await repo.peek('main')).isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final messages = await repo.drain('main');
      expect(messages, hasLength(1));
      expect(messages.single.text, 'public inbound');
      expect(messages.single.toId, '#$channel');
    },
  );

  test(
    'keyed invite imports pub/priv and round-trips channel crypto',
    () async {
      final identity = await HubIdentity.generate();
      final sender = await HubIdentity.generate();
      final channelPair = await X25519().newKeyPair();
      final channelData = await channelPair.extract();
      final transport = _FakeTransport(peer: sender);
      final repo = _repo(identity, transport);
      addTearDown(repo.dispose);
      final pub = base64Encode(channelData.publicKey.bytes);
      final priv = base64Encode(await channelPair.extractPrivateKeyBytes());
      await repo.start();
      await repo.joinChannel(
        channel,
        keys: HubChannelKeys(pub: pub, priv: priv),
      );

      final socket = transport.sockets.single;
      final join = socket.frames.singleWhere((frame) => frame['op'] == 'join');
      expect(join['chanPubkey'], pub);

      await repo.send(_message(channel, 'keyed outbound'));
      final sent = socket.frames.singleWhere((frame) => frame['op'] == 'send');
      final outbound = await hubDecryptPayloadWithKeyPair(
        recipientDhKeyPair: channelPair,
        senderDhPubkey: identity.dhPublicKey,
        frameId: sent['id'] as String,
        aadTarget: channel,
        ciphertextB64: sent['ciphertext'] as String,
      );
      expect(outbound, 'keyed outbound');

      const frameId = 'keyed-inbound-1';
      socket.emit({
        'op': 'msg',
        'id': frameId,
        'from': sender.agentId,
        'ts': 1767225600000,
        'channel': channel,
        'ciphertext': await hubEncryptPayload(
          sender: sender,
          recipientDhPubkey: channelData.publicKey,
          frameId: frameId,
          aadTarget: channel,
          plaintext: 'keyed inbound',
        ),
      });
      await _waitUntil(() async => (await repo.peek('main')).isNotEmpty);
      final messages = await repo.drain('main');
      expect(messages.single.text, 'keyed inbound');
      expect(messages.single.toId, '#$channel');
    },
  );

  test(
    'reconnect restores membership before draining an outbound send',
    () async {
      final identity = await HubIdentity.generate();
      final transport = _FakeTransport();
      final repo = _repo(identity, transport);
      addTearDown(repo.dispose);
      await repo.start();
      await repo.joinChannel(channel);
      final first = transport.sockets.single;
      final disconnected = repo.stateChanges.firstWhere(
        (state) => state == HubLinkState.disconnected,
      );
      await first.drop();
      await disconnected;

      // This queues while disconnected and must not race ahead of join after
      // the next welcome.
      await repo.send(_message(channel, 'after reconnect'));
      await _waitUntil(() async => transport.sockets.length >= 2);
      final second = transport.sockets[1];
      await _waitUntil(
        () async => second.frames.any((frame) => frame['op'] == 'send'),
      );
      final operations = second.frames
          .map((frame) => frame['op'])
          .where((op) => op == 'join' || op == 'send')
          .toList();
      expect(operations, ['join', 'send']);
      expect(second.frames.last['channel'], channel);
    },
  );

  test('access_denied completes join with an error', () async {
    final identity = await HubIdentity.generate();
    final transport = _FakeTransport(denyJoins: true);
    final repo = _repo(identity, transport);
    addTearDown(repo.dispose);
    await repo.start();
    await expectLater(repo.joinChannel(channel), throwsStateError);
  });

  test(
    'waitForConnection times out without leaking transport errors',
    () async {
      final identity = await HubIdentity.generate();
      final transport = _FakeTransport(refuseConnections: true);
      final repo = _repo(identity, transport);
      addTearDown(repo.dispose);
      await repo.start();
      await expectLater(
        repo.waitForConnection(timeout: const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>()),
      );
    },
  );
}

HubMessagingRepository _repo(
  HubIdentity identity,
  _FakeTransport transport, {
  String? clientSecret,
}) => HubMessagingRepository(
  url: Uri.parse('wss://fake.test/ws'),
  transport: transport,
  identity: identity,
  clientSecret: clientSecret,
  backoff: (_) => const Duration(milliseconds: 1),
);

AgentMessage _message(String channel, String text) => AgentMessage(
  id: 'out-${text.replaceAll(' ', '-')}',
  fromId: 'main',
  toId: '#$channel',
  text: text,
  sentAt: '2026-01-01T00:00:00Z',
);

Map<String, dynamic> _publicFrame(
  String channel,
  String from,
  String text,
  String id,
) => {
  'op': 'msg',
  'id': id,
  'from': from,
  'ts': 1767225600000,
  'channel': channel,
  'ciphertext': base64Encode(utf8.encode(jsonEncode({'text': text}))),
};

String _publicDecode(String ciphertext) {
  final decoded = jsonDecode(utf8.decode(base64Decode(ciphertext)));
  return (decoded as Map)['text'] as String;
}

Future<void> _waitUntil(FutureOr<bool> Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!await predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('condition did not arrive');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

final class _FakeTransport implements HubTransport, HubBearerTransport {
  _FakeTransport({
    this.expectedCredential,
    this.peer,
    this.denyJoins = false,
    this.refuseConnections = false,
  });

  final String? expectedCredential;
  final HubIdentity? peer;
  final bool denyJoins;
  final bool refuseConnections;
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

  Future<HubSocket> _open() async {
    if (refuseConnections) throw StateError('offline');
    final socket = _FakeSocket(peer: peer, denyJoins: denyJoins);
    sockets.add(socket);
    return socket;
  }
}

final class _FakeSocket implements HubSocket {
  _FakeSocket({this.peer, this.denyJoins = false});

  final HubIdentity? peer;
  final bool denyJoins;
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
        if (denyJoins) {
          emit({'op': 'error', 'code': 'access_denied'});
        } else {
          emit({'op': 'joined', 'channel': frame['channel']});
        }
      case 'whois':
        final peer = this.peer;
        if (peer != null) {
          emit({
            'op': 'agent_info',
            'agentId': peer.agentId,
            'replyTo': frame['id'],
            'online': true,
            'sign': peer.signingPubkeyB64,
            'x25519': peer.dhPubkeyB64,
          });
        }
      case 'flush':
        emit({'op': 'flushed', 'count': 0});
    }
  }

  void emit(Map<String, dynamic> frame) {
    if (_open) _messages.add(jsonEncode(frame));
  }

  Future<void> drop() async {
    if (!_open) return;
    _open = false;
    await _messages.close();
  }

  @override
  Future<void> close() => drop();
}

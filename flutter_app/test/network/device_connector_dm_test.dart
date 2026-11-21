// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/network/device_dm_session_host.dart';
import 'package:fa/network/envelope_codec.dart';
import 'package:flutter_agent_harness/src/network/connector/device_dm.dart';
import 'package:flutter_agent_harness/src/network/connector/device_dm_keys.dart';
import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
import 'package:flutter_agent_harness/src/network/connector/machine_connector.dart';
import 'package:flutter_agent_harness/src/network/connector/presence_engine.dart'
    show AgentRunState;
import 'package:flutter_test/flutter_test.dart';

import 'device_connector_service_test.dart' as fixture;
import 'fakes.dart';

final class _FakeDmSessionHost implements DeviceDmSessionHost {
  _FakeDmSessionHost(this.reply);

  final String? reply;
  final calls = <({String? sessionId, String text})>[];

  @override
  Future<String?> deliverUserText({
    String? sessionId,
    required String text,
  }) async {
    calls.add((sessionId: sessionId, text: text));
    return reply;
  }
}

void main() {
  const codec = EnvelopeCodec();

  FakeHttpClient http() => FakeHttpClient()
    ..respond(
      200,
      body:
          '{"deviceId":"dev-1","deviceToken":"dt-secret",'
          '"personalNetwork":{"id":"net-personal"}}',
    )
    ..respond(200, body: '{"ticket":"tk-1"}')
    ..respond(200, body: '{"ticket":"tk-2"}');

  Future<void> waitFor(bool Function() condition) async {
    for (var i = 0; i < 200; i++) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('DM condition not met within 2s');
  }

  NetworkEnvelope rosterWithDmPub(String deviceId, String dmPub) =>
      NetworkEnvelope(
        kind: NetworkEnvelopeKind.roster,
        msgId: 'roster-dm-1',
        network: 'net-personal',
        ts: '2026-11-12T10:00:00.000Z',
        payload: {
          'devices': [
            {
              'deviceId': deviceId,
              'name': deviceId,
              'agents': [
                {
                  'name': 'goal',
                  'state': 'live',
                  'exposed': true,
                  'dmPub': dmPub,
                },
              ],
            },
          ],
        },
      );

  test('sendDmToAgent seals with minted msgId and roster dmPub', () async {
    final remote = await EnvelopeCodec.newX25519KeyPair();
    final (service, manager, _, transport, _) = await fixture.buildService(
      httpClient: http(),
      tokenStore: fixture.enrolledTokens(),
      userIdProvider: () async => 'user-1',
      idFactory: () => 'dm-frame-1',
    );
    addTearDown(service.dispose);
    await service.start();
    await fixture.pumpUntilOnline(service);
    transport.sockets.first.serverSends(
      rosterWithDmPub('remote-dev', remote.pub),
    );
    await waitFor(() => service.currentRosterFrames.isNotEmpty);
    transport.sockets.first.serverSends(
      NetworkEnvelope(
        kind: NetworkEnvelopeKind.roster,
        msgId: 'roster-dm-patch',
        network: 'net-personal',
        ts: '2026-11-12T10:00:01.000Z',
        payload: {
          'devices': [
            {'deviceId': 'remote-dev', 'name': 'remote-dev'},
          ],
        },
      ),
    );
    await waitFor(
      () => service.currentRosterFrames.single.msgId == 'roster-dm-patch',
    );

    final msgId = await service.sendDmToAgent(
      deviceId: 'remote-dev',
      agentName: 'goal',
      sessionId: 'session-offline',
      text: 'hello remote',
    );

    expect(msgId, 'dm-frame-1');
    await waitFor(
      () => transport.sockets.first.sent.any(
        (frame) => frame.kind == NetworkEnvelopeKind.mail,
      ),
    );
    final sent = transport.sockets.first.sent.singleWhere(
      (frame) => frame.kind == NetworkEnvelopeKind.mail,
    );
    const channel = 'dm:user:user-1:goal@remote-dev';
    expect(
      await service.dmChannelForAgent(
        deviceId: 'remote-dev',
        agentName: 'goal',
      ),
      channel,
    );
    expect(sent.msgId, msgId);
    expect(sent.network, 'net-personal');
    expect(sent.channel, channel);
    expect(sent.from, 'user:user-1');
    expect(sent.to, 'goal@remote-dev');
    final opened = await codec.decrypt(
      channelKeyPair: await codec.keyPairFromPriv(remote.priv),
      frameId: msgId,
      aadTarget: channel,
      payloadB64: sent.ciphertext!,
    );
    expect(opened.senderPub, manager.wallet.identityPub);
    expect(jsonDecode(opened.plaintext), {
      'text': 'hello remote',
      'sessionId': 'session-offline',
      'threading': 1,
    });
  });

  test(
    'same-account CLI reply with a foreign id is delivered, not echo-dropped',
    () async {
      final agent = await EnvelopeCodec.newX25519KeyPair();
      final (service, manager, _, transport, _) = await fixture.buildService(
        httpClient: http(),
        tokenStore: fixture.enrolledTokens(),
        userIdProvider: () async => 'user-1',
      );
      addTearDown(service.dispose);
      await manager.wallet.createIfMissing();
      await service.start();
      await fixture.pumpUntilOnline(service);
      final received = <NetworkEnvelope>[];
      final subscription = service.dmMail.listen(received.add);
      addTearDown(subscription.cancel);
      final rejections = <RejectedMail>[];
      final rejectionSubscription = service.connector!.rejections.listen(
        rejections.add,
      );
      addTearDown(rejectionSubscription.cancel);

      const sessionId = '01a0ca2d-783a-78a0-8217-0533f83f8912';
      const deviceId =
          '3d87abcbe6428ec5222d1062c6d0b93a9792a7b4467e2ccddc29f25d551bcb22';
      const channel = 'dm:user:user-1:$sessionId@$deviceId';
      const replyId = 'cli-reply-foreign-id';
      const replyText =
          'Привет! По AIIN активной кодовой задачи нет; фикс availability задеплоен.';
      final ciphertext = await codec.encrypt(
        senderIdentity: await codec.keyPairFromPriv(agent.priv),
        channelPub: codec.publicKeyFromB64(manager.wallet.identityPub!),
        frameId: replyId,
        aadTarget: channel,
        plaintext: jsonEncode({
          'text': replyText,
          'sessionId': sessionId,
          'replyTo': 'app-outbound-1',
        }),
      );

      // This is the deployed relay shape: the authenticated CLI sender is
      // rewritten to the SAME account uid as the recipient. Its foreign id
      // proves this is not an echo of an envelope minted by this connector.
      transport.sockets.first.serverSends(
        NetworkEnvelope(
          kind: NetworkEnvelopeKind.mail,
          msgId: replyId,
          network: 'net-personal',
          channel: channel,
          from: 'user:user-1',
          to: 'user:user-1',
          ts: '2026-11-20T10:00:00.000Z',
          ciphertext: ciphertext,
        ),
      );

      await waitFor(() => received.isNotEmpty);
      await waitFor(
        () => transport.sockets.first.sent.any(
          (frame) =>
              frame.kind == NetworkEnvelopeKind.ack && frame.refId == replyId,
        ),
      );
      expect(received.single.msgId, replyId);
      expect(received.single.ciphertext, ciphertext);
      expect(rejections, isEmpty);
    },
  );

  for (final route in <({String label, String sender, String recipient})>[
    (
      label: 'normalizes the backend\'s bare user id',
      sender: 'remote-user',
      recipient: 'user:remote-user',
    ),
    (
      label: 'preserves an already-prefixed user id',
      sender: 'user:remote-user',
      recipient: 'user:remote-user',
    ),
    (
      label: 'preserves an agent address',
      sender: 'peer@dev-2',
      recipient: 'peer@dev-2',
    ),
  ]) {
    test('inbound DM auto-reply ${route.label}', () async {
      final user = await EnvelopeCodec.newX25519KeyPair();
      final userKeyPair = await codec.keyPairFromPriv(user.priv);
      final host = _FakeDmSessionHost('assistant answer');
      final tokens = fixture.enrolledTokens();
      final (service, _, _, transport, _) = await fixture.buildService(
        httpClient: http(),
        tokenStore: tokens,
        dmSessionHost: host,
        idFactory: () => 'reply-frame-1',
      );
      addTearDown(service.dispose);
      await service.start();
      await fixture.pumpUntilOnline(service);
      final local = await DeviceDmKeyProvider(tokens).loadOrCreate('fa@dev-1');
      const channel = 'dm:user:remote-user:fa@dev-1';
      final ciphertext = await codec.encrypt(
        senderIdentity: userKeyPair,
        channelPub: codec.publicKeyFromB64(local.publicKey),
        frameId: 'inbound-frame-1',
        aadTarget: channel,
        plaintext: jsonEncode({
          'text': 'please wake this session',
          'sessionId': 'session-offline',
        }),
      );

      transport.sockets.first.serverSends(
        NetworkEnvelope(
          kind: NetworkEnvelopeKind.mail,
          msgId: 'inbound-frame-1',
          network: 'net-personal',
          channel: channel,
          from: route.sender,
          to: 'fa@dev-1',
          ts: '2026-11-12T10:00:00.000Z',
          ciphertext: ciphertext,
        ),
      );

      await waitFor(() => host.calls.isNotEmpty);
      expect(host.calls.single, (
        sessionId: 'session-offline',
        text: 'please wake this session',
      ));
      await waitFor(
        () => transport.sockets.first.sent.any(
          (frame) =>
              frame.kind == NetworkEnvelopeKind.mail &&
              frame.msgId == 'reply-frame-1',
        ),
      );
      final reply = transport.sockets.first.sent.singleWhere(
        (frame) =>
            frame.kind == NetworkEnvelopeKind.mail &&
            frame.msgId == 'reply-frame-1',
      );
      expect(reply.network, 'net-personal');
      expect(reply.channel, channel);
      expect(reply.from, 'fa@dev-1');
      expect(reply.to, route.recipient);
      final opened = await codec.decrypt(
        channelKeyPair: userKeyPair,
        frameId: reply.msgId,
        aadTarget: channel,
        payloadB64: reply.ciphertext!,
      );
      expect(opened.senderPub, local.publicKey);
      expect(opened.plaintext, 'assistant answer');
    });
  }

  test(
    'mobile non-live catalog DM stays queued with an honest receipt',
    () async {
      final user = await EnvelopeCodec.newX25519KeyPair();
      final userKeyPair = await codec.keyPairFromPriv(user.priv);
      final host = _FakeDmSessionHost('must not be delivered');
      final tokens = fixture.enrolledTokens();
      final source = fixture.FakeChatSessionSource(const [
        (id: 'session-offline', live: false),
      ]);
      final (service, _, _, transport, _) = await fixture.buildService(
        httpClient: http(),
        tokenStore: tokens,
        dmSessionHost: host,
        chatSessionSource: source,
        mobileQueueOnly: true,
        idFactory: () => 'reply-mobile-1',
      );
      addTearDown(service.dispose);
      await service.start();
      await fixture.pumpUntilOnline(service);
      final local = await DeviceDmKeyProvider(tokens).loadOrCreate('fa@dev-1');
      const channel = 'dm:user:remote-user:fa@dev-1';
      final ciphertext = await codec.encrypt(
        senderIdentity: userKeyPair,
        channelPub: codec.publicKeyFromB64(local.publicKey),
        frameId: 'inbound-mobile-1',
        aadTarget: channel,
        plaintext: jsonEncode({
          'text': 'please wake this session',
          'sessionId': 'session-offline',
        }),
      );

      transport.sockets.first.serverSends(
        NetworkEnvelope(
          kind: NetworkEnvelopeKind.mail,
          msgId: 'inbound-mobile-1',
          network: 'net-personal',
          channel: channel,
          from: 'user:remote-user',
          to: 'fa@dev-1',
          ts: '2026-11-12T10:00:00.000Z',
          ciphertext: ciphertext,
        ),
      );

      await waitFor(
        () => transport.sockets.first.sent.any(
          (frame) =>
              frame.kind == NetworkEnvelopeKind.mail &&
              frame.msgId == 'reply-mobile-1',
        ),
      );
      expect(host.calls, isEmpty);
      expect(
        transport.sockets.first.sent.any(
          (frame) =>
              frame.kind == NetworkEnvelopeKind.ack &&
              frame.refId == 'inbound-mobile-1',
        ),
        isFalse,
      );
      final reply = transport.sockets.first.sent.singleWhere(
        (frame) =>
            frame.kind == NetworkEnvelopeKind.mail &&
            frame.msgId == 'reply-mobile-1',
      );
      final opened = await codec.decrypt(
        channelKeyPair: userKeyPair,
        frameId: reply.msgId,
        aadTarget: channel,
        payloadB64: reply.ciphertext!,
      );
      expect(opened.plaintext, deviceDmQueuedReceipt);
    },
  );

  test(
    'structured slash-command plaintext stays blocked by connector ACL',
    () async {
      final user = await EnvelopeCodec.newX25519KeyPair();
      final host = _FakeDmSessionHost(null);
      final tokens = fixture.enrolledTokens();
      final (service, _, _, transport, _) = await fixture.buildService(
        httpClient: http(),
        tokenStore: tokens,
        dmSessionHost: host,
      );
      addTearDown(service.dispose);
      await service.start();
      await fixture.pumpUntilOnline(service);
      final local = await DeviceDmKeyProvider(tokens).loadOrCreate('fa@dev-1');
      const channel = 'dm:user:remote-user:fa@dev-1';
      final ciphertext = await codec.encrypt(
        senderIdentity: await codec.keyPairFromPriv(user.priv),
        channelPub: codec.publicKeyFromB64(local.publicKey),
        frameId: 'inbound-admin-1',
        aadTarget: channel,
        plaintext: jsonEncode({'text': '/config model=admin'}),
      );

      transport.sockets.first.serverSends(
        NetworkEnvelope(
          kind: NetworkEnvelopeKind.mail,
          msgId: 'inbound-admin-1',
          network: 'net-personal',
          channel: channel,
          from: 'user:remote-user',
          to: 'fa@dev-1',
          ts: '2026-11-12T10:00:00.000Z',
          ciphertext: ciphertext,
        ),
      );
      await waitFor(
        () => transport.sockets.first.sent.any(
          (frame) =>
              frame.kind == NetworkEnvelopeKind.ack &&
              frame.refId == 'inbound-admin-1',
        ),
      );
      expect(host.calls, isEmpty);
    },
  );

  test(
    'agentRunState exposes the roster agent state for the DM banner',
    () async {
      final remote = await EnvelopeCodec.newX25519KeyPair();
      final (service, _, _, transport, _) = await fixture.buildService(
        httpClient: http(),
        tokenStore: fixture.enrolledTokens(),
        userIdProvider: () async => 'user-1',
        idFactory: () => 'dm-frame-1',
      );
      addTearDown(service.dispose);
      await service.start();
      await fixture.pumpUntilOnline(service);
      expect(
        service.agentRunState('goal@remote-dev', networkId: 'net-personal'),
        isNull,
      );

      transport.sockets.first.serverSends(
        rosterWithDmPub('remote-dev', remote.pub),
      );
      await waitFor(() => service.currentRosterFrames.isNotEmpty);
      expect(
        service.agentRunState('goal@remote-dev', networkId: 'net-personal'),
        AgentRunState.live,
      );

      transport.sockets.first.serverSends(
        NetworkEnvelope(
          kind: NetworkEnvelopeKind.roster,
          msgId: 'roster-busy',
          network: 'net-personal',
          ts: '2026-11-12T10:00:02.000Z',
          payload: {
            'devices': [
              {
                'deviceId': 'remote-dev',
                'name': 'remote-dev',
                'agents': [
                  {'name': 'goal', 'state': 'busy', 'exposed': true},
                ],
              },
            ],
          },
        ),
      );
      await waitFor(
        () =>
            service.agentRunState(
              'goal@remote-dev',
              networkId: 'net-personal',
            ) ==
            AgentRunState.busy,
      );
      expect(
        service.agentRunState('nobody@remote-dev', networkId: 'net-personal'),
        isNull,
      );
      expect(
        service.agentRunState('malformed', networkId: 'net-personal'),
        isNull,
      );
    },
  );

  test('agentRunState scopes the lookup to the requested network', () async {
    // The SAME name@deviceId published in two networks: a first-match
    // scan over every cached roster reported whichever network's frame
    // arrived first (review #2197), so the wrong network's roster is
    // cached first here on purpose.
    NetworkEnvelope roster(String msgId, String network, String state) =>
        NetworkEnvelope(
          kind: NetworkEnvelopeKind.roster,
          msgId: msgId,
          network: network,
          ts: '2026-11-14T10:00:00.000Z',
          payload: {
            'devices': [
              {
                'deviceId': 'remote-dev',
                'name': 'remote-dev',
                'agents': [
                  {'name': 'goal', 'state': state, 'exposed': true},
                ],
              },
            ],
          },
        );

    final (service, _, _, transport, _) = await fixture.buildService(
      httpClient: http(),
      tokenStore: fixture.enrolledTokens(),
      userIdProvider: () async => 'user-1',
      idFactory: () => 'dm-frame-1',
    );
    addTearDown(service.dispose);
    await service.start();
    await fixture.pumpUntilOnline(service);

    transport.sockets.first.serverSends(
      roster('roster-other', 'net-other', 'busy'),
    );
    transport.sockets.first.serverSends(
      roster('roster-personal', 'net-personal', 'live'),
    );
    await waitFor(
      () =>
          service.agentRunState('goal@remote-dev', networkId: 'net-personal') ==
          AgentRunState.live,
    );
    expect(
      service.agentRunState('goal@remote-dev', networkId: 'net-personal'),
      AgentRunState.live,
    );
    expect(
      service.agentRunState('goal@remote-dev', networkId: 'net-other'),
      AgentRunState.busy,
    );
    expect(
      service.agentRunState('goal@remote-dev', networkId: 'net-unknown'),
      isNull,
    );
  });
}

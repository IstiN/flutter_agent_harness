// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_agent_harness/src/cli/network_presence.dart';
import 'package:flutter_agent_harness/src/messaging/hub_crypto.dart';
import 'package:flutter_agent_harness/src/network/connector/device_dm.dart';
import 'package:flutter_agent_harness/src/network/connector/device_dm_keys.dart';
import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
import 'package:flutter_agent_harness/src/network/network_account.dart';
import 'package:flutter_agent_harness/src/session/session_catalog.dart';
import 'package:test/test.dart';

import '../network/connector/fake_device_server.dart';

void main() {
  const device = NetworkDeviceCredentials(
    deviceId: 'device-1',
    deviceToken: 'device-token',
    personalNetworkId: 'personal-1',
  );
  const address = 'mailbox-1@device-1';
  const session = CliNetworkSession(
    sessionId: 'session-1',
    mailboxPrefix: 'mailbox-1',
  );

  test(
    'current DMs write in order, dedup redelivery, then accepted receipt + ack',
    () async {
      final server = FakeDeviceServer()
        ..seedDevice(device.deviceId, networks: const ['personal-1']);
      final store = MemoryDeviceDmKeyStore();
      final agent = await DeviceDmKeyProvider(store).loadOrCreate(address);
      final user = await hubGenerateX25519KeyPair();
      final delivered = <CliNetworkDm>[];
      final controller = NetworkPresenceController(
        device: device,
        dmKeyStore: store,
        baseUrl: 'https://relay.test',
        ticketProvider: () async => 'ticket',
        transport: server.transport,
        idFactory: _ids(),
      );
      addTearDown(controller.dispose);
      await controller.startSession(
        CliNetworkSession(
          sessionId: session.sessionId,
          mailboxPrefix: session.mailboxPrefix,
          dmSink: (dm) async => delivered.add(dm),
        ),
      );
      await _waitUntil(() => controller.connector?.isConnected == true);

      server.deliverTo(
        deviceId: device.deviceId,
        mail: await _appDm(
          id: 'dm-1',
          text: 'first',
          user: user,
          agentPub: agent.publicKey,
        ),
      );
      server.deliverTo(
        deviceId: device.deviceId,
        mail: await _appDm(
          id: 'dm-2',
          text: 'second',
          user: user,
          agentPub: agent.publicKey,
        ),
      );
      await _waitUntil(() => delivered.length == 2);
      await _waitUntil(
        () =>
            server.received
                .where((frame) => frame.kind == NetworkEnvelopeKind.ack)
                .length ==
            2,
      );
      server.deliverTo(
        deviceId: device.deviceId,
        mail: await _appDm(
          id: 'dm-1',
          text: 'first',
          user: user,
          agentPub: agent.publicKey,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(delivered.map((dm) => dm.mail.text), ['first', 'second']);
      expect(delivered.map((dm) => dm.mail.sessionId), [
        'session-1',
        'session-1',
      ]);
      expect(
        delivered.singleWhere((dm) => dm.mail.msgId == 'dm-1').senderLabel,
        'network user user-1',
      );
      expect(
        delivered.every(
          (dm) => dm.replyAddress.startsWith(deviceDmReplyAddressPrefix),
        ),
        isTrue,
      );
      final receipts = server.persistedMail
          .where((frame) => frame.to == 'user:user-1')
          .toList(growable: false);
      expect(
        receipts,
        hasLength(2),
        reason: 'redelivery sends no second receipt',
      );
      for (final receipt in receipts) {
        expect(await _decryptReply(receipt, user), {
          'text': deviceDmAcceptedReceipt,
          'sessionId': 'session-1',
        });
      }
      expect(
        server.received.where(
          (frame) =>
              frame.kind == NetworkEnvelopeKind.ack && frame.refId == 'dm-1',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'non-current session gets encrypted queued notice and stays unacked',
    () async {
      final server = FakeDeviceServer()
        ..seedDevice(device.deviceId, networks: const ['personal-1']);
      final store = MemoryDeviceDmKeyStore();
      final agent = await DeviceDmKeyProvider(store).loadOrCreate(address);
      final user = await hubGenerateX25519KeyPair();
      final delivered = <CliNetworkDm>[];
      final controller = NetworkPresenceController(
        device: device,
        dmKeyStore: store,
        baseUrl: 'https://relay.test',
        ticketProvider: () async => 'ticket',
        transport: server.transport,
        idFactory: _ids(),
      );
      addTearDown(controller.dispose);
      await controller.startSession(
        CliNetworkSession(
          sessionId: session.sessionId,
          mailboxPrefix: session.mailboxPrefix,
          dmSink: (dm) async => delivered.add(dm),
        ),
      );
      await _waitUntil(() => controller.connector?.isConnected == true);

      server.deliverTo(
        deviceId: device.deviceId,
        mail: await _appDm(
          id: 'dm-other-session',
          text: 'do not steal this',
          sessionId: 'session-other',
          user: user,
          agentPub: agent.publicKey,
        ),
      );
      await _waitUntil(() => server.persistedMail.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(delivered, isEmpty);
      expect(
        server.received.where(
          (frame) =>
              frame.kind == NetworkEnvelopeKind.ack &&
              frame.refId == 'dm-other-session',
        ),
        isEmpty,
      );
      expect(await _decryptReply(server.persistedMail.single, user), {
        'text': deviceDmQueuedReceipt,
        'sessionId': 'session-other',
      });
    },
  );

  test(
    'DM to a catalog sleeper launches its guarded headless wake, then the '
    'woken session receives the unacked DM and returns an accepted receipt',
    () async {
      final server = FakeDeviceServer()
        ..seedDevice(device.deviceId, networks: const ['personal-1']);
      final keyStore = MemoryDeviceDmKeyStore();
      final agent = await DeviceDmKeyProvider(keyStore).loadOrCreate(address);
      final user = await hubGenerateX25519KeyPair();
      final delivered = <CliNetworkDm>[];
      final catalog = _FakeWakeCatalogStore([
        SessionCatalogEntry(
          id: 'session-1',
          live: true,
          title: 'Current work',
          cwd: '/work/current',
          lastActiveAt: DateTime.utc(2026, 11, 12, 12),
        ),
        SessionCatalogEntry(
          id: 'session-other',
          live: false,
          title: 'Asleep work',
          sessionName: 'asleep-name',
          snippet: 'Continue the asleep task',
          cwd: '/work/asleep',
          lastActiveAt: DateTime.utc(2026, 11, 12, 11),
        ),
      ]);
      final wakes = <({String cwd, String sessionId, String? sessionName})>[];
      final controller = NetworkPresenceController(
        device: device,
        dmKeyStore: keyStore,
        baseUrl: 'https://relay.test',
        ticketProvider: () async => 'ticket',
        transport: server.transport,
        idFactory: _ids(),
        catalogStore: catalog,
        catalogPollInterval: Duration.zero,
      );
      controller.wakeLauncher =
          ({required cwd, required sessionId, sessionName}) async {
            wakes.add((
              cwd: cwd,
              sessionId: sessionId,
              sessionName: sessionName,
            ));
            return null;
          };
      await controller.startSession(
        CliNetworkSession(
          sessionId: session.sessionId,
          mailboxPrefix: session.mailboxPrefix,
          dmSink: (dm) async => delivered.add(dm),
        ),
      );
      await _waitUntil(() => controller.connector?.isConnected == true);

      server.deliverTo(
        deviceId: device.deviceId,
        mail: await _appDm(
          id: 'dm-wake-session',
          text: 'wake and handle this',
          sessionId: 'session-other',
          user: user,
          agentPub: agent.publicKey,
        ),
      );
      await _waitUntil(() => wakes.isNotEmpty);
      await _waitUntil(() => server.persistedMail.isNotEmpty);

      expect(wakes.single, (
        cwd: '/work/asleep',
        sessionId: 'session-other',
        sessionName: 'asleep-name',
      ));
      expect(delivered, isEmpty);
      expect(
        server.received.where(
          (frame) =>
              frame.kind == NetworkEnvelopeKind.ack &&
              frame.refId == 'dm-wake-session',
        ),
        isEmpty,
        reason: 'only the woken target owns the accepted receipt and ack',
      );
      expect(await _decryptReply(server.persistedMail.single, user), {
        'text': deviceDmQueuedReceipt,
        'sessionId': 'session-other',
      });

      // The launched headless process opens the target with the SAME device
      // and agent identity. The fake fabric displaces the interactive socket
      // and redelivers the original still-unacked mail, exactly as production.
      await controller.dispose();
      final headlessDelivered = <CliNetworkDm>[];
      final headless = NetworkPresenceController(
        device: device,
        dmKeyStore: keyStore,
        baseUrl: 'https://relay.test',
        ticketProvider: () async => 'ticket',
        transport: server.transport,
        idFactory: _ids('headless'),
        catalogStore: catalog,
        catalogPollInterval: Duration.zero,
      );
      addTearDown(headless.dispose);
      await headless.startSession(
        CliNetworkSession(
          sessionId: 'session-other',
          mailboxPrefix: session.mailboxPrefix,
          dmSink: (dm) async {
            headlessDelivered.add(dm);
            await headless.sendNetworkDmReply(
              address: dm.replyAddress,
              text: 'awake answer',
            );
          },
        ),
      );
      await _waitUntil(() => headlessDelivered.isNotEmpty);
      await _waitUntil(
        () => server.received.any(
          (frame) =>
              frame.kind == NetworkEnvelopeKind.ack &&
              frame.refId == 'dm-wake-session',
        ),
      );

      expect(headlessDelivered.single.mail.text, 'wake and handle this');
      expect(headlessDelivered.single.mail.sessionId, 'session-other');
      final replies = server.persistedMail.where(
        (frame) => frame.to == 'user:user-1',
      );
      final plaintexts = [
        for (final reply in replies) await _decryptReply(reply, user),
      ];
      expect(
        plaintexts,
        anyElement(
          equals({'text': 'awake answer', 'sessionId': 'session-other'}),
        ),
      );
      expect(plaintexts.last, {
        'text': deviceDmAcceptedReceipt,
        'sessionId': 'session-other',
      });
    },
  );

  test(
    'wrong-key CLI input is acknowledged with a safe notice, never delivered',
    () async {
      final server = FakeDeviceServer()
        ..seedDevice(device.deviceId, networks: const ['personal-1']);
      final store = MemoryDeviceDmKeyStore();
      final agent = await DeviceDmKeyProvider(store).loadOrCreate(address);
      final wrong = await DeviceDmKeyProvider(
        MemoryDeviceDmKeyStore(),
      ).loadOrCreate('wrong@device-2');
      final user = await hubGenerateX25519KeyPair();
      final delivered = <CliNetworkDm>[];
      final notices = <String>[];
      final controller = NetworkPresenceController(
        device: device,
        dmKeyStore: store,
        baseUrl: 'https://relay.test',
        ticketProvider: () async => 'ticket',
        transport: server.transport,
        idFactory: _ids(),
      );
      addTearDown(controller.dispose);
      await controller.startSession(
        CliNetworkSession(
          sessionId: session.sessionId,
          mailboxPrefix: session.mailboxPrefix,
          dmSink: (dm) async => delivered.add(dm),
          onNotice: notices.add,
        ),
      );
      await _waitUntil(() => controller.connector?.isConnected == true);

      server.deliverTo(
        deviceId: device.deviceId,
        mail: await _appDm(
          id: 'dm-wrong-key',
          text: 'secret plaintext',
          user: user,
          agentPub: wrong.publicKey,
        ),
      );
      await _waitUntil(() => notices.isNotEmpty);

      expect(delivered, isEmpty);
      expect(notices.single, contains('rejected'));
      expect(notices.single, isNot(contains('secret plaintext')));
      expect(notices.single, isNot(contains(wrong.privateKey)));
      expect(
        server.received.any(
          (frame) =>
              frame.kind == NetworkEnvelopeKind.ack &&
              frame.refId == 'dm-wrong-key',
        ),
        isTrue,
      );

      server.deliverTo(
        deviceId: device.deviceId,
        mail: await _appDm(
          id: 'dm-foreign-device',
          text: 'foreign plaintext',
          targetAddress: 'main@device-2',
          user: user,
          agentPub: agent.publicKey,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(delivered, isEmpty);
      expect(notices, hasLength(1));
      expect(
        server.received.any(
          (frame) =>
              frame.kind == NetworkEnvelopeKind.ack &&
              frame.refId == 'dm-foreign-device',
        ),
        isFalse,
        reason: 'the catch-all sink must never ack a foreign device DM',
      );
    },
  );
}

final class _FakeWakeCatalogStore implements SessionCatalogStore {
  _FakeWakeCatalogStore(this.rows);

  final List<SessionCatalogEntry> rows;

  @override
  Future<List<SessionCatalogEntry>> loadSessions({
    Set<String> liveSessionIds = const {},
  }) async => rows;
}

Future<NetworkEnvelope> _appDm({
  required String id,
  required String text,
  required SimpleKeyPair user,
  required String agentPub,
  String sessionId = 'session-1',
  String targetAddress = 'mailbox-1@device-1',
}) async {
  final channel = dmChannelId('user-1', targetAddress);
  return NetworkEnvelope(
    kind: NetworkEnvelopeKind.mail,
    msgId: id,
    network: 'personal-1',
    channel: channel,
    from: 'user:user-1',
    to: targetAddress,
    ts: '2026-11-15T10:00:00.000Z',
    ciphertext: await hubSealFanet1(
      senderDhKeyPair: user,
      recipientDhPubkey: SimplePublicKey(
        base64Decode(agentPub),
        type: KeyPairType.x25519,
      ),
      frameId: id,
      aadTarget: channel,
      plaintext: jsonEncode({
        'text': text,
        'sessionId': sessionId,
        'threading': 1,
      }),
    ),
  );
}

Future<Map<String, Object?>> _decryptReply(
  NetworkEnvelope reply,
  SimpleKeyPair user,
) async {
  final opened = hubTryOpenFanet1(reply.ciphertext!);
  expect(opened, isNotNull);
  final plaintext = await hubDecryptPayloadWithKeyPair(
    recipientDhKeyPair: user,
    senderDhPubkey: opened!.senderPubkey,
    frameId: reply.msgId,
    aadTarget: reply.channel!,
    ciphertextB64: opened.ciphertextB64,
  );
  return (jsonDecode(plaintext) as Map).cast<String, Object?>();
}

String Function() _ids([String prefix = 'id']) {
  var value = 0;
  return () => '$prefix-${++value}';
}

Future<void> _waitUntil(bool Function() condition) async {
  for (var i = 0; i < 300; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition not met within 3s');
}

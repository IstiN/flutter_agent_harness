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
      for (final (index, receipt) in receipts.indexed) {
        expect(await _decryptReply(receipt, user), {
          'text': deviceDmAcceptedReceipt,
          'sessionId': 'session-1',
          'replyTo': 'dm-${index + 1}',
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
        'replyTo': 'dm-other-session',
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
        sessionName: null,
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
        'replyTo': 'dm-wake-session',
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
          // Production: the woken session publishes its OWN prefix, so the
          // redelivered original (addressed to the earlier alias) must be
          // accepted via the authenticated matching sessionId alone.
          mailboxPrefix: 'session-other',
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
          equals({
            'text': 'awake answer',
            'sessionId': 'session-other',
            'replyTo': 'dm-wake-session',
          }),
        ),
      );
      expect(plaintexts.last, {
        'text': deviceDmAcceptedReceipt,
        'sessionId': 'session-other',
        'replyTo': 'dm-wake-session',
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

  group('live incident: dm-mail device-WS push sender rewrite', () {
    // Live failure (iOS v1.0.740 → Mac, msgId 8ff48b96-…): the DM decrypted
    // fine yet was rejected 'empty remote write carries nothing to deliver'
    // and ACKED — the mail was lost. This group pins both halves of the
    // evidence: every sender-id form the relay legitimately produces still
    // delivers, and the only mangled form that reproduces the incident is
    // `from` rewritten to the ADDRESSED AGENT address (from/to swap or
    // from ← routing target in the server's dm-mail → device-WS push).
    // Routed to the fa_network owner; not repairable locally without
    // re-delivering the agent's own reply echoes (echo ack/drop invariant).
    for (final sender in ['user:user-1', 'user-1']) {
      test(
        'app-built DM arriving as from "$sender" still delivers non-empty',
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
              id: 'dm-ok-$sender',
              text: 'steer the mac',
              from: sender,
              user: user,
              agentPub: agent.publicKey,
            ),
          );
          await _waitUntil(() => delivered.length == 1);

          expect(delivered.single.mail.text, 'steer the mac');
          expect(delivered.single.mail.msgId, 'dm-ok-$sender');
        },
      );
    }

    // The live-loss half of the incident is now a CLASSIFICATION, not a
    // silent drop: every from-rewritten shape (msgId the connector never
    // minted) must be acknowledged (server caps redelivery at 32/device)
    // but NEVER silently — the loud non-echo warning is the regression
    // tripwire that would have made 8ff48b96 visible in the field.
    for (final shape in <({String label, String from, String? to})>[
      (
        label: 'from rewritten to the addressee',
        from: address,
        to: null, // envelope to stays the addressed agent
      ),
      (label: 'from/to swapped', from: address, to: 'user:user-1'),
      (label: 'from/to swapped + bare uid', from: address, to: 'user-1'),
    ]) {
      test('rewritten-sender frame (${shape.label}) is acked with the loud '
          'non-echo warning, never silently dropped', () async {
        final server = FakeDeviceServer()
          ..seedDevice(device.deviceId, networks: const ['personal-1']);
        final store = MemoryDeviceDmKeyStore();
        final agent = await DeviceDmKeyProvider(store).loadOrCreate(address);
        final user = await hubGenerateX25519KeyPair();
        final delivered = <CliNetworkDm>[];
        final notices = <String>[];
        final logs = <String>[];
        final controller = NetworkPresenceController(
          device: device,
          dmKeyStore: store,
          baseUrl: 'https://relay.test',
          ticketProvider: () async => 'ticket',
          transport: server.transport,
          idFactory: _ids(),
          onLog: logs.add,
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

        // Byte-for-byte the app send-path envelope, except `from` (and
        // for the swapped shapes `to`) carries the rewritten direction.
        // The ciphertext/frameId/channel stay intact — exactly what the
        // live log proved for 8ff48b96 (decryption machinery intact).
        final msgId = '8ff48b96-e4b8-46c4-9b3c-a2f48490bcb7-${shape.label}';
        server.deliverTo(
          deviceId: device.deviceId,
          mail: await _appDm(
            id: msgId,
            text: 'hello from ios',
            from: shape.from,
            to: shape.to,
            user: user,
            agentPub: agent.publicKey,
          ),
        );
        await _waitUntil(() => notices.length == 1);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(delivered, isEmpty);
        expect(
          notices.single,
          'network DM $msgId rejected: '
          'non-echo frame with rewritten sender: sender id equals the '
          'addressed agent and the payload is empty',
        );
        expect(
          logs,
          anyElement(
            allOf(
              contains('::warning'),
              contains('non-echo frame with rewritten sender'),
              contains(msgId),
            ),
          ),
          reason:
              'the field-visible regression tripwire (incident '
              '8ff48b96 was lost silently for a full day)',
        );
        expect(
          server.received.any(
            (frame) =>
                frame.kind == NetworkEnvelopeKind.ack && frame.refId == msgId,
          ),
          isTrue,
          reason:
              'still acked: a malformed inbound must not loop forever '
              '(fa_network caps redelivery at 32/device)',
        );
      });
    }

    test(
      'own reply echo (frame id this connector minted) acks quietly',
      () async {
        final server = FakeDeviceServer()
          ..seedDevice(device.deviceId, networks: const ['personal-1']);
        final store = MemoryDeviceDmKeyStore();
        final agent = await DeviceDmKeyProvider(store).loadOrCreate(address);
        final user = await hubGenerateX25519KeyPair();
        final delivered = <CliNetworkDm>[];
        final notices = <String>[];
        final logs = <String>[];
        final controller = NetworkPresenceController(
          device: device,
          dmKeyStore: store,
          baseUrl: 'https://relay.test',
          ticketProvider: () async => 'ticket',
          transport: server.transport,
          idFactory: _ids(),
          onLog: logs.add,
        );
        addTearDown(controller.dispose);
        await controller.startSession(
          CliNetworkSession(
            sessionId: session.sessionId,
            mailboxPrefix: session.mailboxPrefix,
            dmSink: (dm) async {
              delivered.add(dm);
              await controller.sendNetworkDmReply(
                address: dm.replyAddress,
                text: 'an answer',
              );
            },
            onNotice: notices.add,
          ),
        );
        await _waitUntil(() => controller.connector?.isConnected == true);

        server.deliverTo(
          deviceId: device.deviceId,
          mail: await _appDm(
            id: 'dm-echo-source',
            text: 'trigger a reply',
            user: user,
            agentPub: agent.publicKey,
          ),
        );
        await _waitUntil(() => delivered.length == 1);
        // The reply this connector minted, fanned back by the server to
        // the sending device itself — the true own-reply echo shape.
        await _waitUntil(
          () => server.persistedMail.any(
            (frame) => frame.from == address && frame.to == 'user:user-1',
          ),
        );
        final echo = server.persistedMail
            .where((frame) => frame.from == address)
            .first;
        server.deliverTo(deviceId: device.deviceId, mail: echo);
        await _waitUntil(
          () => server.received.any(
            (frame) =>
                frame.kind == NetworkEnvelopeKind.ack &&
                frame.refId == echo.msgId,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(delivered, hasLength(1), reason: 'the echo is not user mail');
        expect(notices, isEmpty);
        expect(logs, anyElement(contains('own reply echo')));
        expect(
          logs.where((line) => line.contains('non-echo')),
          isEmpty,
          reason: 'a frame we minted must never raise the rewrite alarm',
        );
      },
    );

    test('stored unacked DM resume-sync delivers the ORIGINAL sender verbatim '
        'with a non-empty payload (8ff48b96 flow end-to-end)', () async {
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
      // First incarnation: the addressed session is NOT listening, so
      // the DM gets the honest queued receipt and stays UNACKED — the
      // exact state the incident's first delivery left on the server.
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
          id: 'dm-stored-1',
          text: 'hello from ios',
          sessionId: 'session-other',
          user: user,
          agentPub: agent.publicKey,
        ),
      );
      await _waitUntil(
        () => server.persistedMail.any((frame) => frame.to == 'user:user-1'),
      );
      expect(
        server.received.where(
          (frame) =>
              frame.kind == NetworkEnvelopeKind.ack &&
              frame.refId == 'dm-stored-1',
        ),
        isEmpty,
        reason: 'queued mail stays stored server-side for resume',
      );
      await controller.dispose();

      // Later live session (new process): the resume push hands over the
      // STORED frame. The sink must see the envelope senderId VERBATIM —
      // user:user-1, never the local agent address — and the payload
      // must decode non-empty. This is the client half fa_network
      // 2a5bf20 now guarantees on the wire; a client-side from rewrite
      // anywhere in pull → re-emit → decode fails here.
      final redelivered = <CliNetworkDm>[];
      final second = NetworkPresenceController(
        device: device,
        dmKeyStore: store,
        baseUrl: 'https://relay.test',
        ticketProvider: () async => 'ticket',
        transport: server.transport,
        idFactory: _ids('second'),
      );
      addTearDown(second.dispose);
      await second.startSession(
        CliNetworkSession(
          sessionId: 'session-other',
          mailboxPrefix: session.mailboxPrefix,
          dmSink: (dm) async => redelivered.add(dm),
        ),
      );
      await _waitUntil(() => redelivered.length == 1);

      expect(redelivered.single.mail.text, 'hello from ios');
      expect(redelivered.single.mail.envelope.from, 'user:user-1');
      expect(redelivered.single.mail.envelope.from, isNot(address));
      await _waitUntil(
        () => server.received.any(
          (frame) =>
              frame.kind == NetworkEnvelopeKind.ack &&
              frame.refId == 'dm-stored-1',
        ),
      );
    });
  });
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
  String from = 'user:user-1',
  String? to,
}) async {
  final channel = dmChannelId('user-1', targetAddress);
  return NetworkEnvelope(
    kind: NetworkEnvelopeKind.mail,
    msgId: id,
    network: 'personal-1',
    channel: channel,
    from: from,
    to: to ?? targetAddress,
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

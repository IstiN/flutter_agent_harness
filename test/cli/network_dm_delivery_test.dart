@TestOn('vm')
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/messaging/hub_crypto.dart';
import 'package:flutter_agent_harness/src/network/network_account.dart';
import 'package:test/test.dart';

import '../network/connector/fake_device_server.dart';
import 'agent_cli_test_support.dart';

void main() {
  test(
    'app DM → CLI steering → agent_message reply → encrypted app round-trip',
    () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final server = FakeDeviceServer()
        ..seedDevice('device-1', networks: const ['personal-1']);
      final store = MemoryDeviceDmKeyStore();
      final controller = NetworkPresenceController(
        device: const NetworkDeviceCredentials(
          deviceId: 'device-1',
          deviceToken: 'device-token',
          personalNetworkId: 'personal-1',
        ),
        dmKeyStore: store,
        baseUrl: 'https://relay.test',
        ticketProvider: () async => 'ticket',
        transport: server.transport,
        idFactory: _ids(),
      );
      final io = FakeCliIO();
      final fake = FakeStreamFunction([textTurn('steering received')]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          networkPresence: controller,
        ),
        io: io,
        streamFunction: fake.call,
      );
      final running = cli.run();
      addTearDown(() async {
        io.sendLine('/exit');
        await running;
        await controller.dispose();
        await io.close();
      });
      await waitForIt(
        () =>
            controller.connector?.isConnected == true && store.keys.length == 1,
        reason: 'CLI network session and provisioned DM key',
      );
      final address = store.keys.keys.single;
      final agent = await DeviceDmKeyProvider(store).loadExisting(address);
      final user = await hubGenerateX25519KeyPair();

      Future<void> sendFromApp(String id, String text) async {
        server.deliverTo(
          deviceId: 'device-1',
          mail: await _appDm(
            id: id,
            text: text,
            sessionId: cli.subagentManager.mailboxPrefix,
            agentAddress: address,
            agentPub: agent!.publicKey,
            user: user,
          ),
        );
      }

      await sendFromApp('app-dm-1', 'first network instruction');
      await sendFromApp('app-dm-2', 'second network instruction');
      // At-least-once server redelivery must not become a second mailbox write.
      await sendFromApp('app-dm-1', 'first network instruction');

      await waitForIt(() => fake.calls >= 1, reason: 'idle inbox wake');
      await waitForIt(
        () =>
            server.persistedMail
                .where((frame) => frame.to == 'user:user-1')
                .length >=
            2,
        reason: 'distinct accepted receipts',
      );
      final steering = fake.contexts.first.messages
          .whereType<UserMessage>()
          .map((message) => message.content)
          .whereType<String>()
          .join('\n');
      expect(steering, contains('network DM · network user user-1'));
      expect(steering, contains('first network instruction'));
      expect(steering, contains('second network instruction'));
      expect(
        steering.indexOf('first network instruction'),
        lessThan(steering.indexOf('second network instruction')),
      );
      expect(
        steering,
        contains('[reply with agent_message to: "$deviceDmReplyAddressPrefix'),
      );
      expect(
        'first network instruction'.allMatches(steering),
        hasLength(1),
        reason: 'redelivery was deduped before steering',
      );
      for (final receipt in server.persistedMail.where(
        (frame) => frame.to == 'user:user-1',
      )) {
        expect(await _decryptReply(receipt, user), {
          'text': deviceDmAcceptedReceipt,
          'sessionId': cli.subagentManager.mailboxPrefix,
        });
      }
      expect(
        server.received.where((frame) => frame.kind == NetworkEnvelopeKind.ack),
        hasLength(2),
      );

      final route = DeviceDmReplyRoute(
        network: 'personal-1',
        channel: dmChannelId('user-1', address),
        replyRecipient: 'user:user-1',
        agentAddress: address,
        sessionId: cli.subagentManager.mailboxPrefix,
        senderPubkey: base64Encode((await user.extractPublicKey()).bytes),
        threaded: true,
      );
      final replyAddress = route.toAddress();
      expect(steering, contains(replyAddress));
      fake.turns.add(
        toolTurn([
          ToolCall(
            id: 'network-reply-1',
            name: 'agent_message',
            arguments: {'to': replyAddress, 'message': 'CLI encrypted reply'},
          ),
        ]),
      );
      fake.turns.add(textTurn('reply sent'));
      io.sendLine('answer the network DM');
      await waitForIt(
        () => fake.calls >= 3 && server.persistedMail.length >= 3,
        reason: 'existing agent_message tool sends the encrypted DM reply',
      );
      final reply = server.persistedMail.last;
      expect(reply.from, address);
      expect(reply.to, 'user:user-1');
      expect(await _decryptReply(reply, user), {
        'text': 'CLI encrypted reply',
        'sessionId': cli.subagentManager.mailboxPrefix,
      });

      fake.turns.add(
        toolTurn([
          ToolCall(
            id: 'network-reply-malformed',
            name: 'agent_message',
            arguments: {
              'to': 'network-dm:v1:not-base64!',
              'message': 'must not send',
            },
          ),
        ]),
      );
      fake.turns.add(textTurn('reported malformed route'));
      io.sendLine('try a malformed network route');
      await waitForIt(() => fake.calls >= 5);
      final toolErrors = fake.contexts
          .expand((context) => context.messages)
          .whereType<ToolResultMessage>()
          .expand(
            (message) => message.content.whereType<TextContent>().map(
              (content) => content.text,
            ),
          )
          .join('\n');
      expect(
        toolErrors,
        contains('invalid network DM reply address'),
        reason: 'malformed reply addresses return an actionable tool result',
      );
      expect(server.persistedMail, hasLength(3));
    },
  );

  test(
    'network mailbox ids are deterministic, filename-safe and seq-sortable',
    () {
      NetworkEnvelope frame({required String id, int? seq, String? ts}) =>
          NetworkEnvelope(
            kind: NetworkEnvelopeKind.mail,
            msgId: id,
            network: 'personal-1',
            channel: 'dm:user:user-1:main@device-1',
            from: 'user:user-1',
            to: 'main@device-1',
            ts: ts ?? '2026-11-15T10:00:00.000Z',
            seq: seq,
            ciphertext: 'opaque',
          );

      final second = networkDmMailboxMessageId(frame(id: 'raw/id:2', seq: 2));
      final tenth = networkDmMailboxMessageId(frame(id: 'raw/id:10', seq: 10));
      expect(second, networkDmMailboxMessageId(frame(id: 'raw/id:2', seq: 2)));
      expect(second, isNot(contains('/')));
      expect(second, isNot(contains(':')));
      expect([tenth, second]..sort(), [second, tenth]);
      final earlier = networkDmMailboxMessageId(
        frame(id: 'fallback-1', ts: '2026-11-15T10:00:00.000Z'),
      );
      final later = networkDmMailboxMessageId(
        frame(id: 'fallback-2', ts: '2026-11-15T10:00:01.000Z'),
      );
      expect([later, earlier]..sort(), [earlier, later]);
    },
  );
}

Future<NetworkEnvelope> _appDm({
  required String id,
  required String text,
  required String sessionId,
  required String agentAddress,
  required String agentPub,
  required SimpleKeyPair user,
}) async {
  final channel = dmChannelId('user-1', agentAddress);
  return NetworkEnvelope(
    kind: NetworkEnvelopeKind.mail,
    msgId: id,
    network: 'personal-1',
    channel: channel,
    from: 'user:user-1',
    to: agentAddress,
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

String Function() _ids() {
  var value = 0;
  return () => 'id-${++value}';
}

/// Live-fire compatibility test against a REAL DAP hub (env-gated).
///
/// Runs ONLY when both `DAP_HUB_URL` and `DAP_MASTER_SECRET` are set in the
/// environment (the CI gate excludes the `integration` tag — see
/// dart_test.yaml). The master secret exists solely in the process
/// environment: never in code, fixtures, or logs.
///
/// Contract exercised against the real hub over fah_hub_client 0.2.1:
/// 1. Enroll a FRESH throwaway identity (`fah-livetest-<random hex>`) with
///    the master secret; the welcome's agentId must be a valid 16-hex id
///    and must not collide with any real agent on this hub.
/// 2. `peers()` completes within the client request timeout and reports
///    exactly one `self` entry — ours.
/// 3. Self-DM round trip: a DM to our own id comes back decrypted on the
///    inbound stream with the matching text.
/// 4. Concurrent `peers()` calls both complete with the full roster —
///    the real hub's replyTo echo must not corrupt presence waiters
///    (BUG 3 / BUG 5 regression at the protocol level).
/// 5. `flush()` completes and `disconnect()` leaves no connection behind.
///
/// No timeout-as-pass: every hub interaction is asserted by value; the
/// client's own `requestTimeout` plus the suite timeout bound the waits.
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:fa_hub_client/fa_hub_client.dart';
import 'package:test/test.dart';

/// Real agent identities on the shared live hub — the enrolled test
/// identity must never collide with any of them.
const _forbiddenAgentIds = {
  'c31bb18e807174aa',
  'be174ca612fffd94',
  '947a113319897ad5',
};

String _randomHex(int chars) {
  final rng = Random.secure();
  return List.generate(chars, (_) => rng.nextInt(16).toRadixString(16)).join();
}

void main() {
  final hubUrl = Platform.environment['DAP_HUB_URL'];
  final masterSecret = Platform.environment['DAP_MASTER_SECRET'];
  final liveConfigured =
      (hubUrl?.isNotEmpty ?? false) && (masterSecret?.isNotEmpty ?? false);

  group(
    'live DAP hub',
    () {
      late HubClient client;
      late String agentId;
      late String agentName;

      setUpAll(() async {
        agentName = 'fah-livetest-${_randomHex(8)}';
        client = HubClient(
          config: HubConfig(url: hubUrl, name: agentName),
          identity: await HubIdentity.generate(),
          // Master secret: enroll mode. configFile stays null so the
          // hub-issued client secret is NEVER persisted anywhere.
          clientSecret: masterSecret,
          enroll: true,
          requestTimeout: const Duration(seconds: 15),
        );
        agentId = await client.connect();
      });

      test('enrolled agentId is a fresh unique identity', () {
        expect(agentId, matches(RegExp(r'^[0-9a-f]{16}$')));
        expect(_forbiddenAgentIds, isNot(contains(agentId)));
        expect(client.agentId, agentId);
      });

      test('peers() completes and includes exactly one self entry', () async {
        final peers = await client.peers();
        final self = peers.where((peer) => peer.self).toList();
        expect(self, hasLength(1));
        expect(self.single.agentId, agentId);
        expect(self.single.online, isTrue);
      });

      test('self-DM round trip via inbound stream', () async {
        final text =
            'fah-livetest round-trip ${DateTime.now().microsecondsSinceEpoch}';
        // Subscribe BEFORE sending: inbound is a broadcast stream, so a
        // late subscription would lose the reply racing the send.
        final inbox = StreamIterator<InboundMessage>(client.inbound);
        await client.sendDm(agentId, text);

        final received = await inbox.moveNext().timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw TimeoutException(
            'self-DM never arrived on the inbound stream',
            const Duration(seconds: 20),
          ),
        );
        expect(
          received,
          isTrue,
          reason: 'self-DM round trip produced no frame',
        );
        final message = inbox.current;
        expect(message.from, agentId);
        expect(message.plaintext, text);
        await inbox.cancel();
      });

      test(
        'concurrent peers() both complete with self (waiter race)',
        () async {
          final rosters = await Future.wait([client.peers(), client.peers()]);
          for (final roster in rosters) {
            expect(roster.map((peer) => peer.agentId), contains(agentId));
          }
        },
      );

      test('flush drains the offline mailbox cleanly', () async {
        final drained = await client.flush();
        expect(drained, greaterThanOrEqualTo(0));
      });

      tearDownAll(() async {
        await client.disconnect();
        expect(client.connected, isFalse);
      });
    },
    timeout: const Timeout(Duration(seconds: 100)),
    skip: liveConfigured
        ? false
        : 'DAP_HUB_URL / DAP_MASTER_SECRET not set — live hub test skipped',
  );
}

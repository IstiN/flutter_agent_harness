// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// REG-NOLEAK (AC-N7 / invariant I2): byte-scan proof that channel key
/// material never leaves the device. A full session (join → openChannel →
/// sendText → loadOlder → wallet export → agent invite) is driven over
/// the fakes with fixed, recognizable key material; every artifact that
/// crosses a boundary (HTTP requests, WS frames) is then scanned for the
/// private keys, and the sent envelope payload for the plaintext.
library;

import 'dart:convert';

import 'package:fa/network/invite_codec.dart';
import 'package:fa/network/key_wallet.dart';
import 'package:fa/network/network_session_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

/// Fixed recognizable test key material (32 bytes each, X25519 seeds).
final channelPriv = base64Encode(List.filled(32, 0xAA));
final identityPriv = base64Encode(List.filled(32, 0xBB));
final otherPriv = base64Encode(List.filled(32, 0xCC));

/// The plaintext that must never appear on the wire.
const plaintext = 'NOLEAK-PLAINTEXT-7f3a9c';

/// Derives the base64 X25519 public key for a base64 private key.
Future<String> pubFor(String privB64) async {
  final pair = await testCodec.keyPairFromPriv(privB64);
  final data = await pair.extract();
  return base64Encode(data.publicKey.bytes);
}

/// Waits for an async condition (plain-test real event loop).
Future<void> waitFor(bool Function() condition, String what) async {
  for (var i = 0; i < 500; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('timed out waiting for $what');
}

void main() {
  group('REG-NOLEAK (I2)', () {
    test(
      'channel and identity priv appear in no HTTP request or WS frame',
      () async {
        final channelPub = await pubFor(channelPriv);
        final identityPub = await pubFor(identityPriv);
        final otherPub = await pubFor(otherPriv);

        // A wallet with known, fixed key material.
        final wallet = KeyWallet.fromJson({
          'identity': {
            'pub': identityPub,
            'priv': identityPriv,
            'displayName': 'Me',
          },
          'channels': {
            'net1/c1': {'pub': channelPub, 'priv': channelPriv},
          },
          'networks': {
            'net1': {'name': 'fa-team', 'password': 'secret-pw'},
          },
        });

        // Two history envelopes from another member (decryptable only with
        // the channel priv — the sanity proof the wallet keys are live).
        final history1 = await encryptAs(
          sender: (pub: otherPub, priv: otherPriv),
          channelPub: channelPub,
          envelopeId: 'e1',
          plaintext: 'history one',
        );
        final history2 = await encryptAs(
          sender: (pub: otherPub, priv: otherPriv),
          channelPub: channelPub,
          envelopeId: 'e2',
          plaintext: 'history two',
        );

        final httpClient = FakeHttpClient()
          ..respond(200, body: joinBodyOk) // join
          ..respond(200, body: channelsBody) // start: channels
          ..respond(200, body: membersBody) // start: members
          ..respond(
            200,
            body: jsonEncode({
              'items': [
                {
                  'id': 'e1',
                  'channelId': 'c1',
                  'senderId': 'other-1',
                  'payload': history1,
                },
              ],
              'nextCursor': 'cur1',
            }),
          ) // openChannel: first history page
          ..respond(
            200,
            body: jsonEncode({
              'items': [
                {
                  'id': 'e2',
                  'channelId': 'c1',
                  'senderId': 'other-1',
                  'payload': history2,
                },
              ],
            }),
          ); // loadOlder: next page
        final ws = FakeWsConnector();
        final manager = NetworkSessionManager(
          baseUrl: testBase,
          wallet: wallet,
          httpClient: httpClient,
          wsConnector: ws,
        );
        addTearDown(manager.disconnectAll);

        // Drive the full session: join → start → openChannel → loadOlder →
        // sendText. Roster non-empty means start() finished its REST calls,
        // so the scripted responses line up 1:1 with the requests.
        final session = await manager.join(
          networkId: 'net1',
          password: 'secret-pw',
        );
        await waitFor(() => session.roster.isNotEmpty, 'roster');
        await session.openChannel('c1');
        await session.loadOlder('c1');
        // Sanity: the history decrypted — the channel priv is live in the
        // wallet and the scan below is not vacuous.
        expect(
          session.channelStates['c1']!.messages.map((m) => m.text),
          containsAll(<String?>['history one', 'history two']),
        );

        await session.sendText('c1', plaintext);
        await waitFor(
          () => ws.channels.any(
            (c) => c.sentFrames.any((f) => f['type'] == 'envelope.send'),
          ),
          'envelope.send frame',
        );

        // Capture every artifact that crosses a device boundary.
        final artifacts = <String>[
          for (final r in httpClient.requests)
            '${r.method} ${r.url}\n${r.body}',
          for (final channel in ws.channels) ...channel.sent,
        ];
        expect(artifacts, isNotEmpty);
        expect(httpClient.requests, hasLength(5));

        // I2: neither private key appears in ANY artifact.
        for (final artifact in artifacts) {
          expect(
            artifact,
            isNot(contains(channelPriv)),
            reason: 'channel priv leaked: $artifact',
          );
          expect(
            artifact,
            isNot(contains(identityPriv)),
            reason: 'identity priv leaked: $artifact',
          );
          expect(
            artifact,
            isNot(contains(plaintext)),
            reason: 'plaintext leaked: $artifact',
          );
        }

        // The sent envelope payload is ciphertext, not the plaintext.
        final sentEnvelope = ws.channels
            .expand((c) => c.sentFrames)
            .firstWhere((f) => f['type'] == 'envelope.send');
        expect(sentEnvelope['payload']! as String, isNot(contains(plaintext)));

        // The wallet export DOES carry the privs (device-local secret
        // store) — the scan above is not vacuous.
        final walletJson = wallet.serialize();
        expect(walletJson, contains(channelPriv));
        expect(walletJson, contains(identityPriv));

        // The agent invite carries the channel priv in the URI fragment
        // ONLY (client-side per RFC 3986) — never in the connect URI.
        final invite = buildAgentInvite(
          hubUri: Uri.parse('wss://hub.fa1.dev/ws'),
          channel: 'c1',
          pub: channelPub,
          priv: channelPriv,
        );
        final fragment = invite.split('#').last;
        // The fragment query-encodes the base64 padding ('=' → %3D).
        expect(fragment, contains(channelPriv.replaceAll('=', '')));
        expect(fragment, isNot(contains(identityPriv)));
        final parsed = parseAgentInvite(invite);
        expect(parsed.priv, channelPriv);
        expect(parsed.hubUri.toString(), isNot(contains(channelPriv)));
        expect(parsed.hubUri.toString(), isNot(contains(identityPriv)));
      },
    );
  });
}

// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/src/network/connector/envelope.dart';
import 'package:test/test.dart';

void main() {
  NetworkEnvelope mail({
    String msgId = 'm-1',
    String? network = 'net-1',
    String? channel = 'chan-1',
    String? to = 'goal_builder@macbook',
    String ciphertext = 'cipher-text',
    int? seq,
    String? refId,
  }) => NetworkEnvelope(
    kind: NetworkEnvelopeKind.mail,
    msgId: msgId,
    network: network,
    channel: channel,
    from: 'user:u1',
    to: to,
    ts: '2026-11-12T10:00:00.000Z',
    ciphertext: ciphertext,
    seq: seq,
    refId: refId,
  );

  group('round trip', () {
    test('mail envelope encodes and decodes field-for-field', () {
      final envelope = mail(seq: 7, refId: null);
      final json = envelope.toJson();
      expect(json['v'], 1);
      expect(json['kind'], 'mail');
      expect(json['msgId'], 'm-1');
      expect(json.containsKey('refId'), isFalse, reason: 'nulls are omitted');
      expect(json['network'], 'net-1');
      expect(json['channel'], 'chan-1');
      expect(json['from'], 'user:u1');
      expect(json['to'], 'goal_builder@macbook');
      expect(json['ts'], '2026-11-12T10:00:00.000Z');
      expect(json['seq'], 7);
      expect(json['ciphertext'], 'cipher-text');

      final decoded = NetworkEnvelope.fromJson(json);
      expect(decoded, envelope);
      expect(decoded.hashCode, envelope.hashCode);
    });

    test('control frame payload survives the round trip', () {
      final hello = NetworkEnvelope(
        kind: NetworkEnvelopeKind.hello,
        msgId: 'h-1',
        ts: '2026-11-12T10:00:00.000Z',
        payload: {'deviceId': 'macbook', 'rosterDigest': 'abc'},
      );
      final decoded = NetworkEnvelope.fromJson(hello.toJson());
      expect(decoded, hello);
      expect(decoded.payload['deviceId'], 'macbook');
      expect(decoded.payload['rosterDigest'], 'abc');
    });

    test('fromJson tolerates unknown extra keys and missing optionals', () {
      final decoded = NetworkEnvelope.fromJson({
        'v': 1,
        'kind': 'ping',
        'msgId': 'p-1',
        'ts': '2026-11-12T10:00:00.000Z',
        'futureField': {'x': 1},
      });
      expect(decoded.kind, NetworkEnvelopeKind.ping);
      expect(decoded.refId, isNull);
      expect(decoded.network, isNull);
      expect(decoded.seq, isNull);
      expect(decoded.ciphertext, isNull);
      expect(decoded.payload, isEmpty);
    });

    test('unknown kind and wrong version throw FormatException', () {
      expect(
        () => NetworkEnvelope.fromJson({
          'v': 1,
          'kind': 'teleport',
          'msgId': 'x-1',
          'ts': '2026-11-12T10:00:00.000Z',
        }),
        throwsFormatException,
      );
      expect(
        () => NetworkEnvelope.fromJson({
          'v': 2,
          'kind': 'mail',
          'msgId': 'x-1',
          'ts': '2026-11-12T10:00:00.000Z',
        }),
        throwsFormatException,
      );
      expect(
        () => NetworkEnvelope.fromJson('not a map'),
        throwsFormatException,
      );
      expect(
        () => NetworkEnvelope.fromJson({
          'v': 1,
          'kind': 'mail',
          'ts': '2026-11-12T10:00:00.000Z',
        }),
        throwsFormatException,
        reason: 'msgId is mandatory',
      );
    });

    test('parseValid throws EnvelopeValidationException on bad mail', () {
      final invalid = NetworkEnvelope(
        kind: NetworkEnvelopeKind.mail,
        msgId: 'm-2',
        ts: '2026-11-12T10:00:00.000Z',
        ciphertext: 'c',
      );
      expect(invalid.isValid, isFalse);
      expect(invalid.validationErrors, contains(contains('network')));
      expect(
        () => NetworkEnvelope.parseValid(invalid.toJson()),
        throwsA(isA<EnvelopeValidationException>()),
      );
    });
  });

  group('validation', () {
    test('valid mail passes', () {
      expect(mail().isValid, isTrue);
      expect(mail().validationErrors, isEmpty);
    });

    test('mail requires network and channel', () {
      final noNetwork = NetworkEnvelope(
        kind: NetworkEnvelopeKind.mail,
        msgId: 'm-3',
        channel: 'chan-1',
        to: 'a@b',
        ts: '2026-11-12T10:00:00.000Z',
        ciphertext: 'c',
      );
      final noChannel = NetworkEnvelope(
        kind: NetworkEnvelopeKind.mail,
        msgId: 'm-4',
        network: 'net-1',
        to: 'a@b',
        ts: '2026-11-12T10:00:00.000Z',
        ciphertext: 'c',
      );
      expect(noNetwork.validationErrors.join(' '), contains('network'));
      expect(noChannel.validationErrors.join(' '), contains('channel'));
    });

    test('dm mail requires to', () {
      final dm = NetworkEnvelope(
        kind: NetworkEnvelopeKind.mail,
        msgId: 'm-5',
        network: 'net-1',
        channel: dmChannelId('u1', 'goal_builder@macbook'),
        from: 'user:u1',
        ts: '2026-11-12T10:00:00.000Z',
        ciphertext: 'c',
      );
      expect(dm.validationErrors.join(' '), contains('to'));
    });

    test('mail requires ciphertext', () {
      final bare = mail();
      final decrypted = NetworkEnvelope(
        kind: NetworkEnvelopeKind.mail,
        msgId: 'm-6',
        network: 'net-1',
        channel: 'chan-1',
        ts: '2026-11-12T10:00:00.000Z',
      );
      expect(decrypted.validationErrors.join(' '), contains('ciphertext'));
      expect(bare.isValid, isTrue);
    });

    test('ack, error and hello_ok require refId', () {
      for (final kind in [
        NetworkEnvelopeKind.ack,
        NetworkEnvelopeKind.error,
        NetworkEnvelopeKind.helloOk,
      ]) {
        final withoutRef = NetworkEnvelope(
          kind: kind,
          msgId: 'r-1',
          ts: '2026-11-12T10:00:00.000Z',
        );
        expect(withoutRef.validationErrors.join(' '), contains('refId'));
        expect(
          NetworkEnvelope(
            kind: kind,
            msgId: 'r-2',
            refId: 'm-1',
            ts: '2026-11-12T10:00:00.000Z',
          ).isValid,
          isTrue,
          reason: '$kind with refId validates',
        );
      }
    });

    test('hello requires deviceId in its payload', () {
      final bare = NetworkEnvelope(
        kind: NetworkEnvelopeKind.hello,
        msgId: 'h-2',
        ts: '2026-11-12T10:00:00.000Z',
      );
      expect(bare.validationErrors.join(' '), contains('deviceId'));
      final good = NetworkEnvelope(
        kind: NetworkEnvelopeKind.hello,
        msgId: 'h-3',
        ts: '2026-11-12T10:00:00.000Z',
        payload: {'deviceId': 'macbook'},
      );
      expect(good.isValid, isTrue);
    });
  });

  group('channel addressing (contract §7)', () {
    test('dmChannelId is stable both directions', () {
      expect(
        dmChannelId('u1', agentAddress('goal_builder', 'macbook')),
        'dm:user:u1:goal_builder@macbook',
      );
      // Same inputs, same id — the user side and the agent side derive the
      // identical virtual channel id.
      expect(
        dmChannelId('u1', agentAddress('goal_builder', 'macbook')),
        dmChannelId('u1', 'goal_builder@macbook'),
      );
    });

    test('isDmChannel distinguishes dm ids from group channels', () {
      expect(isDmChannel(dmChannelId('u1', 'goal_builder@macbook')), isTrue);
      expect(isDmChannel('chan-1'), isFalse);
      expect(isDmChannel(''), isFalse);
    });

    test('agentAddress joins name and device per contract §1', () {
      expect(agentAddress('goal_builder', 'macbook'), 'goal_builder@macbook');
    });

    test('default id factory mints unique uuid-shaped msgIds', () {
      final a = defaultIdFactory();
      final b = defaultIdFactory();
      expect(a, isNot(b));
      expect(
        a,
        matches(
          RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-'
            r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
    });

    test('rfc3339Timestamp renders RFC3339 UTC', () {
      final stamp = rfc3339Timestamp(
        DateTime.parse('2026-11-12T12:30:45.123Z'),
      );
      expect(stamp, '2026-11-12T12:30:45.123Z');
    });
  });

  test('presence-family frames (CRAP coverage) require a payload', () {
    for (final kind in [
      NetworkEnvelopeKind.presence,
      NetworkEnvelopeKind.roster,
      NetworkEnvelopeKind.wakeHint,
    ]) {
      final bare = NetworkEnvelope(
        kind: kind,
        msgId: 'p-1',
        ts: '2026-11-12T10:00:00.000Z',
      );
      expect(bare.validationErrors.single, contains('requires payload'));
      final carried = NetworkEnvelope(
        kind: kind,
        msgId: 'p-1',
        ts: '2026-11-12T10:00:00.000Z',
        payload: <String, Object?>{'state': 'live'},
      );
      expect(carried.validationErrors, isEmpty);
    }
  });

  test('ping/pong frames carry no kind-specific requirements', () {
    for (final kind in [NetworkEnvelopeKind.ping, NetworkEnvelopeKind.pong]) {
      final bare = NetworkEnvelope(
        kind: kind,
        msgId: 'pp-1',
        ts: '2026-11-12T10:00:00.000Z',
      );
      expect(bare.validationErrors, isEmpty);
      expect(bare.isValid, isTrue);
    }
  });

  test('toString never leaks ciphertext content (relay-only hygiene)', () {
    final text = mail().toString();
    expect(text.contains('cipher-text'), isFalse);
    expect(text, contains('mail'));
    expect(text, contains('m-1'));
  });
}

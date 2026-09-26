// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/network/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MemberClass / Presence wire parsing', () {
    test('known wire names parse to their enum value', () {
      expect(MemberClass.parse('owner'), MemberClass.owner);
      expect(MemberClass.parse('admin'), MemberClass.admin);
      expect(MemberClass.parse('member'), MemberClass.member);
      expect(MemberClass.parse('guest'), MemberClass.guest);
      expect(MemberClass.parse('agent'), MemberClass.agent);
      expect(Presence.parse('live'), Presence.live);
      expect(Presence.parse('busy'), Presence.busy);
      expect(Presence.parse('offline'), Presence.offline);
    });

    test('unknown wire names and junk tolerate to .unknown', () {
      expect(MemberClass.parse('superuser'), MemberClass.unknown);
      expect(MemberClass.parse(null), MemberClass.unknown);
      expect(MemberClass.parse(42), MemberClass.unknown);
      expect(Presence.parse('away'), Presence.unknown);
      expect(Presence.parse(null), Presence.unknown);
    });
  });

  group('Network.fromJson', () {
    test('full payload', () {
      final n = Network.fromJson(
        jsonDecode(
              '{"id":"net1","name":"fa-team","ownerId":"u1",'
              '"admins":["u2"],"publicChannels":["c1"],'
              '"createdAt":"2026-01-02T03:04:05Z"}',
            )
            as Map<String, Object?>,
      );
      expect(n.id, 'net1');
      expect(n.name, 'fa-team');
      expect(n.ownerId, 'u1');
      expect(n.admins, ['u2']);
      expect(n.publicChannels, ['c1']);
      expect(n.createdAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
    });

    test('missing optional fields do not throw', () {
      final n = Network.fromJson(
        jsonDecode('{"id":"net1","name":"fa-team","ownerId":"u1"}')
            as Map<String, Object?>,
      );
      expect(n.admins, isNull);
      expect(n.publicChannels, isEmpty);
      expect(n.isPublic, isFalse);
      expect(n.createdAt, isNull);
    });

    test('the public-directory flag parses', () {
      final n = Network.fromJson(
        jsonDecode(
              '{"id":"net1","name":"fa-team","ownerId":"u1","public":true}',
            )
            as Map<String, Object?>,
      );
      expect(n.isPublic, isTrue);
    });
  });

  group('PublicNetworkInfo.fromJson', () {
    test('directory item with int counts (deployed contract)', () {
      final p = PublicNetworkInfo.fromJson(
        jsonDecode(
              '{"id":"pub-1","name":"open-hub","publicChannels":3,'
              '"memberCount":42}',
            )
            as Map<String, Object?>,
      );
      expect(p.id, 'pub-1');
      expect(p.name, 'open-hub');
      expect(p.publicChannelCount, 3);
      expect(p.memberCount, 42);
    });

    test('counts are optional; id + name are required', () {
      final p = PublicNetworkInfo.fromJson(
        jsonDecode('{"id":"pub-2","name":"agents-lab"}')
            as Map<String, Object?>,
      );
      expect(p.publicChannelCount, isNull);
      expect(p.memberCount, isNull);
      expect(
        () => PublicNetworkInfo.fromJson(
          jsonDecode('{"name":"x"}') as Map<String, Object?>,
        ),
        throwsFormatException,
      );
    });
  });

  group('Member.fromJson', () {
    test('full payload', () {
      final m = Member.fromJson(
        jsonDecode(
              '{"id":"m1","class":"agent","displayName":"bot",'
              '"presence":"busy"}',
            )
            as Map<String, Object?>,
      );
      expect(m.id, 'm1');
      expect(m.memberClass, MemberClass.agent);
      expect(m.displayName, 'bot');
      expect(m.presence, Presence.busy);
    });

    test('unknown class / presence tolerated', () {
      final m = Member.fromJson(
        jsonDecode(
              '{"id":"m1","class":"wizard","displayName":"x",'
              '"presence":"sleeping"}',
            )
            as Map<String, Object?>,
      );
      expect(m.memberClass, MemberClass.unknown);
      expect(m.presence, Presence.unknown);
    });
  });

  group('Channel.fromJson', () {
    test('optional name, acl and retentionDays tolerated', () {
      final c = Channel.fromJson(
        jsonDecode('{"id":"c1","networkId":"n1","public":true}')
            as Map<String, Object?>,
      );
      expect(c.id, 'c1');
      expect(c.networkId, 'n1');
      expect(c.isPublic, isTrue);
      expect(c.name, isNull);
      expect(c.acl, isNull);
      expect(c.retentionDays, isNull);
    });

    test('retentionDays 0 is preserved (not treated as absent)', () {
      final c = Channel.fromJson(
        jsonDecode(
              '{"id":"c1","networkId":"n1","public":false,'
              '"retentionDays":0}',
            )
            as Map<String, Object?>,
      );
      expect(c.retentionDays, 0);
    });
  });

  group('NetworkAgent.fromJson', () {
    test('full + minimal payloads', () {
      final a = NetworkAgent.fromJson(
        jsonDecode(
              '{"agentId":"a1","displayName":"Helper","presence":"live",'
              '"wakeupRegistered":true}',
            )
            as Map<String, Object?>,
      );
      expect(a.agentId, 'a1');
      expect(a.presence, Presence.live);
      expect(a.wakeupRegistered, isTrue);

      final bare = NetworkAgent.fromJson(
        jsonDecode('{"agentId":"a2","displayName":"B","presence":"offline"}')
            as Map<String, Object?>,
      );
      expect(bare.wakeupRegistered, isNull);
    });
  });

  group('Envelope', () {
    test('fromJson full payload', () {
      final e = Envelope.fromJson(
        jsonDecode(
              '{"id":"e1","channelId":"c1","senderId":"m1",'
              '"payload":"aGk=","mentions":["a1"],'
              '"createdAt":"2026-01-02T03:04:05Z"}',
            )
            as Map<String, Object?>,
      );
      expect(e.id, 'e1');
      expect(e.channelId, 'c1');
      expect(e.senderId, 'm1');
      expect(e.payload, 'aGk=');
      expect(e.mentions, ['a1']);
      expect(e.createdAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
    });

    test('minimal payload does not throw', () {
      final e = Envelope.fromJson(
        jsonDecode(
              '{"id":"e1","channelId":"c1","senderId":"m1",'
              '"payload":"aGk="}',
            )
            as Map<String, Object?>,
      );
      expect(e.mentions, isNull);
      expect(e.createdAt, isNull);
    });

    test('toJson round-trips the wire fields', () {
      final e = Envelope(
        id: 'e1',
        channelId: 'c1',
        senderId: 'm1',
        payload: 'aGk=',
        mentions: const ['a1'],
        createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
      );
      final json = e.toJson();
      expect(json['id'], 'e1');
      expect(json['channelId'], 'c1');
      expect(json['payload'], 'aGk=');
      expect(json['mentions'], ['a1']);
      expect(json['createdAt'], '2026-01-02T03:04:05.000Z');
      expect(Envelope.fromJson(json).id, 'e1');
    });

    test('toJson omits absent optional fields', () {
      final json = const Envelope(
        id: 'e1',
        channelId: 'c1',
        senderId: 'm1',
        payload: 'aGk=',
      ).toJson();
      expect(json.containsKey('mentions'), isFalse);
      expect(json.containsKey('createdAt'), isFalse);
    });
  });

  group('JoinResult.fromJson', () {
    test('full payload with network', () {
      final r = JoinResult.fromJson(
        jsonDecode(
              '{"sessionToken":"tok","identity":{"id":"m1",'
              '"class":"member","displayName":"Al","authName":"al-gh"},'
              '"network":{"id":"n1","name":"fa-team","ownerId":"u1"}}',
            )
            as Map<String, Object?>,
      );
      expect(r.sessionToken, 'tok');
      expect(r.identity.id, 'm1');
      expect(r.identity.memberClass, MemberClass.member);
      expect(r.identity.displayName, 'Al');
      expect(r.identity.authName, 'al-gh');
      expect(r.network?.id, 'n1');
    });

    test('missing network and authName tolerated', () {
      final r = JoinResult.fromJson(
        jsonDecode(
              '{"sessionToken":"tok","identity":{"id":"m1",'
              '"class":"guest","displayName":"G"}}',
            )
            as Map<String, Object?>,
      );
      expect(r.network, isNull);
      expect(r.identity.authName, isNull);
    });
  });

  group('Wakeup models', () {
    test('WakeupRegistration.fromJson', () {
      final r = WakeupRegistration.fromJson(
        jsonDecode(
              '{"url":"https://hook.example/x","debounceSeconds":300,'
              '"createdAt":"2026-01-02T03:04:05Z"}',
            )
            as Map<String, Object?>,
      );
      expect(r.url, 'https://hook.example/x');
      expect(r.debounceSeconds, 300);
      expect(r.createdAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
    });

    test('WakeupDispatch.fromJson with optional note', () {
      final d = WakeupDispatch.fromJson(
        jsonDecode(
              '{"agentId":"a1","at":"2026-01-02T03:04:05Z",'
              '"outcome":"delivered","note":"ok"}',
            )
            as Map<String, Object?>,
      );
      expect(d.agentId, 'a1');
      expect(d.outcome, 'delivered');
      expect(d.note, 'ok');
      expect(d.at, DateTime.utc(2026, 1, 2, 3, 4, 5));

      final bare = WakeupDispatch.fromJson(
        jsonDecode(
              '{"agentId":"a1","at":"2026-01-02T03:04:05Z",'
              '"outcome":"backoff"}',
            )
            as Map<String, Object?>,
      );
      expect(bare.note, isNull);
    });
  });
}

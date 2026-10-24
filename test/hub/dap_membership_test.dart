// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/src/hub/dap_membership.dart';
import 'package:test/test.dart';

DapChannelMembership m(
  String channel,
  DapChannelScope scope, {
  String hub = 'wss://hub.fa1.dev/ws',
  String? priv,
}) => DapChannelMembership(
  hubUrl: hub,
  channelId: channel,
  scope: scope,
  joinedAt: DateTime.utc(2026, 10, 24),
  priv: priv,
);

void main() {
  group('DapChannelMembership', () {
    test('json round-trip preserves all fields', () {
      final original = m(
        'team',
        DapChannelScope.project,
        priv: 'k',
      ).copyWithPub('p');
      final restored = DapChannelMembership.fromJson(original.toJson());
      expect(restored.hubUrl, original.hubUrl);
      expect(restored.channelId, 'team');
      expect(restored.scope, DapChannelScope.project);
      expect(restored.joinedAt, original.joinedAt);
      expect(restored.pub, 'p');
      expect(restored.priv, 'k');
    });

    test('keyless (public channel) round-trip omits keys', () {
      final restored = DapChannelMembership.fromJson(
        m('open', DapChannelScope.session).toJson(),
      );
      expect(restored.pub, isNull);
      expect(restored.priv, isNull);
      expect(restored.toJson().containsKey('priv'), isFalse);
    });

    test('malformed records fail loudly', () {
      expect(
        () => DapChannelMembership.fromJson({'channelId': 'x'}),
        throwsFormatException,
      );
      expect(
        () => DapChannelMembership.fromJson({
          'hubUrl': 'wss://h/ws',
          'channelId': 'x',
          'scope': 'galaxy',
        }),
        throwsFormatException,
      );
    });
  });

  group('DapMembershipUnion', () {
    test('same channel at two scopes → one effective membership', () {
      final union = DapMembershipUnion([
        m('team', DapChannelScope.global, priv: 'global-key'),
        m('team', DapChannelScope.session, priv: 'session-key'),
      ]);
      final effective = union.effective();
      expect(effective, hasLength(1));
      // Narrowest scope wins the key material.
      expect(effective.single.priv, 'session-key');
    });

    test('scopesOf lists every scope for the badges', () {
      final union = DapMembershipUnion([
        m('team', DapChannelScope.global),
        m('team', DapChannelScope.project),
        m('other', DapChannelScope.session),
      ]);
      expect(union.scopesOf('wss://hub.fa1.dev/ws', 'team'), [
        DapChannelScope.project,
        DapChannelScope.global,
      ]);
      expect(union.scopesOf('wss://hub.fa1.dev/ws', 'other'), [
        DapChannelScope.session,
      ]);
    });

    test('same channel id on DIFFERENT hubs stays separate (E3)', () {
      final union = DapMembershipUnion([
        m('team', DapChannelScope.global),
        m('team', DapChannelScope.session, hub: 'wss://other/ws'),
      ]);
      expect(union.effective(), hasLength(2));
    });

    test('E1: leave(session) keeps global; leaving the last stops it', () {
      final both = DapMembershipUnion([
        m('team', DapChannelScope.session),
        m('team', DapChannelScope.global),
      ]);
      final afterSessionLeave = both.leaving(
        'wss://hub.fa1.dev/ws',
        'team',
        DapChannelScope.session,
      );
      expect(afterSessionLeave.effective(), hasLength(1));
      expect(
        afterSessionLeave.effective().single.scope,
        DapChannelScope.global,
      );
      final afterAll = afterSessionLeave.leaving(
        'wss://hub.fa1.dev/ws',
        'team',
        DapChannelScope.global,
      );
      expect(afterAll.effective(), isEmpty);
    });

    test('effective output is deterministic (sorted by key)', () {
      final union = DapMembershipUnion([
        m('b', DapChannelScope.session),
        m('a', DapChannelScope.session),
      ]);
      expect(union.effective().map((m) => m.channelId), ['a', 'b']);
    });
  });
}

extension on DapChannelMembership {
  DapChannelMembership copyWithPub(String pub) => DapChannelMembership(
    hubUrl: hubUrl,
    channelId: channelId,
    scope: scope,
    joinedAt: joinedAt,
    pub: pub,
    priv: priv,
  );
}

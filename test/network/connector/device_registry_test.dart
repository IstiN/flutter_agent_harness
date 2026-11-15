// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter_agent_harness/src/network/connector/device_registry.dart';
import 'package:test/test.dart';

void main() {
  group('exposure defaults (AC3 local half, contract §2/§6)', () {
    test('fresh device in a SHARED network projects an empty roster', () {
      final registry = DeviceRegistry()
        ..configureNetwork('shared-1', NetworkKind.shared);
      final roster = registry.rosterProjection('shared-1');
      expect(roster.agents, isEmpty);
      expect(roster.kind, NetworkKind.shared);
    });

    test('fresh device in a SHARED network hides registered sessions', () {
      final registry = DeviceRegistry()
        ..configureNetwork('shared-1', NetworkKind.shared)
        ..registerAgent('goal_builder', 'macbook', dmPub: 'dm-pub-1')
        ..registerSession(
          const SessionRegistration(
            id: 'sess-1',
            agentAddressOf: 'goal_builder@macbook',
          ),
        );
      final roster = registry.rosterProjection('shared-1');
      // Deny-by-default: even channel-less agents and their sessions stay
      // unpublished on a shared network.
      expect(roster.agents, isEmpty);
      expect(registry.isSessionExposed('shared-1', 'sess-1'), isFalse);
    });

    test('shared-network agents follow channel membership visibility', () {
      final registry = DeviceRegistry()
        ..configureNetwork('shared-1', NetworkKind.shared)
        ..registerAgent('goal_builder', 'macbook')
        ..registerAgent('quiet_agent', 'macbook')
        ..setAgentChannels('goal_builder', 'shared-1', ['#room']);
      final roster = registry.rosterProjection('shared-1');
      expect(roster.agents.map((a) => a.name), ['goal_builder']);
      // Sessions stay OFF on shared networks even when the agent is visible.
      expect(registry.isSessionExposed('shared-1', 'any-session'), isFalse);
    });

    test('personal network defaults agents AND sessions ON', () {
      final registry = DeviceRegistry()
        ..configureNetwork('personal-1', NetworkKind.personal)
        ..registerAgent('goal_builder', 'macbook', dmPub: 'dm-pub-1')
        ..registerSession(
          const SessionRegistration(
            id: 'sess-1',
            agentAddressOf: 'goal_builder@macbook',
          ),
        );
      final roster = registry.rosterProjection('personal-1');
      expect(roster.agents, hasLength(1));
      expect(roster.agents.single.sessions, ['sess-1']);
      expect(
        registry.isAgentExposed('personal-1', 'goal_builder', 'macbook'),
        isTrue,
      );
      expect(registry.isSessionExposed('personal-1', 'sess-1'), isTrue);
    });

    test('unconfigured networks use the conservative shared default', () {
      final registry = DeviceRegistry()
        ..registerAgent('goal_builder', 'macbook');
      expect(registry.kindOf('mystery'), isNull);
      expect(
        registry.isAgentExposed('mystery', 'goal_builder', 'macbook'),
        isFalse,
        reason: 'deny-by-default without membership',
      );
      expect(registry.isSessionExposed('mystery', 'sess'), isFalse);
    });

    test('disable unpublishes within the projection', () {
      final registry = DeviceRegistry()
        ..configureNetwork('personal-1', NetworkKind.personal)
        ..registerAgent('goal_builder', 'macbook')
        ..registerSession(
          const SessionRegistration(
            id: 'sess-1',
            agentAddressOf: 'goal_builder@macbook',
          ),
        );
      expect(registry.rosterProjection('personal-1').agents, hasLength(1));
      registry.setAgentExposed(
        'personal-1',
        'goal_builder',
        'macbook',
        exposed: false,
      );
      expect(
        registry.rosterProjection('personal-1').agents,
        isEmpty,
        reason: '§6: toggle unpublishes within one heartbeat',
      );
      // An exposed session under a hidden agent stays unpublished.
      registry.setAgentExposed(
        'personal-1',
        'goal_builder',
        'macbook',
        exposed: true,
      );
      registry.setSessionExposed('personal-1', 'sess-1', exposed: false);
      expect(
        registry.rosterProjection('personal-1').agents.single.sessions,
        isEmpty,
      );
    });

    test('explicit flags do not leak across networks', () {
      final registry = DeviceRegistry()
        ..configureNetwork('personal-1', NetworkKind.personal)
        ..configureNetwork('shared-1', NetworkKind.shared)
        ..registerAgent('goal_builder', 'macbook')
        ..setAgentExposed('shared-1', 'goal_builder', 'macbook', exposed: true);
      expect(
        registry.isAgentExposed('shared-1', 'goal_builder', 'macbook'),
        isTrue,
      );
      expect(
        registry.isAgentExposed('personal-1', 'goal_builder', 'macbook'),
        isTrue,
        reason: 'personal default still applies',
      );
    });
  });

  group('composite identity + dmPub (contract v1.1, §1/§7)', () {
    test('same agent name on two devices keeps separate dmPubs by address', () {
      final registry = DeviceRegistry()
        ..configureNetwork('personal-1', NetworkKind.personal)
        ..registerAgent('goal_builder', 'macbook', dmPub: 'pub-macbook')
        ..registerAgent('goal_builder', 'ipad', dmPub: 'pub-ipad');
      final roster = registry.rosterProjection('personal-1').agents;
      final byAddress = {for (final entry in roster) entry.address: entry};
      expect(byAddress['goal_builder@macbook']!.dmPub, 'pub-macbook');
      expect(byAddress['goal_builder@ipad']!.dmPub, 'pub-ipad');
    });

    test('unregisterAgent removes exactly the named device and cascades', () {
      final registry = DeviceRegistry()
        ..configureNetwork('personal-1', NetworkKind.personal)
        ..registerAgent('goal_builder', 'macbook')
        ..registerAgent('goal_builder', 'ipad')
        ..registerSession(
          const SessionRegistration(
            id: 'sess-mac',
            agentAddressOf: 'goal_builder@macbook',
          ),
        );
      registry.unregisterAgent('goal_builder', 'macbook');
      final addresses = registry.agents.map((a) => a.address).toSet();
      expect(addresses, {'goal_builder@ipad'});
      expect(registry.sessions, isEmpty, reason: 'session cascaded away');
    });
  });

  group('change stream (presence propagation seam)', () {
    test('emits a change per mutation kind', () async {
      final registry = DeviceRegistry();
      final changes = <DeviceRegistryChange>[];
      final subscription = registry.changes.listen(changes.add);
      registry
        ..configureNetwork('personal-1', NetworkKind.personal)
        ..registerAgent('goal_builder', 'macbook')
        ..setAgentChannels('goal_builder', 'personal-1', ['#a'])
        ..registerSession(
          const SessionRegistration(
            id: 'sess-1',
            agentAddressOf: 'goal_builder@macbook',
          ),
        )
        ..setSessionExposed('personal-1', 'sess-1', exposed: false)
        ..setAgentExposed(
          'personal-1',
          'goal_builder',
          'macbook',
          exposed: false,
        )
        ..unregisterSession('sess-1')
        ..unregisterAgent('goal_builder', 'macbook');
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();
      expect(changes.map((change) => change.kind), [
        DeviceRegistryChangeKind.networkKindChanged,
        DeviceRegistryChangeKind.agentRegistered,
        DeviceRegistryChangeKind.agentChannelsChanged,
        DeviceRegistryChangeKind.sessionRegistered,
        DeviceRegistryChangeKind.exposureChanged,
        DeviceRegistryChangeKind.exposureChanged,
        DeviceRegistryChangeKind.sessionUnregistered,
        DeviceRegistryChangeKind.agentUnregistered,
      ]);
      registry.dispose();
    });

    test('dispose closes the stream', () async {
      final registry = DeviceRegistry();
      final done = Completer<void>();
      registry.changes.listen((_) {}, onDone: done.complete);
      registry.dispose();
      await done.future.timeout(const Duration(seconds: 1));
    });

    test('unknown targets are no-ops, not throws', () {
      final registry = DeviceRegistry()
        ..unregisterAgent('ghost', 'nowhere')
        ..unregisterSession('ghost')
        ..setAgentChannels('ghost', 'net', ['#a']);
      expect(registry.agents, isEmpty);
      expect(registry.sessions, isEmpty);
    });
  });

  test('roster projection carries name, address and dmPub fields', () {
    final registry = DeviceRegistry()
      ..configureNetwork('personal-1', NetworkKind.personal)
      ..registerAgent('goal_builder', 'macbook', dmPub: 'pub-1');
    final entry = registry.rosterProjection('personal-1').agents.single;
    expect(entry.name, 'goal_builder');
    expect(entry.address, 'goal_builder@macbook');
    expect(entry.dmPub, 'pub-1');
    expect(entry.toString(), contains('goal_builder@macbook'));
  });

  group('DeviceRegistryChange.toString', () {
    test('omits unset optional fields', () {
      expect(
        const DeviceRegistryChange(
          kind: DeviceRegistryChangeKind.agentChannelsChanged,
        ).toString(),
        'DeviceRegistryChange(DeviceRegistryChangeKind.agentChannelsChanged)',
      );
    });

    test('includes every set optional field in order', () {
      expect(
        const DeviceRegistryChange(
          kind: DeviceRegistryChangeKind.networkKindChanged,
          networkId: 'shared-1',
          agentAddressOf: 'goal_builder@macbook',
          sessionId: 'sess-1',
        ).toString(),
        'DeviceRegistryChange(DeviceRegistryChangeKind.networkKindChanged'
        ' network=shared-1 agent=goal_builder@macbook session=sess-1)',
      );
    });
  });
}

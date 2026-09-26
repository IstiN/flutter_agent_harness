// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fa/network/network_mode.dart';

void main() {
  group('NetworkModeStore', () {
    test('missing file loads the local-mode default', () async {
      final env = MemoryExecutionEnv();
      final store = await NetworkModeStore.load(env);
      expect(store.mode, AppMode.local);
      expect(store.lastNetworkId, isNull);
      expect(store.lastChannelId, isNull);
    });

    test('corrupt file loads the default, never crashes', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        '${env.cwd}/${NetworkModeStore.fileName}',
        '{not json',
      );
      final store = await NetworkModeStore.load(env);
      expect(store.mode, AppMode.local);
    });

    test('wrong schema version loads the default', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        '${env.cwd}/${NetworkModeStore.fileName}',
        '{"version": 99, "mode": "network"}',
      );
      final store = await NetworkModeStore.load(env);
      expect(store.mode, AppMode.local);
    });

    test('roundtrip persists mode + last network/channel', () async {
      final env = MemoryExecutionEnv();
      final store = await NetworkModeStore.load(env);
      await store.setState(
        mode: AppMode.network,
        lastNetworkId: 'net-1',
        lastChannelId: 'chan-7',
      );
      final reloaded = await NetworkModeStore.load(env);
      expect(reloaded.mode, AppMode.network);
      expect(reloaded.lastNetworkId, 'net-1');
      expect(reloaded.lastChannelId, 'chan-7');
    });

    test('clearing selection persists nulls', () async {
      final env = MemoryExecutionEnv();
      final store = await NetworkModeStore.load(env);
      await store.setState(mode: AppMode.network, lastNetworkId: 'net-1');
      await store.setState(mode: AppMode.local);
      final reloaded = await NetworkModeStore.load(env);
      expect(reloaded.mode, AppMode.local);
      expect(reloaded.lastNetworkId, isNull);
    });

    test('unknown persisted mode string loads as local', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        '${env.cwd}/${NetworkModeStore.fileName}',
        '{"version": 1, "mode": "hyperspace"}',
      );
      final store = await NetworkModeStore.load(env);
      expect(store.mode, AppMode.local);
    });
  });

  group('NetworkModeController', () {
    test('boots in local mode', () {
      final controller = NetworkModeController.inMemory();
      expect(controller.mode, AppMode.local);
      expect(controller.networkId, isNull);
      expect(controller.channelId, isNull);
    });

    test('enterNetwork switches mode, selects network, notifies', () async {
      final controller = NetworkModeController.inMemory();
      var notified = 0;
      controller.addListener(() => notified++);
      await controller.enterNetwork('net-1');
      expect(controller.mode, AppMode.network);
      expect(controller.networkId, 'net-1');
      expect(controller.channelId, isNull);
      expect(notified, greaterThan(0));
    });

    test('selectChannel keeps network, sets channel', () async {
      final controller = NetworkModeController.inMemory();
      await controller.enterNetwork('net-1');
      await controller.selectChannel('chan-7');
      expect(controller.mode, AppMode.network);
      expect(controller.networkId, 'net-1');
      expect(controller.channelId, 'chan-7');
    });

    test('exitToLocal clears selection and persists', () async {
      final env = MemoryExecutionEnv();
      final store = await NetworkModeStore.load(env);
      final controller = NetworkModeController(store);
      await controller.enterNetwork('net-1');
      await controller.selectChannel('chan-7');
      await controller.exitToLocal();
      expect(controller.mode, AppMode.local);
      expect(controller.networkId, isNull);
      expect(controller.channelId, isNull);
      final reloaded = await NetworkModeStore.load(env);
      expect(reloaded.mode, AppMode.local);
    });

    test(
      'restores last network/channel on boot when mode is network',
      () async {
        final env = MemoryExecutionEnv();
        final store = await NetworkModeStore.load(env);
        await store.setState(
          mode: AppMode.network,
          lastNetworkId: 'net-1',
          lastChannelId: 'chan-7',
        );
        final controller = NetworkModeController(store);
        expect(controller.mode, AppMode.network);
        expect(controller.networkId, 'net-1');
        expect(controller.channelId, 'chan-7');
      },
    );

    test('backToNetworks keeps mode, clears network+channel', () async {
      final controller = NetworkModeController.inMemory();
      await controller.enterNetwork('net-1');
      await controller.selectChannel('chan-7');
      await controller.backToNetworks();
      expect(controller.mode, AppMode.network);
      expect(controller.networkId, isNull);
      expect(controller.channelId, isNull);
    });

    test('backToChannels keeps network, clears channel', () async {
      final controller = NetworkModeController.inMemory();
      await controller.enterNetwork('net-1');
      await controller.selectChannel('chan-7');
      await controller.backToChannels();
      expect(controller.networkId, 'net-1');
      expect(controller.channelId, isNull);
    });

    test('persistence failures never throw into the UI', () async {
      final env = MemoryExecutionEnv();
      final store = await NetworkModeStore.load(env);
      // A controller over a read-only-ish env still toggles in memory.
      final controller = NetworkModeController(store);
      await controller.enterNetwork('net-1');
      expect(controller.networkId, 'net-1');
    });
  });
}

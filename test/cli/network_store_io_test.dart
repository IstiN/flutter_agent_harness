// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/cli/network_store_io.dart';
import 'package:flutter_agent_harness/src/network/network_account.dart';
import 'package:test/test.dart';

void main() {
  test(
    'device DM private keys persist beside enrollment credentials',
    () async {
      final home = await Directory.systemTemp.createTemp('fa-net-dm-keys-');
      addTearDown(() async {
        if (await home.exists()) await home.delete(recursive: true);
      });
      final store = FileNetworkCredentialStore(home.path);
      await store.writeDevice(
        const NetworkDeviceCredentials(
          deviceId: 'dev-1',
          deviceToken: 'device-secret',
          personalNetworkId: 'personal-1',
          name: 'workstation',
        ),
      );

      await store.writeDmPrivateKeys(const {'goal@dev-1': 'cHJpdmF0ZS1rZXk='});

      final restored = await FileNetworkCredentialStore(home.path).readDevice();
      expect(restored?.deviceToken, 'device-secret');
      expect(restored?.personalNetworkId, 'personal-1');
      expect(restored?.name, 'workstation');
      expect(restored?.dmPrivateKeys, {'goal@dev-1': 'cHJpdmF0ZS1rZXk='});
      expect(await store.readDmPrivateKeys(), restored?.dmPrivateKeys);
      final json =
          jsonDecode(
                await File(
                  '${home.path}/.fah/network/device.json',
                ).readAsString(),
              )
              as Map;
      expect(json['deviceToken'], 'device-secret');
      expect(json['dmPrivateKeys'], {'goal@dev-1': 'cHJpdmF0ZS1rZXk='});
      if (!Platform.isWindows) {
        final file = File('${home.path}/.fah/network/device.json');
        expect(await file.stat().then((stat) => stat.mode & 63), 0);
      }
    },
  );
}

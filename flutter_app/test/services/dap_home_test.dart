import 'dart:io';

import 'package:fa/services/dap_home.dart';
import 'package:fa/services/dap_service_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => dapHomeOverride = null);

  test(
    'mobile sandbox home persists the hub URL when HOME is unusable',
    () async {
      final dir = await Directory.systemTemp.createTemp('dap_home');
      addTearDown(() => dir.delete(recursive: true));
      dapHomeOverride = dir.path;
      // Android shape: no HOME / USERPROFILE in the environment.
      final svc = IoDapHubService(environment: const {});
      await svc.saveConnection(url: 'ws://127.0.0.1:8787/ws', name: 'phone');
      expect(File('${dir.path}/.dap/config.json').existsSync(), isTrue);
      // A fresh service (= app restart) reads the saved URL back.
      final again = IoDapHubService(environment: const {});
      expect((await again.load()).url, 'ws://127.0.0.1:8787/ws');
    },
  );

  test('explicit home beats the override', () {
    dapHomeOverride = '/a';
    expect(resolveDapHome('/b'), '/b');
    expect(resolveDapHome(null), '/a');
  });
}

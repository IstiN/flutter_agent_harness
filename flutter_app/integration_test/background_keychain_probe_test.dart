// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/background_execution.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Live-device probe for the two `fah/*` channels this issue (#329) touched:
/// every call must complete WITHOUT `MissingPluginException` — before the
/// fix, Android logged `MissingPluginException(fah/background)` on every
/// agent run, and the keychain channel simply did not exist.
///
/// The assert IS the log assertion from the issue's AC5: a missing Android
/// handler surfaces here as a thrown [MissingPluginException], failing the
/// probe, instead of silently spamming the run log.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('fah/background answers without MissingPluginException', (
    tester,
  ) async {
    // The refused contract: Android grants no extended background budget,
    // so begin() resolves to null there (iOS may grant a real id) — either
    // way it must RESOLVE, never throw MissingPluginException.
    final id = await BackgroundExecution.begin('issue-329-probe');
    expect(id, anyOf(isNull, isNonNegative));
    await BackgroundExecution.end(id);
    await BackgroundExecution.setScreenAwake(true);
    await BackgroundExecution.setScreenAwake(false);
  });

  testWidgets('fah/keychain round-trips without MissingPluginException', (
    tester,
  ) async {
    const store = KeychainStore();
    final available = await store.isAvailable();
    if (!available) return; // degraded Keystore: vacuously fine (E2)

    const probe = 'fah_keychain_probe';
    const secret = 'probe-secret-329';
    expect(await store.set(probe, secret), isTrue);
    final all = await store.readAll();
    expect(all[probe], secret);
    expect(await store.delete(probe), isTrue);
    expect((await store.readAll())[probe], isNull);
  });

  testWidgets('raw channel surfaces MissingPluginException if unhandled', (
    tester,
  ) async {
    // Belt and braces: a bare invoke against the background channel must
    // not fall through to the platform's missing-handler error.
    try {
      await const MethodChannel(
        'fah/background',
      ).invokeMethod<int>('begin', {'name': 'probe'});
    } on MissingPluginException catch (e) {
      fail('fah/background has no Android handler: $e');
    }
  });
}

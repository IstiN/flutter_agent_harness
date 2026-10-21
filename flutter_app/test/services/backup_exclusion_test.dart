// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';

import 'package:fa/services/backup_exclusion.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit coverage for the backup-exclusion channel wrapper (gh-1730 review:
/// the `~/.dap` hub tree must never ride the default iCloud backup).
///
/// The iOS branch proper (`Platform.isIOS` → `fah/icloud` excludeFromBackup)
/// cannot run on a desktop test host; it is covered end-to-end by the app
/// on-device. What IS pinnable here: the injection seam the env factory
/// test drives, and the non-iOS no-op never touching the channel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('fah/icloud');
  final invoked = <String>[];

  setUp(() {
    invoked.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          invoked.add(call.method);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    excludePathFromBackupOverride = null;
  });

  test('the override seam answers instead of the channel', () async {
    final seen = <String>[];
    excludePathFromBackupOverride = (path) async => seen.add(path);

    await excludePathFromBackup('/tmp/dap');

    expect(seen, ['/tmp/dap']);
    // The seam replaces the platform call entirely.
    expect(invoked, isEmpty);
  });

  test('a non-iOS host is a no-op: the channel is never touched', () async {
    // Deterministic on every test host (linux/mac/windows): none is iOS.
    if (Platform.isIOS) return;
    await excludePathFromBackup('/tmp/dap');
    expect(invoked, isEmpty);
  });
}

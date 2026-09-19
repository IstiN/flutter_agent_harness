// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// IT-layer contract for the mobile.* method channels (issue #622): the
/// REAL app-side services run against a scripted platform side that
/// emulates the god-flavor Android embedder (slice A's Kotlin answers:
/// `dev.fa1.app/mobile`, `mobile_launch`, `mobile_automation`,
/// `mobile_shell`). The argument shapes and result maps asserted here are
/// the same shapes the native side implements — if either side drifts,
/// this file and the Kotlin handlers disagree visibly.
@Tags(['integration'])
library;


import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fa/services/mobile/mobile_services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

const timeout = Timeout(Duration(minutes: 5));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const launchChannel = MethodChannel('dev.fa1.app/mobile_launch');
  const automationChannel = MethodChannel('dev.fa1.app/mobile_automation');
  const shellChannel = MethodChannel('dev.fa1.app/mobile_shell');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Every answered call, in order: `channel.method → arguments`.
  final calls = <String, List<Object?>>{};

  /// The scripted god-flavor platform side.
  Future<Object?>? godPlatform(String channel, MethodCall call) async {
    (calls['$channel.${call.method}'] ??= []).add(call.arguments);
    return switch (call.method) {
      'dumpHierarchy' => _hierarchyXml,
      'screenshot' => Uint8List.fromList([137, 80, 78, 71]),
      'tap' || 'swipe' || 'text' || 'launch' => null,
      'launcherApps' => [
          {'packageName': 'com.android.settings', 'label': 'Settings'},
        ],
      'allPackages' => [
          {'packageName': 'com.android.settings', 'label': 'Settings'},
          {'packageName': 'dev.fa1.app', 'label': 'Fa'},
        ],
      'isRunning' => false, // god build, Shizuku bridge not opted in yet
      'run' => {'exitCode': 0, 'stdout': 'uid=2000(shell)\n', 'stderr': ''},
      _ => null,
    };
  }

  setUp(() {
    calls.clear();
    resetMobileLogLines();
    for (final channel in [launchChannel, automationChannel, shellChannel]) {
      messenger.setMockMethodCallHandler(
          channel, (call) => godPlatform(channel.name, call));
    }
  });

  tearDown(() {
    for (final channel in [launchChannel, automationChannel, shellChannel]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('dumpHierarchy round-trips the raw XML the embedder answers',
      timeout: timeout, () async {
    final xml = await const MobileAutomationService().dumpHierarchy();
    expect(xml, _hierarchyXml);
    expect(calls.keys, contains('dev.fa1.app/mobile_automation.dumpHierarchy'));
  });

  test('screenshot carries the embedder bytes unchanged',
      timeout: timeout, () async {
    final shot = await const MobileAutomationService().screenshot();
    expect(shot.pngBytes, Uint8List.fromList([137, 80, 78, 71]));
  });

  test('tap arg shapes match the Kotlin contract', timeout: timeout,
      () async {
    final service = const MobileAutomationService();
    await service.tap(const MobileTapById('e12'));
    await service.tap(const MobileTapAtPoint(540, 1200));
    expect(calls['dev.fa1.app/mobile_automation.tap'], [
      {'elementId': 'e12'},
      {'x': 540, 'y': 1200},
    ]);
  });

  test('swipe passes points and the 300ms default duration',
      timeout: timeout, () async {
    await const MobileAutomationService().swipe(
      fromX: 100,
      fromY: 800,
      toX: 100,
      toY: 300,
    );
    expect(calls['dev.fa1.app/mobile_automation.swipe'], [
      {
        'fromX': 100,
        'fromY': 800,
        'toX': 100,
        'toY': 300,
        'durationMs': 300,
      }
    ]);
  });

  test('text passes element/text/clear with the clear=false default',
      timeout: timeout, () async {
    final service = const MobileAutomationService();
    await service.text(elementId: 'e3', text: 'hello');
    await service.text(text: 'focused field', clear: true);
    expect(calls['dev.fa1.app/mobile_automation.text'], [
      {'elementId': 'e3', 'text': 'hello', 'clear': false},
      {'text': 'focused field', 'clear': true},
    ]);
  });

  test('shell run maps the embedder result map; isRunning starts false',
      timeout: timeout, () async {
    final service = MobileShellService();
    await service.probe();
    expect(service.isRunning, isFalse);

    final result = await service.run('id', timeoutMs: 4000);
    expect(result.exitCode, 0);
    expect(result.stdout, 'uid=2000(shell)\n');
    expect(result.stderr, '');
    expect(calls['dev.fa1.app/mobile_shell.run'], [
      {'command': 'id', 'timeoutMs': 4000}
    ]);
    // A successful run proves the binder — the cached state flips.
    expect(service.isRunning, isTrue);
  });

  test('projection-reconsent surfaces as the named reconsent state',
      timeout: timeout, () async {
    messenger.setMockMethodCallHandler(automationChannel, (call) async {
      throw PlatformException(
        code: MobileErrorCode.projectionReconsent,
        message: 'consent token expired',
      );
    });
    await expectLater(
      const MobileAutomationService().screenshot(),
      throwsA(isA<MobileAutomationException>()
          .having((e) => e.code, 'code', MobileErrorCode.projectionReconsent)),
    );
  });

  test('launch and inventories keep the store/god shapes over one embedder',
      timeout: timeout, () async {
    final launch = const MobileLaunchService(queryAllPackages: true);
    await launch.launch(packageName: 'com.android.settings');
    expect(calls['dev.fa1.app/mobile_launch.launch'], [
      {'packageName': 'com.android.settings'}
    ]);

    final launcher = await launch.launcherApps();
    expect(launcher.single.packageName, 'com.android.settings');
    expect(launcher.single.label, 'Settings');

    final all = await launch.allPackages();
    expect(all, hasLength(2)); // god build answers the full inventory
    expect(all![1].packageName, 'dev.fa1.app');
  });

  test('the app log ring feeds mobile.logs through the wire hook',
      timeout: timeout, () async {
    addMobileLogLine('boot: flavor=god');
    addMobileLogLine('automation: accessibility on');
    expect(
      await const MobileLogService().recentLines(lines: 2),
      'boot: flavor=god\nautomation: accessibility on',
    );
  });
}

const _hierarchyXml =
    '<?xml version=\'1.0\' encoding=\'UTF-8\' standalone=\'yes\' ?>'
    '<hierarchy rotation="0"><node index="0" text="" class="android.widget.FrameLayout" '
    'bounds="[0,0][1080,2400]" /></hierarchy>';

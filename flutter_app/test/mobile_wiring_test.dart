// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Unit wiring for the app-side mobile.* services (issue #622): each
/// service must translate its `dev.fa1.app/mobile*` method channel exactly
/// as the Android embedder (slice A) implements it, and map channel
/// failures onto the core package's named exception states.
library;


import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fa/services/mobile/mobile_services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const launchChannel = MethodChannel('dev.fa1.app/mobile_launch');
  const automationChannel = MethodChannel('dev.fa1.app/mobile_automation');
  const shellChannel = MethodChannel('dev.fa1.app/mobile_shell');
  final messenger = TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger;

  Object? captured;

  void mock(MethodChannel channel, Future<Object?>? Function(MethodCall) handler) {
    messenger.setMockMethodCallHandler(channel, handler);
  }

  void mockError(MethodChannel channel, String code, [String? message]) =>
      mock(channel, (call) async => throw PlatformException(code: code, message: message));

  tearDown(() {
    for (final channel in [launchChannel, automationChannel, shellChannel]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    captured = null;
  });

  test('mobileFlavor defaults to the store flavor in tests', () {
    expect(mobileFlavor, 'store');
    expect(mobilePlatformSupported, isFalse); // test host is not Android
  });

  test('store flavor registers launch/logs only — no automation/shell backends', () {
    final names = mobileToolsForFlavor().map((tool) => tool.name).toList();
    expect(names, ['mobile.launch', 'mobile.logs']);
    expect(names, isNot(contains(mobileHierarchyToolName)));
    expect(names, isNot(contains(mobileShellToolName)));
  });

  test('god flavor wires all 8 mobile tools', () {
    final names = mobileToolsForFlavor(flavor: 'god').map((t) => t.name).toSet();
    expect(names, {
      mobileLaunchToolName,
      mobileHierarchyToolName,
      mobileTapToolName,
      mobileSwipeToolName,
      mobileTextToolName,
      mobileScreenshotToolName,
      mobileLogsToolName,
      mobileShellToolName,
    });
    expect(names.length, 8);
  });

  test('MobileLaunchService maps launcherApps rows to MobileAppEntry', () async {
    mock(launchChannel, (call) async {
      expect(call.method, 'launcherApps');
      return [
        {'packageName': 'com.example.app', 'label': 'Example'},
        {'packageName': 'com.bare'},
      ];
    });
    final apps = await const MobileLaunchService().launcherApps();
    expect(apps, hasLength(2));
    expect(apps[0].packageName, 'com.example.app');
    expect(apps[0].label, 'Example');
    expect(apps[1].packageName, 'com.bare');
    expect(apps[1].label, isNull);
  });

  test('store build answers allPackages null without touching the channel', () async {
    expect(await const MobileLaunchService().allPackages(), isNull);
    expect(
        await const MobileLaunchService(queryAllPackages: false).allPackages(),
        isNull);
  });

  test('launch passes packageName/deepLink args; notImplemented is a StateError', () async {
    mock(launchChannel, (call) async {
      captured = call.arguments;
      return null;
    });
    await const MobileLaunchService().launch(packageName: 'com.android.settings');
    expect(captured, {'packageName': 'com.android.settings'});

    captured = null;
    await const MobileLaunchService().launch(deepLink: 'fah://oauth/openrouter');
    expect(captured, {'deepLink': 'fah://oauth/openrouter'});
    // No handler: the messenger answers null ByteData — the framework's
    // notImplemented (MissingPluginException), not a null SUCCESS result.
    messenger.setMockMethodCallHandler(launchChannel, null);
    await expectLater(
      const MobileLaunchService().launch(packageName: 'com.x'),
      throwsStateError,
    );
  });

  test('tap maps by-element and by-point to the right channel args', () async {
    mock(automationChannel, (call) async {
      captured = call.arguments;
      return null;
    });
    final service = const MobileAutomationService();

    await service.tap(const MobileTapById('e7'));
    expect(captured, {'elementId': 'e7'});

    await service.tap(const MobileTapAtPoint(40, 90));
    expect(captured, {'x': 40, 'y': 90});
  });

  test('automation-offline PlatformException becomes the named exception', () async {
    mockError(automationChannel, 'automation-offline', 'service disabled');
    await expectLater(
      const MobileAutomationService().dumpHierarchy(),
      throwsA(isA<MobileAutomationException>()
          .having((e) => e.code, 'code', MobileErrorCode.automationOffline)
          .having((e) => e.message, 'message', 'service disabled')),
    );
  });

  test('missing embedder handler is the offline state', () async {
    // No automation handler registered: the embedder is absent here.
    await expectLater(
      const MobileAutomationService().dumpHierarchy(),
      throwsA(isA<MobileAutomationException>()
          .having((e) => e.code, 'code', MobileErrorCode.automationOffline)),
    );
  });

  test('screenshot wraps the channel bytes into a MobileScreenshot', () async {
    final png = Uint8List.fromList([1, 2, 3]);
    mock(automationChannel, (call) async {
      expect(call.method, 'screenshot');
      return png;
    });
    final shot = await const MobileAutomationService().screenshot();
    expect(shot.pngBytes, png);
  });

  test('shell isRunning answers false when the bridge is absent', () async {
    messenger.setMockMethodCallHandler(shellChannel, null); // no embedder
    final service = MobileShellService();
    await service.probe();
    expect(service.isRunning, isFalse);
  });

  test('shizuku-not-running maps to the named exception', () async {
    mock(shellChannel, (call) async {
      if (call.method == 'isRunning') return true;
      throw PlatformException(code: MobileErrorCode.shizukuNotRunning);
    });
    final service = MobileShellService();
    await service.probe();
    expect(service.isRunning, isTrue);
    await expectLater(
      service.run('id'),
      throwsA(isA<MobileAutomationException>()
          .having((e) => e.code, 'code', MobileErrorCode.shizukuNotRunning)),
    );
    // The failed run also drops the cached binder state.
    expect(service.isRunning, isFalse);
  });

  test('shell run maps the result map to MobileShellResult', () async {
    mock(shellChannel, (call) async {
      if (call.method != 'run') return true; // the constructor's isRunning probe
      captured = call.arguments;
      return {'exitCode': 0, 'stdout': 'uid=2000(shell)', 'stderr': ''};
    });
    final result = await MobileShellService().run('id', timeoutMs: 5000);
    expect(captured, {'command': 'id', 'timeoutMs': 5000});
    expect(result.exitCode, 0);
    expect(result.stdout, 'uid=2000(shell)');
    expect(result.stderr, '');
  });

  test('log ring keeps the 200-line tail; recentLines reads it oldest-first', () async {
    resetMobileLogLines();
    for (var i = 0; i < 205; i++) {
      addMobileLogLine('l$i');
    }
    final text = await const MobileLogService().recentLines(lines: 3);
    expect(text, 'l202\nl203\nl204');
  });
}

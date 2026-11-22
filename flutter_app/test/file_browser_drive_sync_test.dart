import 'package:fa/services/cloud/drive_sync_controller.dart';
import 'package:fa/ui/widgets/file_browser.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'drive_sync_test_helper.dart';

void main() {
  Future<void> pump(
    WidgetTester tester,
    ExecutionEnv env, [
    DriveSyncController? controller,
  ]) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFaTheme(
          direction: FaVisualDirection.glass,
          brightness: Brightness.dark,
        ),
        home: Scaffold(
          body: FileBrowser(env: env, driveSyncController: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('stock Files has no cloud action, status row or provider', (
    tester,
  ) async {
    await pump(tester, MemoryExecutionEnv());
    expect(find.byKey(const ValueKey('fileBrowserDriveSync')), findsNothing);
    expect(
      find.byKey(const ValueKey('fileBrowserDriveSyncStatus')),
      findsNothing,
    );
  });

  testWidgets('injected controller exposes syncing state and pending count', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final controller = await makeDriveStatusController(
      env: env,
      status: DriveSyncStatus.syncing,
    );
    await pump(tester, env, controller);
    expect(
      find.byKey(const ValueKey('fileBrowserDriveSyncStatus')),
      findsOneWidget,
    );
    expect(find.text('Syncing'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('fileBrowserDrivePending')),
      findsOneWidget,
    );
    expect(find.text('1'), findsOneWidget);
  });

  testWidgets('quota and inactive-plan states remain explicit in Files', (
    tester,
  ) async {
    for (final (status, label) in [
      (DriveSyncStatus.quotaExceeded, 'Drive quota exceeded'),
      (DriveSyncStatus.planInactive, 'Drive plan inactive'),
      (DriveSyncStatus.providerReauthRequired, 'Drive sign-in required'),
    ]) {
      final env = MemoryExecutionEnv();
      final controller = await makeDriveStatusController(
        env: env,
        status: status,
      );
      await pump(tester, env, controller);
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('conflict action offers explicit keep-local/use-remote choices', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final controller = await makeDriveStatusController(
      env: env,
      status: DriveSyncStatus.conflict,
    );
    await pump(tester, env, controller);
    expect(find.text('Conflict — choose a version'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('driveConflictUseRemote')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('driveConflictKeepLocal')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('driveConflictKeepLocal')));
    await tester.pumpAndSettle();
    // No-op provider throws instead of silently claiming a successful upload.
    expect(controller.lastError, isNotNull);
  });
}

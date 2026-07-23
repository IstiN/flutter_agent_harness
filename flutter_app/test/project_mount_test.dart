import 'package:fa/file_browser.dart';
import 'package:fa/project_folder_channel.dart';
import 'package:fa/project_mount_env.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Scripted [ProjectFolderOps] for the open-folder flow tests.
final class _FakeFolderOps implements ProjectFolderOps {
  _FakeFolderOps({this.pickResult});

  ({String path, String bookmark})? pickResult;
  final stopped = <String>[];

  @override
  Future<({String path, String bookmark})?> pickDirectory() async => pickResult;

  @override
  Future<bool> startAccessing(String bookmark) async => true;

  @override
  Future<void> stopAccessing(String bookmark) async => stopped.add(bookmark);
}

Future<ProjectMountEnv> _envWithHost() async {
  final base = MemoryExecutionEnv();
  await base.createDir('host/repo');
  await base.writeFile('host/repo/a.txt', 'in the project');
  return ProjectMountEnv(base);
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('open-folder button mounts and lists the project', (
    tester,
  ) async {
    final env = await _envWithHost();
    final ops = _FakeFolderOps(
      pickResult: (path: '/host/repo', bookmark: 'Ym9va21hcms='),
    );
    await tester.pumpWidget(
      _wrap(FileBrowser(env: env, projectFolderOps: ops)),
    );
    await tester.pumpAndSettle();

    // Not mounted yet: the open-folder button is there, listing is container.
    expect(find.byIcon(Icons.create_new_folder_outlined), findsOneWidget);
    expect(find.text('a.txt'), findsNothing);

    await tester.tap(find.byIcon(Icons.create_new_folder_outlined));
    await tester.pumpAndSettle();

    expect(env.mountedRoot, '/host/repo');
    expect(
      find.byIcon(Icons.eject_outlined),
      findsOneWidget,
      reason: 'mounted state shows the eject chip',
    );
  });

  testWidgets('eject unmounts and stops the scoped access', (tester) async {
    final env = await _envWithHost();
    final ops = _FakeFolderOps(
      pickResult: (path: '/host/repo', bookmark: 'Ym9va21hcms='),
    );
    await tester.pumpWidget(
      _wrap(FileBrowser(env: env, projectFolderOps: ops)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.create_new_folder_outlined));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.eject_outlined));
    await tester.pumpAndSettle();

    expect(env.mountedRoot, isNull);
    expect(ops.stopped, ['Ym9va21hcms=']);
    expect(find.byIcon(Icons.create_new_folder_outlined), findsOneWidget);
  });

  testWidgets('a stale stored mount shows the warning chip', (tester) async {
    final env = await _envWithHost()
      ..mountUnavailable = '/host/gone';
    await tester.pumpWidget(
      _wrap(FileBrowser(env: env, projectFolderOps: _FakeFolderOps())),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget);
    expect(find.byIcon(Icons.create_new_folder_outlined), findsNothing);
  });

  testWidgets('no mount env means no control at all', (tester) async {
    await tester.pumpWidget(_wrap(FileBrowser(env: MemoryExecutionEnv())));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.create_new_folder_outlined), findsNothing);
    expect(find.byIcon(Icons.eject_outlined), findsNothing);
    expect(find.byIcon(Icons.warning_amber_outlined), findsNothing);
  });
}

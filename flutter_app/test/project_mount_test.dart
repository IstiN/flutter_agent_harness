import 'dart:io';

import 'package:fa/ui/widgets/file_browser.dart';
import 'package:fa/services/project_folder_channel.dart';
import 'package:fa/services/project_mount_env.dart';
import 'package:fa/services/project_mount_flow.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
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
  group('visibleFolderRoot — the Files initialPath visibility seam (P1)', () {
    test('session folder == the mounted root passes through', () {
      final base = LocalExecutionEnv(cwd: '/app/support');
      final env = ProjectMountEnv(base)..mountedRoot = '/Users/x/project';
      expect(visibleFolderRoot(env, '/Users/x/project'), '/Users/x/project');
    });

    test(
      'an unrelated host path (the macOS sandbox cannot see it) is null',
      () {
        // The regression: currentSessionCwd passed raw — Files tried to
        // list a host path outside the granted mount and painted "could
        // not open folder". Null keeps the env cwd instead (for a mounted
        // session that already is the session's folder via /project).
        final base = LocalExecutionEnv(cwd: '/app/support');
        final env = ProjectMountEnv(base)..mountedRoot = '/Users/x/project';
        expect(visibleFolderRoot(env, '/Users/Uladzimir/git/support'), isNull);
      },
    );

    test(
      'session folder == the env cwd (unmounted desktop) passes through',
      () {
        final env = LocalExecutionEnv(cwd: '/app/support');
        expect(visibleFolderRoot(env, '/app/support'), '/app/support');
      },
    );

    test('a relocated sandbox folder (stale container prefix) resolves to '
        'the live root', () {
      // iOS reinstall/backup-restore re-seats the app container UUID: a
      // restored session records the OLD prefix while the env root
      // carries the NEW one. The folder is still the sandbox the env
      // opens, and the returned root must be the LIVE one — the stale
      // prefix would resolve nowhere on the listing.
      final env = LocalExecutionEnv(
        cwd:
            '/var/mobile/Containers/Data/Application/9F2E-live/Documents/'
            'fah_sandbox',
      );
      const stale =
          '/var/mobile/Containers/Data/Application/4A7D-old/Documents/'
          'fah_sandbox';
      expect(visibleFolderRoot(env, stale), env.cwd);
    });

    test('a same-name folder under a DIFFERENT parent never matches', () {
      // The tail identity needs the folder AND its parent to agree — a
      // shared folder name alone must not claim visibility.
      final env = LocalExecutionEnv(cwd: '/app/support');
      expect(visibleFolderRoot(env, '/elsewhere/support'), isNull);
    });

    test('single-segment roots never tail-match', () {
      final env = LocalExecutionEnv(cwd: '/sandbox');
      expect(visibleFolderRoot(env, '/other/sandbox'), isNull);
    });

    test('trailing slashes do not hide visibility', () {
      final base = LocalExecutionEnv(cwd: '/app/support');
      final env = ProjectMountEnv(base)..mountedRoot = '/Users/x/project/';
      expect(visibleFolderRoot(env, '/Users/x/project'), '/Users/x/project');
      expect(
        visibleFolderRoot(env, '/Users/x/project///'),
        '/Users/x/project///'.replaceAll(RegExp(r'/+$'), ''),
      );
    });

    test('null/empty candidates stay null', () {
      final env = ProjectMountEnv(LocalExecutionEnv(cwd: '/app'))
        ..mountedRoot = '/Users/x/project';
      expect(visibleFolderRoot(env, null), isNull);
      expect(visibleFolderRoot(env, ''), isNull);
      expect(visibleFolderRoot(env, '   '), isNull);
    });

    test(
      'the visible root is returned for the env the listing will use',
      () async {
        // End-to-end shape: what the seam returns must be a path the env's
        // listing can actually open — mounted root lists through the mount
        // pass-through, the env cwd always lists.
        final dir = await Directory.systemTemp.createTemp('visible_root');
        addTearDown(() => dir.delete(recursive: true));
        await File('${dir.path}/in_project.txt').writeAsString('x');
        final base = LocalExecutionEnv(cwd: dir.path);
        final env = ProjectMountEnv(base)..mountedRoot = dir.path;
        final root = visibleFolderRoot(env, dir.path);
        expect(root, dir.path);
        expect((await env.listDir(root!)).isOk, isTrue);
      },
    );
  });

  group('ProjectFolderChannelOps', () {
    test('pickResult maps a complete payload to the record', () {
      expect(
        ProjectFolderChannelOps.pickResult(const {
          'path': '/host/repo',
          'bookmark': 'Ym9va21hcms=',
        }),
        (path: '/host/repo', bookmark: 'Ym9va21hcms='),
      );
    });

    test('null payloads and incomplete records count as cancel', () {
      expect(ProjectFolderChannelOps.pickResult(null), isNull);
      expect(ProjectFolderChannelOps.pickResult(const {}), isNull);
      expect(ProjectFolderChannelOps.pickResult(const {'path': '/x'}), isNull);
      expect(
        ProjectFolderChannelOps.pickResult(const {'bookmark': 'bm='}),
        isNull,
      );
    });

    test('pickDirectory is a no-op off macOS', () async {
      // The unit-test host has no native handler: unsupported platforms
      // resolve to null without touching the channel.
      if (ProjectFolderChannelOps.isSupported) return;
      const ops = ProjectFolderChannelOps();
      expect(await ops.pickDirectory(), isNull);
      expect(await ops.startAccessing('bm='), isFalse);
    });
  });

  testWidgets('open-folder button mounts and lists the project', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 700);
    addTearDown(tester.view.reset);
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
    expect(
      find.byKey(const ValueKey('fileBrowserMountIdentity')),
      findsOneWidget,
    );
    expect(find.text('repo'), findsOneWidget);
    final title = tester.widget<Text>(
      find.descendant(
        of: find.byKey(const ValueKey('fileBrowserHeader')),
        matching: find.text('Files'),
      ),
    );
    expect(title.maxLines, 1);
    expect(title.overflow, TextOverflow.ellipsis);
    expect(tester.takeException(), isNull);
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

  group('folderPathsTailMatch — platform fold seam (review blockers, PR #2112)', () {
    test('web fold is case-sensitive (URL semantics, same as Linux)', () {
      // The web build cannot touch dart:io's Platform at all — the seam
      // takes the resolved bool so this branch is exercisable on the VM.
      expect(
        folderPathsTailMatch('/a/b/Demo', '/x/b/Demo', caseSensitive: true),
        isTrue,
      );
      expect(
        folderPathsTailMatch('/a/b/Demo', '/x/b/demo', caseSensitive: true),
        isFalse,
      );
    });

    test('case-insensitive platforms fold the trailing two segments', () {
      expect(
        folderPathsTailMatch('/a/b/Demo', '/x/b/demo', caseSensitive: false),
        isTrue,
      );
    });

    test('single-segment paths never tail-match on any platform', () {
      expect(
        folderPathsTailMatch('/Demo', '/x/Demo', caseSensitive: true),
        isFalse,
      );
      expect(
        folderPathsTailMatch('/Demo', '/x/demo', caseSensitive: false),
        isFalse,
      );
    });
  });
}

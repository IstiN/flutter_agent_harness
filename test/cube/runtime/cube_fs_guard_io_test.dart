/// REG for #791 (SEC-03): the cube fs guard must resolve REAL filesystem
/// symlinks — a link inside the workspace may not smuggle reads/writes to a
/// target outside it, while legitimate in-workspace links keep working.
///
/// Runs against `LocalFileSystem` + `LocalCubeFsProbe` over `Directory
/// .systemTemp` links created with `Link.createSync`. Skipped on platforms
/// without unprivileged symlink support (Windows).
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

CubeSpec spec(String workspace) => CubeSpec(
  name: 'reg-791',
  filesystem: CubeFsPolicy(workspace: workspace),
);

void main() {
  // Creating symlinks on Windows needs privileges; every case below is a
  // POSIX link(2), so skip the whole suite there (fail-open the skip, the
  // fake-probe UTs in cube_fs_guard_test.dart still cover the logic).
  final skip = Platform.isWindows ? 'POSIX symlinks unavailable' : null;

  group('CubeFsGuard resolves real symlinks (REG #791)', () {
    late Directory root;
    late Directory ws;
    late LocalFileSystem fs;
    late CubeFsGuard guard;

    setUp(() {
      root = Directory.systemTemp.createTempSync('fa_cube_791_');
      ws = Directory('${root.path}/ws')..createSync();
      fs = LocalFileSystem(cwd: ws.path);
      guard = CubeFsGuard(
        fs,
        spec(ws.path),
        workspaceRoot: ws.path,
        pathProbe: const LocalCubeFsProbe(),
      );
    });

    tearDown(() {
      root.deleteSync(recursive: true);
    });

    test('AC1: link to outside denies read AND write; allowed path works', () async {
      final outside = Directory('${root.path}/outside')..createSync();
      File('${outside.path}/id_rsa').writeAsStringSync('secret');
      Link('${ws.path}/link').createSync(outside.path);

      final read = await guard.readTextFile('link/id_rsa');
      expect(read.isErr, isTrue, reason: 'read through the link must vanish');
      expect(read.errorOrNull!.code, FileErrorCode.notFound);

      final write = await guard.writeFile('link/evil', 'x');
      expect(write.isErr, isTrue, reason: 'write through the link must fail');
      expect(write.errorOrNull!.code, FileErrorCode.permissionDenied);
      expect(File('${outside.path}/evil').existsSync(), isFalse,
          reason: 'nothing may land outside');

      // No over-block: normal workspace files still read and write.
      expect((await guard.writeFile('real.txt', 'fine')).isOk, isTrue);
      expect((await guard.readTextFile('real.txt')).getOrThrow(), 'fine');
      // ...and the protected file is reachable through its allowed spelling.
      expect(
        await guard.readTextFile('${outside.path}/id_rsa'),
        isA<Err<String, FileError>>(),
      );
    });

    test('AC1: relative link escaping the workspace is denied too', () async {
      final outside = Directory('${root.path}/outside')..createSync();
      Link('${ws.path}/rel').createSync('../outside');
      expect(
        (await guard.writeFile('rel/evil', 'x')).errorOrNull!.code,
        FileErrorCode.permissionDenied,
      );
      expect(File('${outside.path}/evil').existsSync(), isFalse);
    });

    test('AC2: chains denied; in-workspace link allowed', () async {
      final outside = Directory('${root.path}/outside')..createSync();
      Directory('${ws.path}/sub').createSync();
      Link('${ws.path}/a').createSync('b');
      Link('${ws.path}/b').createSync(outside.path);
      expect(
        (await guard.readTextFile('a/key')).errorOrNull!.code,
        FileErrorCode.notFound,
      );

      // The legitimate use keeps working: link to a workspace sibling.
      Link('${ws.path}/alias').createSync('sub');
      expect((await guard.writeFile('alias/f.txt', 'chained')).isOk, isTrue);
      expect(File('${ws.path}/sub/f.txt').readAsStringSync(), 'chained');
    });

    test('AC3: .. traversal after resolution is denied', () async {
      Directory('${ws.path}/sub/deep').createSync(recursive: true);
      Link('${ws.path}/l').createSync('sub/deep');
      // Resolves to ws/sub/deep, then climbs out of the workspace.
      final result = await guard.writeFile('l/../../../escape', 'x');
      expect(result.isErr, isTrue);
      expect(
        File('${root.path}/escape').existsSync(),
        isFalse,
        reason: 'the .. applies to the resolved dir, not the written one',
      );
    });

    test('AC3: .. from a link target lands where the kernel would', () async {
      final outside = Directory('${root.path}/outside')..createSync();
      Link('${ws.path}/alt').createSync(outside.path);
      // ws/alt/../sibling = root/outside/sibling — still outside.
      final result = await guard.writeFile('alt/../sibling', 'x');
      expect(result.isErr, isTrue);
      expect(File('${root.path}/sibling').existsSync(), isFalse);
    });

    test('exists reports false for outside targets behind links', () async {
      final outside = Directory('${root.path}/outside')..createSync();
      File('${outside.path}/f').writeAsStringSync('x');
      Link('${ws.path}/link').createSync(outside.path);
      expect((await guard.exists('link/f')).getOrThrow(), isFalse);
      expect((await guard.exists('real.txt')).getOrThrow(), isFalse);
      expect((await guard.writeFile('real.txt', 'x')).isOk, isTrue);
      expect((await guard.exists('real.txt')).getOrThrow(), isTrue);
    });
  }, skip: skip);
}

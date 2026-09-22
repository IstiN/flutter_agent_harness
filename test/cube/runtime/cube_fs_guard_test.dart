import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../fake_fs_probe.dart';

CubeSpec spec({
  String workspace = '/workspace',
  List<CubeMount> mounts = const [],
}) => CubeSpec(
  name: 'test-cube',
  filesystem: CubeFsPolicy(workspace: workspace, mounts: mounts),
);

void main() {
  group('CubeFsGuard', () {
    test('writes under the workspace root succeed', () async {
      final delegate = MemoryExecutionEnv(cwd: '/work');
      final guard = CubeFsGuard(delegate, spec(), workspaceRoot: '/work');
      final result = await guard.writeFile('dir/file.txt', 'hello');
      expect(result.isOk, isTrue);
      expect(
        (await delegate.readTextFile('/work/dir/file.txt')).getOrThrow(),
        'hello',
      );
    });

    test('writes to a read-only path are permissionDenied', () async {
      final delegate = MemoryExecutionEnv(cwd: '/work');
      final guard = CubeFsGuard(
        delegate,
        spec(
          workspace: '/work',
          mounts: [
            CubeMount(path: '/work/vendor', access: CubePathAccess.readOnly),
          ],
        ),
      );
      final result = await guard.writeFile('/work/vendor/pkg.dart', 'x');
      expect(result.isErr, isTrue);
      final error = result.errorOrNull!;
      expect(error.code, FileErrorCode.permissionDenied);
      expect(error.message, contains('fa_cube[test-cube]:'));
      expect(error.message, contains('read-only'));
    });

    test('reads of a denied path vanish as notFound', () async {
      final delegate = MemoryExecutionEnv(cwd: '/work');
      await delegate.writeFile('/work/secret.txt', 's');
      final guard = CubeFsGuard(
        delegate,
        spec(
          workspace: '/work',
          mounts: [
            CubeMount(path: '/work/secret.txt', access: CubePathAccess.deny),
          ],
        ),
      );
      final result = await guard.readTextFile('/work/secret.txt');
      expect(result.isErr, isTrue);
      expect(result.errorOrNull!.code, FileErrorCode.notFound);
      expect(
        result.errorOrNull!.message,
        contains('does not exist in this cube'),
      );
    });

    test('exists on a denied path reports false', () async {
      final delegate = MemoryExecutionEnv(cwd: '/work');
      await delegate.writeFile('/work/secret.txt', 's');
      final guard = CubeFsGuard(
        delegate,
        spec(
          workspace: '/work',
          mounts: [
            CubeMount(path: '/work/secret.txt', access: CubePathAccess.deny),
          ],
        ),
      );
      expect((await guard.exists('/work/secret.txt')).getOrThrow(), isFalse);
      expect((await guard.exists('/work/other.txt')).getOrThrow(), isFalse);
      await delegate.writeFile('/work/other.txt', 'o');
      expect((await guard.exists('/work/other.txt')).getOrThrow(), isTrue);
    });

    test('denied directories are not listable or statable', () async {
      final delegate = MemoryExecutionEnv(cwd: '/work');
      await delegate.writeFile('/work/private/a.txt', 'x');
      final guard = CubeFsGuard(
        delegate,
        spec(
          workspace: '/work',
          mounts: [
            CubeMount(path: '/work/private', access: CubePathAccess.deny),
          ],
        ),
      );
      expect(
        (await guard.listDir('/work/private')).errorOrNull!.code,
        FileErrorCode.notFound,
      );
      expect(
        (await guard.fileInfo('/work/private/a.txt')).errorOrNull!.code,
        FileErrorCode.notFound,
      );
    });

    test('.. traversal resolves and is then denied', () async {
      final delegate = MemoryExecutionEnv(cwd: '/work');
      final guard = CubeFsGuard(delegate, spec(workspace: '/work'));
      final result = await guard.writeFile('../escape.txt', 'x');
      expect(result.isErr, isTrue);
      expect(result.errorOrNull!.code, FileErrorCode.permissionDenied);
      expect((await delegate.exists('/escape.txt')).getOrThrow(), isFalse);
    });

    test('workspaceRoot override maps the delegate cwd', () async {
      final delegate = MemoryExecutionEnv(cwd: '/real/cwd');
      // Without the override the spec workspace does not match the cwd.
      final strict = CubeFsGuard(delegate, spec());
      expect(
        (await strict.writeFile('file.txt', 'x')).errorOrNull!.code,
        FileErrorCode.permissionDenied,
      );
      // With the override the cwd becomes the writable root.
      final guard = CubeFsGuard(delegate, spec(), workspaceRoot: '/real/cwd');
      expect((await guard.writeFile('file.txt', 'x')).isOk, isTrue);
    });

    test('absolutePath and joinPath forward untouched', () async {
      final delegate = MemoryExecutionEnv(cwd: '/work');
      final guard = CubeFsGuard(delegate, spec());
      expect(
        (await guard.absolutePath('a.txt')).getOrThrow(),
        (await delegate.absolutePath('a.txt')).getOrThrow(),
      );
      expect(
        (await guard.joinPath(['a', 'b'])).getOrThrow(),
        (await delegate.joinPath(['a', 'b'])).getOrThrow(),
      );
    });

    test('cwd forwards to the delegate', () {
      final guard = CubeFsGuard(MemoryExecutionEnv(cwd: '/work'), spec());
      expect(guard.cwd, '/work');
    });

    test('append and createDir and remove honor the policy', () async {
      final delegate = MemoryExecutionEnv(cwd: '/work');
      final guard = CubeFsGuard(
        delegate,
        spec(
          workspace: '/work',
          mounts: [
            CubeMount(path: '/work/ro', access: CubePathAccess.readOnly),
          ],
        ),
      );
      expect(
        (await guard.appendFile('/work/ro/f.txt', 'x')).errorOrNull!.code,
        FileErrorCode.permissionDenied,
      );
      expect(
        (await guard.createDir('/work/ro/d')).errorOrNull!.code,
        FileErrorCode.permissionDenied,
      );
      expect(
        (await guard.remove('/work/ro/f.txt')).errorOrNull!.code,
        FileErrorCode.permissionDenied,
      );
      expect((await guard.createDir('/work/rw/d')).isOk, isTrue);
    });
  });

  group('CubeFsGuard symlink resolution (#791)', () {
    // Fake probe standing in for the real filesystem: [links] maps paths to
    // their symlink targets. The MemoryExecutionEnv delegate holds real
    // (virtual) files, so "the same file via an allowed path still works"
    // is provable end to end.
    late FakeFsProbe probe;
    late MemoryExecutionEnv delegate;
    late CubeFsGuard guard;

    setUp(() {
      probe = FakeFsProbe();
      delegate = MemoryExecutionEnv(cwd: '/work');
      guard = CubeFsGuard(
        delegate,
        spec(workspace: '/work'),
        workspaceRoot: '/work',
        pathProbe: probe,
      );
    });

    test('AC1: read AND write through a link outside are denied, named', () async {
      probe.links['/work/link'] = '/outside';
      await delegate.createDir('/outside');

      final read = await guard.readTextFile('/work/link/id_rsa');
      expect(read.isErr, isTrue);
      expect(read.errorOrNull!.code, FileErrorCode.notFound);
      expect(read.errorOrNull!.message, contains('fa_cube[test-cube]'));

      final write = await guard.writeFile('/work/link/evil', 'x');
      expect(write.isErr, isTrue);
      expect(write.errorOrNull!.code, FileErrorCode.permissionDenied);
      expect(write.errorOrNull!.message, contains('fa_cube[test-cube]'));
      expect((await delegate.exists('/outside/evil')).getOrThrow(), isFalse);

      // No over-block: the same file via its allowed path still works.
      await delegate.writeFile('/outside/id_rsa', 'secret');
      final direct = await guard.writeFile('/work/mine.txt', 'fine');
      expect(direct.isOk, isTrue);
      expect((await guard.readTextFile('/work/mine.txt')).getOrThrow(), 'fine');
    });

    test('AC2: symlink chains are denied, in-workspace chains allowed', () async {
      probe.links.addAll({
        '/work/a': 'b',
        '/work/b': '/outside',
      });
      expect(
        (await guard.readTextFile('/work/a/key')).errorOrNull!.code,
        FileErrorCode.notFound,
      );

      probe.links.clear();
      probe.links.addAll({'/work/a': 'b', '/work/b': 'sub'});
      final write = await guard.writeFile('/work/a/f.txt', 'chained');
      expect(write.isOk, isTrue);
      // The open path is the resolved target, not the written form.
      expect((await delegate.readTextFile('/work/sub/f.txt')).getOrThrow(),
          'chained');
    });

    test('AC3: .. traversal after resolution is denied', () async {
      probe.links['/work/l'] = 'sub/deep';
      final result = await guard.writeFile('/work/l/../../../etc/passwd', 'x');
      expect(result.isErr, isTrue);
      expect(result.errorOrNull!.code, FileErrorCode.permissionDenied);
      expect((await delegate.exists('/etc/passwd')).getOrThrow(), isFalse);
    });

    test('unreadable indirection fails closed', () async {
      probe.unreadable.add('/work/junction');
      expect(
        (await guard.writeFile('/work/junction/f', 'x')).errorOrNull!.code,
        FileErrorCode.permissionDenied,
      );
      expect(
        (await guard.readTextFile('/work/junction/f')).errorOrNull!.code,
        FileErrorCode.notFound,
      );
    });

    test('without a probe the guard keeps the lexical check', () async {
      final lexical = CubeFsGuard(delegate, spec(workspace: '/work'));
      expect(
        (await lexical.writeFile('/work/../escape', 'x')).isErr,
        isTrue,
      );
      expect((await lexical.writeFile('/work/ok', 'x')).isOk, isTrue);
    });
  });
}

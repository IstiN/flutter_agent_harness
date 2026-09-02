import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

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
}

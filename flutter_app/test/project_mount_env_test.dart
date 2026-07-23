import 'package:fa/project_mount_env.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<ProjectMountEnv> envWithHost() async {
    final base = MemoryExecutionEnv();
    await base.writeFile('app/settings.json', '{}');
    await base.createDir('host/repo');
    await base.writeFile('host/repo/a.txt', 'in the project');
    await base.createDir('host/repo/src');
    await base.writeFile('host/repo/src/b.txt', 'nested');
    return ProjectMountEnv(base);
  }

  test('without a mount every path passes through to the delegate', () async {
    final env = await envWithHost();
    expect(env.mountedRoot, isNull);
    expect((await env.readTextFile('app/settings.json')).valueOrNull, '{}');
    expect((await env.exists(projectMountSegment)).valueOrNull, isFalse);
  });

  test('the mount segment maps onto the host directory', () async {
    final env = await envWithHost()
      ..mountedRoot = '/host/repo';
    expect(env.mountedRoot, '/host/repo');

    expect(
      (await env.readTextFile('$projectMountSegment/a.txt')).valueOrNull,
      'in the project',
    );
    expect(
      (await env.readTextFile('$projectMountSegment/src/b.txt')).valueOrNull,
      'nested',
    );
    final listing = (await env.listDir(projectMountSegment)).valueOrNull!;
    expect(listing.map((e) => e.name), containsAll(<String>['a.txt', 'src']));

    // Writes land in the host directory, not the container root.
    await env.writeFile('$projectMountSegment/new.txt', 'created');
    final base = env;
    expect(
      (await base.readTextFile('$projectMountSegment/new.txt')).valueOrNull,
      'created',
    );
  });

  test('unrelated paths never remap into the mount', () async {
    final env = await envWithHost()
      ..mountedRoot = '/host/repo';
    expect((await env.readTextFile('app/settings.json')).valueOrNull, '{}');
    // '/projectile' is not the mount segment.
    expect((await env.exists('/projectile')).valueOrNull, isFalse);
  });

  test('host paths under the mounted root pass through unchanged', () async {
    final env = await envWithHost()
      ..mountedRoot = '/host/repo';
    // absolutePath resolves as the delegate sees fit; mapped input stays
    // valid input afterwards.
    final absolute = (await env.absolutePath(projectMountSegment)).valueOrNull;
    expect(absolute, isNotNull);
    expect((await env.exists(absolute!)).valueOrNull, isTrue);
  });

  test('unmounting hides the segment again', () async {
    final env = await envWithHost()
      ..mountedRoot = '/host/repo'
      ..mountedRoot = null;
    expect(env.mountedRoot, isNull);
    expect((await env.exists(projectMountSegment)).valueOrNull, isFalse);
  });
}

import 'package:fa/project_mount_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('missing or corrupt files read as no mount', () async {
    final env = MemoryExecutionEnv();
    expect(await ProjectMountStore.load(env), isNull);

    await env.writeFile('project_mount.json', 'not json at all');
    expect(await ProjectMountStore.load(env), isNull);

    await env.writeFile('project_mount.json', '{"path": ""}');
    expect(await ProjectMountStore.load(env), isNull);
  });

  test('save/load/clear round-trip', () async {
    final env = MemoryExecutionEnv();
    await ProjectMountStore.save(
      env,
      path: '/Users/me/repo',
      bookmark: 'Ym9va21hcms=',
    );

    final stored = await ProjectMountStore.load(env);
    expect(stored, isNotNull);
    expect(stored!.path, '/Users/me/repo');
    expect(stored.bookmark, 'Ym9va21hcms=');

    // Saving again replaces the previous mount.
    await ProjectMountStore.save(
      env,
      path: '/Users/me/other',
      bookmark: 'b3RoZXI=',
    );
    final replaced = await ProjectMountStore.load(env);
    expect(replaced!.path, '/Users/me/other');

    await ProjectMountStore.clear(env);
    expect(await ProjectMountStore.load(env), isNull);
  });
}

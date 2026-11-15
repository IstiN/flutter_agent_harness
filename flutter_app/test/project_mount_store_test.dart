import 'package:fa/services/project_mount_store.dart';
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

  test('empty bookmark round-trips (Windows/Linux selectors)', () async {
    // The Windows/Linux file selectors persist no security-scoped
    // bookmark — the store record carries `bookmark: ""` and must still
    // restore the mount (the scoped-folder toggle rides the same load).
    final env = MemoryExecutionEnv();
    await ProjectMountStore.save(env, path: r'C:\Users\me\repo', bookmark: '');

    final stored = await ProjectMountStore.load(env);
    expect(stored, isNotNull);
    expect(stored!.path, r'C:\Users\me\repo');
    expect(stored.bookmark, isEmpty);

    // The scoped flag survives the same restore path.
    await ProjectMountStore.save(
      env,
      path: r'C:\Users\me\repo',
      bookmark: '',
      scoped: true,
    );
    final scoped = await ProjectMountStore.load(env);
    expect(scoped!.bookmark, isEmpty);
    expect(scoped.scoped, isTrue);
  });
}

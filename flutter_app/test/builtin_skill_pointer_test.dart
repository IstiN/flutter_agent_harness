// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// gh-1393 AC7: built-in skills must be discoverable on mobile hosts even
// though their SKILL.md lives in compiled-in memory (`builtin://skills/...`,
// served by the read tool). `.fah/skills/<name>/` gets a pointer file —
// only when the directory is empty or missing, never next to a real copy.

import 'package:fa/sandbox/memory_shell.dart';
import 'package:fa/services/agent_service.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late MemoryShell shell;
  late MemoryExecutionEnv env;

  setUp(() {
    shell = MemoryShell();
    env = MemoryExecutionEnv(cwd: '/', shell: shell);
    shell.attach(env);
  });

  test(
    'every builtin skill gets a pointer file in a fresh workspace',
    () async {
      await seedBuiltinSkillPointers(env);

      for (final skill in builtinSkills()) {
        final path = '/.fah/skills/${skill.name}/SKILL.md.pointer';
        final body = await env.readTextFile(path);
        expect(
          body.valueOrNull,
          'builtin://skills/${skill.name}/SKILL.md\n',
          reason: 'missing pointer at $path',
        );
      }
    },
  );

  test('a directory holding a real skill is never touched', () async {
    await env.createDir('/.fah/skills/create-goal');
    await env.writeFile(
      '/.fah/skills/create-goal/SKILL.md',
      '---\nname: create-goal\ndescription: local override\n---\nreal',
    );

    await seedBuiltinSkillPointers(env);

    expect(
      (await env.listDir('/.fah/skills/create-goal')).valueOrNull!.single.name,
      'SKILL.md',
    );
  });

  test('an empty leftover directory is filled with the pointer', () async {
    await env.createDir('/.fah/skills/js-apps');

    await seedBuiltinSkillPointers(env);

    expect(
      (await env.readTextFile(
        '/.fah/skills/js-apps/SKILL.md.pointer',
      )).valueOrNull,
      'builtin://skills/js-apps/SKILL.md\n',
    );
  });

  test('readCommandInput follows the pointer for cat/head/grep (gh-1444 '
      'AC1)', () async {
    await seedBuiltinSkillPointers(env);
    final body = builtinSkillTextAt('builtin://skills/js-apps/SKILL.md')!;

    final cat = await shell.exec('cat .fah/skills/js-apps/SKILL.md');
    expect(cat.valueOrNull!.exitCode, 0);
    expect(cat.valueOrNull!.stdout, body);

    final head = await shell.exec('head -n 1 .fah/skills/js-apps/SKILL.md');
    expect(head.valueOrNull!.stdout, '${body.split('\n').first}\n');

    // The direct builtin:// URI is equivalent for reads (C1).
    final direct = await shell.exec('cat builtin://skills/js-apps/SKILL.md');
    expect(direct.valueOrNull!.exitCode, 0);
    expect(direct.valueOrNull!.stdout, body);
  });

  test('a foreign pointer target is refused loudly, never silent (E1)',
      () async {
    await env.createDir('/.fah/skills/rogue');
    await env.writeFile(
      '/.fah/skills/rogue/SKILL.md.pointer',
      'file:///etc/passwd\n',
    );

    final result = await shell.exec('cat .fah/skills/rogue/SKILL.md');
    expect(result.valueOrNull!.exitCode, isNot(0));
    expect(result.valueOrNull!.stderr, contains('skill pointer refused'));
    expect(result.valueOrNull!.stdout, isEmpty);
  });

  test('a corrupt pointer (no builtin URI) refuses with the reason (E1)',
      () async {
    await env.createDir('/.fah/skills/broken');
    await env.writeFile('/.fah/skills/broken/SKILL.md.pointer', 'not a uri\n');

    final result = await shell.exec('cat .fah/skills/broken/SKILL.md');
    expect(result.valueOrNull!.exitCode, isNot(0));
    expect(result.valueOrNull!.stderr, contains('skill pointer refused'));
  });

  test('seeding twice keeps the workspace unchanged (idempotent)', () async {
    await seedBuiltinSkillPointers(env);
    final first = await env.listDir('/.fah/skills');
    await seedBuiltinSkillPointers(env);
    final second = await env.listDir('/.fah/skills');

    expect(
      first.valueOrNull!.map((e) => e.name).toList(),
      second.valueOrNull!.map((e) => e.name).toList(),
    );
  });
}

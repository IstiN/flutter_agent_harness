// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// gh-1444 AC1/AC2/E1/E5 — the read tool over the skill pointer surface:
//
// - AC1: reading `.fah/skills/<name>/SKILL.md` returns the same bytes as
//   reading `builtin://skills/<name>/SKILL.md` (the seeded pointer is
//   followed transparently; the FileError is gone).
// - AC2/E5 (IT-vfs-empty): a builtin resource that resolves EMPTY is
//   retried once; a payload on the retry succeeds, a persistent empty
//   fails with an explicit error naming the resource — no silent-empty
//   success path.
// - E1: a pointer with a corrupt/foreign target is refused loudly, never
//   silently falling back to the not-found error.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  late MemoryExecutionEnv env;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/ws');
  });

  Future<String> readText(
    String path, {
    String? Function(String)? builtinText,
  }) async {
    final tool = readFileTool(env, builtinText: builtinText);
    final result = await tool.execute({'path': path}, null, null);
    return result.content.whereType<TextContent>().map((b) => b.text).join();
  }

  Future<Object?> readError(String path) async {
    try {
      await readText(path);
    } on Object catch (error) {
      return error;
    }
    return null;
  }

  Future<void> seedPointer(String name, String body) async {
    final dir = '/ws/.fah/skills/$name';
    await env.createDir(dir);
    await env.writeFile('$dir/SKILL.md.pointer', body);
  }

  group('AC1 — pointer-following reads', () {
    test('fs path and builtin URI return identical bytes', () async {
      await seedPointer(
        'create-goal',
        '${builtinSkillPath('create-goal')}\n',
      );
      final path = '/ws/.fah/skills/create-goal/SKILL.md';

      final viaPointer = await readText(path);
      final viaBuiltin = await readText(builtinSkillPath('create-goal'));

      expect(viaPointer, viaBuiltin);
      expect(viaPointer, contains('create-goal'));
    });

    test('every builtin skill reads byte-identically through its pointer',
        () async {
      for (final skill in builtinSkills()) {
        await seedPointer(skill.name, '${builtinSkillPath(skill.name)}\n');
        final viaPointer = await readText(
          '/ws/.fah/skills/${skill.name}/SKILL.md',
        );
        final viaBuiltin = await readText(builtinSkillPath(skill.name));
        expect(viaPointer, viaBuiltin, reason: skill.name);
      }
    });

    test('a missing file with no pointer keeps the error', () async {
      final error = await readError('/ws/notes.txt');
      expect(error, isA<StateError>());
      expect(
        (error as StateError).message,
        isNot(contains('skill pointer')),
      );
    });

    test('a real file still wins over pointer machinery', () async {
      await env.writeFile('/ws/notes.txt', 'real bytes');
      expect(await readText('/ws/notes.txt'), 'real bytes');
    });
  });

  group('E1 — pointer refusals are loud', () {
    for (final (label, body) in const [
      ('foreign scheme', 'file:///etc/passwd\n'),
      ('unknown skill', 'builtin://skills/nope/SKILL.md\n'),
      ('cross-skill redirect', 'builtin://skills/js-apps/SKILL.md\n'),
      ('corrupt body', 'garbage\n'),
    ]) {
      test(label, () async {
        await seedPointer('create-goal', body);
        final error = await readError('/ws/.fah/skills/create-goal/SKILL.md');
        expect(error, isA<StateError>(), reason: label);
        expect(
          (error as StateError).message,
          contains('skill pointer refused'),
          reason: label,
        );
      });
    }
  });

  group('AC2/E5 — builtin empty payload never a silent success', () {
    test('empty on first lookup, content on retry → retried payload', () {
      var calls = 0;
      final text = readText(
        'builtin://skills/create-goal/SKILL.md',
        builtinText: (path) {
          calls++;
          return calls == 1 ? '' : 'recovered body';
        },
      );
      expect(text, completion('recovered body'));
    });

    test('persistently empty lookup → explicit error naming the resource',
        () async {
      await expectLater(
        readText(
          'builtin://skills/create-goal/SKILL.md',
          builtinText: (path) => '',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('builtin://skills/create-goal/SKILL.md'),
              contains('empty after retry'),
            ),
          ),
        ),
      );
    });

    test('the error names the resource id (E5)', () async {
      await expectLater(
        readText(
          'builtin://skills/self-settings/SKILL.md',
          builtinText: (path) => '',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('builtin://skills/self-settings/SKILL.md'),
              contains('empty after retry'),
            ),
          ),
        ),
      );
    });

    test('the compiled-in builtins are never empty (property sweep)', () {
      for (final skill in builtinSkills()) {
        expect(
          builtinSkillTextAt(builtinSkillPath(skill.name))!.isNotEmpty,
          isTrue,
          reason: skill.name,
        );
      }
    });
  });
}

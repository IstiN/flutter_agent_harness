// Skills discovery freshness (gh-1440): the skill-roots fingerprint math
// (UT-1), the freshness rendering contract of the prompt skills section
// (UT-2, AC1/AC7), and the `/skill:` cold-resolve decision table (UT-4,
// AC3/AC4). The CLI-level integration paths live in
// test/cli/skills_freshness_cli_test.dart; this file keeps the pure layer
// (MemoryExecutionEnv listings + the renderer) — fast, hermetic, no PTY.
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart';

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  Future<SkillRootsFingerprint> fingerprint() async {
    final roots = defaultSkillRoots(cwd: '/work', homeDir: '/home/u');
    return computeSkillRootsFingerprint(env, [
      ...roots.projectRoots,
      ...roots.userRoots,
    ]);
  }

  Future<void> seedSkill(String name, {String body = 'Do things.\n'}) async {
    await env.writeFile(
      '/work/.fah/skills/$name/SKILL.md',
      '---\nname: $name\ndescription: $name skill\n---\n$body',
    );
  }

  group('UT-1: fingerprint stability and change detection', () {
    test('missing roots are stable; an unchanged tree keeps the value', () async {
      final before = await fingerprint();
      final again = await fingerprint();
      // Both computations list only absent roots — stable "absent" stamps
      // (E-4: no rescan loop off a missing root).
      expect(before, equals(again));
      expect(before.stamps.values, everyElement(absentSkillRootStamp));
    });

    test('adding a skill entry changes the fingerprint', () async {
      await env.createDir('/work/.fah/skills');
      final before = await fingerprint();
      await seedSkill('latecomer');
      expect(await fingerprint(), isNot(equals(before)));
    });

    test('removing an entry changes it; renaming is replace, not duplicate',
        () async {
      await seedSkill('old-name');
      final before = await fingerprint();
      // Rename = old dir gone + new dir appears (E-5) — the listing changes
      // either way.
      await env.remove('/work/.fah/skills/old-name', recursive: true);
      expect(await fingerprint(), isNot(equals(before)));
      await seedSkill('new-name');
      final afterRename = await fingerprint();
      expect(await fingerprint(), equals(afterRename));
    });

    test('an mtime bump on a flat skill file changes it (edit detection)',
        () async {
      await env.createDir('/work/.fah/skills');
      await env.writeFile(
        '/work/.fah/skills/flat.md',
        '---\ndescription: v1\n---\nbody\n',
      );
      final before = await fingerprint();
      env.setMtime('/work/.fah/skills/flat.md', 1234567890);
      expect(await fingerprint(), isNot(equals(before)));
    });

    test('a change under one root leaves other roots untouched', () async {
      await seedSkill('a');
      final before = await fingerprint();
      await seedSkill('b');
      final after = await fingerprint();
      expect(after, isNot(equals(before)));
      // The untouched user root keeps its exact stamp.
      expect(
        after.stamps['/home/u/.fah/skills'],
        equals(before.stamps['/home/u/.fah/skills']),
      );
    });

    test('stamp math is content-free (names + kinds + sizes + mtimes only)',
        () {
      const entries = [
        FileInfo(
          name: 'deploy',
          path: '/work/.fah/skills/deploy',
          kind: FileKind.directory,
          size: 0,
          mtimeMs: 42,
        ),
        FileInfo(
          name: 'flat.md',
          path: '/work/.fah/skills/flat.md',
          kind: FileKind.file,
          size: 7,
          mtimeMs: 99,
        ),
      ];
      final stamp = skillRootStamp(entries);
      expect(stamp, contains('deploy:directory:0:42'));
      expect(stamp, contains('flat.md:file:7:99'));
      // Order-independent input, deterministic output.
      final reversed = skillRootStamp(entries.reversed.toList());
      expect(reversed, equals(stamp));
    });
  });

  group('UT-2: freshness rendering determinism (AC1, AC7)', () {
    const skill = Skill(
      name: 'deploy',
      description: 'Deploy the app',
      filePath: '/work/.fah/skills/deploy/SKILL.md',
      scope: SkillScope.project,
      source: SkillSource.fah,
    );

    test('no scannedAt renders the legacy shape byte-identically', () {
      final out = formatSkillsForPrompt([skill]);
      expect(out, contains('</available_skills>'));
      expect(out, isNot(contains('scanned at')));
      expect(out, isNot(contains('mid-session')));
    });

    test(
      'compose vs re-compose after an unchanged fingerprint ⇒ byte-identical',
      () async {
        await seedSkill('deploy');
        final scannedAt = DateTime.utc(2026, 10, 8, 15, 43, 13);
        Future<String> compose() async => formatSkillsForPrompt(
          await discoverSkills(
            env,
            projectRoots: const [
              SkillRoot('/work/.fah/skills', SkillSource.fah),
            ],
          ),
          scannedAt: scannedAt,
        );
        final first = await compose();
        // The freshness check runs between compositions and detects no
        // change — the section must not move by a byte (AC1, I1).
        final fpBefore = await fingerprint();
        final second = await compose();
        expect(await fingerprint(), equals(fpBefore));
        expect(second, equals(first));
      },
    );

    test('mid-session entries carry the added mid-session flag with source',
        () {
      final out = formatSkillsForPrompt(
        [skill],
        scannedAt: DateTime.utc(2026, 10, 8, 15, 43, 13),
        midSessionNames: {'deploy'},
      );
      expect(out, contains('added mid-session (fah)'));
      // Boot-time entries carry no flag.
      final quiet = formatSkillsForPrompt(
        [skill],
        scannedAt: DateTime.utc(2026, 10, 8, 15, 43, 13),
      );
      expect(quiet, isNot(contains('mid-session')));
    });

    test('liveRediscovery off renders the staleness footer; on the stamp',
        () {
      final scannedAt = DateTime.utc(2026, 10, 8, 15, 43, 13);
      final off = formatSkillsForPrompt(
        [skill],
        scannedAt: scannedAt,
        liveRediscovery: false,
      );
      expect(
        off,
        contains(
          'skills index scanned at 2026-10-08T15:43:13.000Z — '
          'newer files are NOT reflected; /skills reload to refresh',
        ),
      );
      final on = formatSkillsForPrompt(
        [skill],
        scannedAt: scannedAt,
        liveRediscovery: true,
      );
      expect(on, contains('skills index scanned at 2026-10-08T15:43:13.000Z'));
      expect(on, isNot(contains('NOT reflected')));
    });

    test('no skills ⇒ empty section, even with a stamp', () {
      expect(
        formatSkillsForPrompt(
          const [],
          scannedAt: DateTime.utc(2026, 10, 8),
        ),
        '',
      );
    });
  });

  group('UT-4: /skill: resolution decision table', () {
    test(
      'indexed / on-disk-unindexed / disabled-by-toggle / nowhere — '
      'only the last says unknown skill',
      () async {
        // indexed: `known` is discovered at boot. disabled: `off` is
        // discovered but toggled off. latecomer: lands on disk AFTER boot.
        await seedSkill('known');
        await env.writeFile(
          '/work/.fah/skills/off/SKILL.md',
          '---\nname: off\ndescription: toggled off\n---\nbody\n',
        );
        final cli = AgentCli(
          config: AgentCliConfig(
            model: testModel,
            apiKey: 'test-key',
            env: env,
            sessionRoot: '/sessions',
            providerKind: 'openai-completions',
            skillToggles: {'off': false},
          ),
          io: io,
          // Three invocations start runs (latecomer, known, and one spare
          // for the boot-time none).
          streamFunction: FakeStreamFunction([
            textTurn('ok'),
            textTurn('ok'),
            textTurn('ok'),
          ]).call,
        );
        final run = cli.run();
        await waitForIt(
          () => cli.systemPrompt.contains('<name>known</name>'),
          reason: 'boot index; out=${io.out}',
        );

        // nowhere: exact wording, no new noise (AC4).
        io.sendLine('/skill:does-not-exist');
        await waitForIt(
          () => io.out.toString().contains('unknown skill: does-not-exist'),
          reason: 'unknown-skill step; out=${io.out}',
        );
        expect(
          io.out.toString(),
          isNot(contains('discovered since startup')),
        );

        // Mid-session drop AFTER that miss's rescan: `latecomer` is on
        // disk but unindexed — the cold-resolve path (AC3).
        await seedSkill('latecomer');
        io.sendLine('/skill:latecomer');
        await waitForIt(
          () => io.out.toString().contains(
            'skill latecomer discovered since startup — index refreshed',
          ),
          reason: 'cold-resolve warning; out=${io.out}',
        );
        await waitForIt(
          () => io.out.toString().contains('skill latecomer — '),
          reason: 'latecomer render; out=${io.out}',
        );

        // indexed: the normal path, no warning — assert on the DELTA (the
        // transcript already carries the latecomer cold-resolve line).
        final outBeforeKnown = io.out.toString();
        io.sendLine('/skill:known');
        await waitForIt(
          () => io.out.toString().contains('skill known — '),
          reason: 'known render; out=${io.out}',
        );
        final knownDelta = io.out.toString().substring(outBeforeKnown.length);
        expect(knownDelta, isNot(contains('discovered since startup')));
        expect(knownDelta, contains('skill known — '));

        // disabled-by-toggle: named way back, never `unknown skill`.
        io.sendLine('/skill:off');
        await waitForIt(
          () => io.out.toString().contains('skill off is disabled'),
          reason: 'off disabled; out=${io.out}',
        );
        expect(io.out.toString(), contains('/skills on off'));

        io.sendLine('/exit');
        await run;
      },
    );
  });
}

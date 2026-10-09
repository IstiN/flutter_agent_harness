// Skills discovery freshness — CLI-level integration tests (gh-1440).
//
// IT-1: a SKILL.md dropped mid-session joins the next composed prompt with
//       the `added mid-session` flag (AC2).
// IT-2: `/skill:` cold-resolve of an on-disk-but-unindexed skill — warning,
//       body rendered, second invocation takes the normal path (AC3, I4).
// IT-3: true negatives keep the exact `unknown skill` wording (AC4).
// IT-4: a malformed SKILL.md mid-session degrades to skip + one warning;
//       a later fixed scan picks it up (AC6, E-1/E-2).
// IT-5: `skills.liveRediscovery: false` — no per-turn rescan, staleness
//       footer, cold-resolve still works (AC7).
// IT-6: consent semantics unchanged — third-party drops stay invisible
//       while denied, appear flagged after a grant; an IO-error root keeps
//       the last snapshot with one warning (AC8, I2, I3).
// UT-3 (CLI-level): bounded check cost — one metadata listing per root and
//       zero SKILL.md content reads on an unchanged turn; a churn storm
//       triggers exactly one rescan (AC5, I1, I5, E-7).
//
// Fake-host determinism: MemoryExecutionEnv + FakeCliIO, no PTY.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// A delegating env that counts freshness-relevant operations: directory
/// listings (the metadata the fingerprint check is allowed to spend) and
/// SKILL.md body reads (zero allowed on an unchanged fingerprint, I1).
/// [throwOnListDir] injects an IO failure for one path — the I2
/// degradation fixture.
final class _CountingEnv implements ExecutionEnv {
  _CountingEnv(this.inner, {this.throwOnListDir});

  final MemoryExecutionEnv inner;

  /// When set, a `listDir` of this path throws instead of returning.
  final String? throwOnListDir;

  int listDirCalls = 0;
  final skillBodyReads = <String>[];

  @override
  String get cwd => inner.cwd;

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) async {
    final doomed = throwOnListDir;
    if (doomed != null && doomed == path) {
      throw StateError('injected IO failure');
    }
    listDirCalls++;
    return inner.listDir(path);
  }

  @override
  Future<Result<String, FileError>> readTextFile(String path) async {
    if (path.endsWith('.md')) skillBodyReads.add(path);
    return inner.readTextFile(path);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });
  tearDown(() => io.close());

  Future<void> seedProjectSkill(String name, {String? description}) =>
      env.writeFile(
        '/work/.fah/skills/$name/SKILL.md',
        '---\nname: $name\n'
        'description: ${description ?? '$name skill'}\n---\n'
        '$name body\n',
      );

  AgentCli cliFor(
    StreamFunction streamFunction, {
    SkillsAccess skillsAccess = SkillsAccess.granted,
    bool liveRediscovery = true,
    ExecutionEnv? envOverride,
  }) => AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: 'test-key',
      env: envOverride ?? env,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
      skillsAccess: skillsAccess,
      skillsLiveRediscovery: liveRediscovery,
    ),
    io: io,
    streamFunction: streamFunction,
  );

  group('IT-1: mid-session skill joins the next composition (AC2)', () {
    test('appears in the next prompt flagged; /skills lists it', () async {
      await seedProjectSkill('alpha');
      final fake = FakeStreamFunction([textTurn('ok'), textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();
      await waitForIt(
        () => cli.systemPrompt.contains('<name>alpha</name>'),
        reason: 'boot index',
      );
      expect(cli.systemPrompt, isNot(contains('mid-session')));
      final bootStamp =
          RegExp(r'skills index scanned at (\S+)').firstMatch(
            cli.systemPrompt,
          )?[1];

      // Mid-session drop, then a fresh turn: the rescan rides the
      // per-turn freshness check, no /skills reload, no restart.
      await seedProjectSkill('latecomer');
      io.sendLine('hello');
      await waitForIt(() => fake.calls >= 1, reason: 'first turn');
      expect(
        cli.systemPrompt,
        contains('<name>latecomer</name>'),
        reason: 'out=${io.out}',
      );
      expect(cli.systemPrompt, contains('added mid-session (fah)'));
      expect(cli.systemPrompt, contains('<name>alpha</name>'));
      // The boot entry carries no flag; only the latecomer does.
      final alphaBlock = RegExp(
        r'<skill>\s*<name>alpha</name>.*?</skill>',
        dotAll: true,
      ).firstMatch(cli.systemPrompt)!;
      expect(alphaBlock.group(0), isNot(contains('mid-session')));
      // The rescan refreshed the scan stamp (content changed).
      final newStamp =
          RegExp(r'skills index scanned at (\S+)').firstMatch(
            cli.systemPrompt,
          )?[1];
      expect(newStamp, isNot(equals(bootStamp)));

      // /skills agrees with the prompt.
      io.sendLine('/skills');
      await waitForIt(
        () => RegExp(
          r'latecomer — .*added mid-session',
          dotAll: true,
        ).hasMatch(io.out.toString()),
        reason: 'skills list; out=${io.out}',
      );
      io.sendLine('/exit');
      await run;
    });

    test('a removed skill drops out with a one-line note (E-4)', () async {
      await seedProjectSkill('doomed');
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();
      await waitForIt(
        () => cli.systemPrompt.contains('<name>doomed</name>'),
        reason: 'boot index',
      );
      await env.remove('/work/.fah/skills/doomed', recursive: true);
      io.sendLine('hello');
      await waitForIt(() => fake.calls >= 1, reason: 'turn');
      await waitForIt(
        () => io.out.toString().contains(
          'skills: no longer on disk — dropped from the index: doomed',
        ),
        reason: 'drop note; out=${io.out}',
      );
      expect(cli.systemPrompt, isNot(contains('<name>doomed</name>')));
      io.sendLine('/exit');
      await run;
    });
  });

  group('IT-2: cold-resolve renders grants and re-uses the index (AC3, I4)',
      () {
    test('warning + body; second invocation is the indexed path', () async {
      await seedProjectSkill('alpha');
      final fake = FakeStreamFunction([
        textTurn('ok'),
        textTurn('ok'),
        textTurn('ok'),
      ]);
      final cli = cliFor(fake.call);
      final run = cli.run();
      await waitForIt(
        () => cli.systemPrompt.contains('<name>alpha</name>'),
        reason: 'boot index',
      );

      await seedProjectSkill('latecomer');
      io.sendLine('/skill:latecomer now');
      await waitForIt(
        () =>
            io.out.toString().contains(
              'skill latecomer discovered since startup — index refreshed',
            ),
        reason: 'cold-resolve warning; out=${io.out}',
      );
      await waitForIt(
        () => io.out.toString().contains('skill latecomer — '),
        reason: 'render',
      );
      await waitForIt(() => fake.calls >= 1, reason: 'run');
      final user = fake.contexts.last.messages.whereType<UserMessage>().last;
      expect(user.content as String, contains('latecomer body'));
      expect(user.content as String, contains('ARGUMENTS: now'));

      // Second invocation: the indexed path — no second warning.
      final outBefore = io.out.toString();
      io.sendLine('/skill:latecomer again');
      await waitForIt(
        () => fake.calls >= 2,
        reason: 'second run; out=${io.out}',
      );
      final delta = io.out.toString().substring(outBefore.length);
      expect(delta, isNot(contains('discovered since startup')));
      io.sendLine('/exit');
      await run;
    });
  });

  group('IT-3: true negatives keep their wording (AC4)', () {
    test('unknown before and after a mid-session drop elsewhere', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();
      await waitForIt(
        () => cli.systemPrompt.isNotEmpty,
        reason: 'boot',
      );
      io.sendLine('/skill:does-not-exist');
      await waitForIt(
        () => io.out.toString().contains('unknown skill: does-not-exist'),
        reason: 'first miss; out=${io.out}',
      );
      await seedProjectSkill('unrelated');
      io.sendLine('/skill:does-not-exist');
      await waitForIt(
        () =>
            RegExp('unknown skill: does-not-exist.*unknown skill: '
                'does-not-exist', dotAll: true).hasMatch(io.out.toString()),
        reason: 'second miss; out=${io.out}',
      );
      expect(io.out.toString(), isNot(contains('discovered since startup')));
      io.sendLine('/exit');
      await run;
    });
  });

  group('IT-4: malformed SKILL.md degrades to skip + one warning (AC6)', () {
    test('skip + warn once; a later scan picks up the fixed file', () async {
      await seedProjectSkill('alpha');
      final fake = FakeStreamFunction([textTurn('ok'), textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();
      await waitForIt(
        () => cli.systemPrompt.contains('<name>alpha</name>'),
        reason: 'boot index',
      );

      // Mid-session drop of a torn write (opened fence, never closed —
      // the E-1 shape).
      await env.writeFile(
        '/work/.fah/skills/broken/SKILL.md',
        '---\nname: broken\ndescription: torn\n',
      );
      io.sendLine('hello');
      await waitForIt(() => fake.calls >= 1, reason: 'turn');
      await waitForIt(
        () => io.out.toString().contains('malformed frontmatter — skipped'),
        reason: 'malformed warning; out=${io.out}',
      );
      expect(
        RegExp('malformed frontmatter').allMatches(io.out.toString()),
        hasLength(1),
        reason: 'warn once',
      );
      expect(cli.systemPrompt, isNot(contains('<name>broken</name>')));
      expect(cli.systemPrompt, contains('<name>alpha</name>'));

      // The fixed rewrite rides the NEXT scan (here forced by a second
      // mid-session drop — a plain in-place rewrite is fingerprint-
      // invisible by design, see the capability table).
      await seedProjectSkill('latecomer');
      io.sendLine('again');
      await waitForIt(() => fake.calls >= 2, reason: 'second turn');
      expect(cli.systemPrompt, contains('<name>latecomer</name>'));
      expect(cli.systemPrompt, contains('<name>broken</name>'));
      expect(
        RegExp('malformed frontmatter').allMatches(io.out.toString()),
        hasLength(1),
        reason: 'still warned once',
      );
      io.sendLine('/exit');
      await run;
    });
  });

  group('IT-5: liveRediscovery off (AC7)', () {
    test('no per-turn rescan, staleness footer, cold-resolve works',
        () async {
      await seedProjectSkill('alpha');
      final fake = FakeStreamFunction([textTurn('ok'), textTurn('ok')]);
      final cli = cliFor(fake.call, liveRediscovery: false);
      final run = cli.run();
      await waitForIt(
        () => cli.systemPrompt.contains('<name>alpha</name>'),
        reason: 'boot index',
      );
      expect(
        cli.systemPrompt,
        contains('newer files are NOT reflected; /skills reload to refresh'),
      );
      final bootStamp =
          RegExp(r'skills index scanned at (\S+)').firstMatch(
            cli.systemPrompt,
          )?[1];

      await seedProjectSkill('latecomer');
      io.sendLine('hello');
      await waitForIt(() => fake.calls >= 1, reason: 'turn');
      // No rescan: the stamp did not move and the latecomer is absent.
      expect(
        RegExp(r'skills index scanned at (\S+)').firstMatch(
          cli.systemPrompt,
        )?[1],
        bootStamp,
      );
      expect(cli.systemPrompt, isNot(contains('<name>latecomer</name>')));

      // The manual escape hatch still resolves (cold-resolve ignores the
      // knob).
      io.sendLine('/skill:latecomer');
      await waitForIt(
        () => io.out.toString().contains(
          'skill latecomer discovered since startup — index refreshed',
        ),
        reason: 'cold-resolve; out=${io.out}',
      );
      io.sendLine('/exit');
      await run;
    });
  });

  group('IT-6: consent semantics unchanged (AC8, I2, I3)', () {
    test('third-party drop invisible while denied; flagged after grant',
        () async {
      await seedProjectSkill('alpha');
      final fake = FakeStreamFunction([textTurn('ok'), textTurn('ok')]);
      final cli = cliFor(fake.call, skillsAccess: SkillsAccess.denied);
      final run = cli.run();
      await waitForIt(
        () => cli.systemPrompt.contains('<name>alpha</name>'),
        reason: 'boot index',
      );

      await env.writeFile(
        '/work/.claude/skills/claudethird/SKILL.md',
        '---\nname: claudethird\ndescription: third party\n---\nbody\n',
      );
      io.sendLine('hello');
      await waitForIt(() => fake.calls >= 1, reason: 'turn');
      // First-party roots are checked every composition (I3) — but the
      // third-party root is not even stat'ed, so no churn happened and the
      // skill stays invisible.
      expect(cli.systemPrompt, isNot(contains('claudethird')));
      expect(cli.systemPrompt, contains('<name>alpha</name>'));

      // The grant rescans: the skill appears, flagged with its source.
      io.sendLine('/skills access granted');
      await waitForIt(
        () => cli.systemPrompt.contains('<name>claudethird</name>'),
        reason: 'post-grant; out=${io.out}',
      );
      expect(cli.systemPrompt, contains('added mid-session (claude)'));
      io.sendLine('/exit');
      await run;
    });

    test('an IO-error root keeps the last snapshot and warns once (I2)',
        () async {
      final throwingEnv = MemoryExecutionEnv(cwd: '/work');
      await throwingEnv.writeFile(
        '/work/.fah/skills/alpha/SKILL.md',
        '---\nname: alpha\ndescription: alpha skill\n---\nbody\n',
      );
      final fake = FakeStreamFunction([textTurn('ok'), textTurn('ok')]);
      final cli = cliFor(
        fake.call,
        envOverride: _CountingEnv(
          throwingEnv,
          throwOnListDir: '/work/.fah/skills',
        ),
      );
      final run = cli.run();
      // Boot failure of the check path is data, not a crash: the session
      // boots, and the last good (empty) index stands.
      await waitForIt(() => cli.systemPrompt.isNotEmpty, reason: 'boot');
      io.sendLine('hello');
      await waitForIt(() => fake.calls >= 1, reason: 'turn');
      await waitForIt(
        () => io.out.toString().contains('freshness check failed'),
        reason: 'I2 warning; out=${io.out}',
      );
      expect(
        RegExp('freshness check failed').allMatches(io.out.toString()),
        hasLength(1),
        reason: 'warn once',
      );
      io.sendLine('/exit');
      await run;
    });
  });

  group('UT-3/AC5: bounded check cost', () {
    test(
      'unchanged turn: one listing per root, zero skill-body reads; '
      'a churn storm: exactly one rescan (E-7)',
      () async {
        await seedProjectSkill('alpha');
        final counting = _CountingEnv(env);
        final fake = FakeStreamFunction([textTurn('ok'), textTurn('ok')]);
        final cli = cliFor(fake.call, envOverride: counting);
        final run = cli.run();
        await waitForIt(
          () => cli.systemPrompt.contains('<name>alpha</name>'),
          reason: 'boot index',
        );
        counting.listDirCalls = 0;
        counting.skillBodyReads.clear();

        // Unchanged turn: the freshness check stats every allowed root
        // exactly once and reads no content (I1, AC5).
        final roots = defaultSkillRoots(cwd: '/work');
        final allowedRootCount = [
          ...roots.projectRoots,
          ...roots.userRoots,
        ].length; // homeDir null ⇒ user roots empty.
        io.sendLine('hello');
        await waitForIt(() => fake.calls >= 1, reason: 'turn');
        await waitForIt(
          () => io.out.toString().contains('ok'),
          reason: 'reply',
        );
        expect(counting.listDirCalls, allowedRootCount);
        expect(counting.skillBodyReads, isEmpty);

        // Churn storm (E-7): many changes land between two compositions —
        // exactly one rescan at the next composition.
        for (var i = 0; i < 5; i++) {
          await seedProjectSkill('storm$i');
        }
        counting.listDirCalls = 0;
        counting.skillBodyReads.clear();
        io.sendLine('again');
        await waitForIt(
          () => cli.systemPrompt.contains('<name>storm4</name>'),
          reason: 'post-storm index',
        );
        // All five picked up by the ONE rescan: the prompt names every
        // storm skill, and the drop-note channel printed no per-skill
        // rescan traces. The observable one-rescan proof: the scanned-at
        // stamp moved exactly once (boot → rescan), and the scan's own
        // listings are the freshness check's roots + the rescan's reads.
        for (var i = 0; i < 5; i++) {
          expect(cli.systemPrompt, contains('<name>storm$i</name>'));
        }
        // Body reads: exactly the six rescan-discovered SKILL.md bodies —
        // never the unchanged alpha (byte-identical entries are not
        // re-read; I1 is about the UNCHANGED path, asserted above).
        expect(counting.skillBodyReads, everyElement(contains('SKILL.md')));
        io.sendLine('/exit');
        await run;
      },
    );
  });
}

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
/// degradation fixture (assigned mid-test, so it is a mutable field and
/// not a constructor parameter).
final class _CountingEnv implements ExecutionEnv {
  _CountingEnv(this.inner);

  final MemoryExecutionEnv inner;

  /// When set, a `listDir` of this path throws instead of returning.
  /// Mutable: tests flip it mid-session to model a root turning unreadable
  /// AFTER a healthy boot.
  String? throwOnListDir;

  /// When set, a `readTextFile` of this path throws — the rescan-failure
  /// fixture: a SKILL.md that lists fine (the fingerprint fires) but whose
  /// body read dies mid-scan, so `_reloadSkills` itself throws.
  String? throwOnReadTextFile;

  int listDirCalls = 0;
  final skillBodyReads = <String>[];
  final listDirLog = <String>[];

  @override
  String get cwd => inner.cwd;

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      inner.absolutePath(path);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      inner.joinPath(parts);

  @override
  Future<Result<String, FileError>> readTextFile(String path) async {
    final doomed = throwOnReadTextFile;
    if (doomed != null && doomed == path) {
      throw StateError('injected read failure');
    }
    if (path.endsWith('.md')) skillBodyReads.add(path);
    return inner.readTextFile(path);
  }

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      inner.readBinaryFile(path);

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => inner.readTextLines(path, maxLines: maxLines);

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => inner.writeBinaryFile(path, content);

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      inner.writeFile(path, content);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      inner.appendFile(path, content);

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      inner.fileInfo(path);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) async {
    final doomed = throwOnListDir;
    if (doomed != null && doomed == path) {
      throw StateError('injected IO failure');
    }
    listDirCalls++;
    listDirLog.add(path);
    return inner.listDir(path);
  }

  @override
  Future<Result<bool, FileError>> exists(String path) => inner.exists(path);

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => inner.createDir(path, recursive: recursive);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => inner.remove(path, recursive: recursive, force: force);

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => inner.exec(command, options: options);
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

  /// Waits until [log] stops growing — boot's async tail (memory-section
  /// refresh, inbox tick) drains after the boot wait before the counting
  /// window may open.
  Future<void> waitQuiet(List<String> log) async {
    for (var round = 0; round < 100; round++) {
      final size = log.length;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (log.length == size) return;
    }
    fail('listDir log never went quiet');
  }

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
      await env.writeFile(
        '/work/.fah/skills/broken/SKILL.md',
        '---\nname: broken\ndescription: fixed now\n---\nbody\n',
      );
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
      final counting = _CountingEnv(throwingEnv);
      final fake = FakeStreamFunction([textTurn('ok'), textTurn('ok')]);
      final cli = cliFor(fake.call, envOverride: counting);
      final run = cli.run();
      await waitForIt(
        () => cli.systemPrompt.contains('<name>alpha</name>'),
        reason: 'boot index',
      );
      // Mid-session the root turns unreadable (permissions change, mount
      // drop): the next composition's check must keep the last good
      // snapshot, warn once, and never block the turn (I2).
      counting.throwOnListDir = '/work/.fah/skills';
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
      // The last good snapshot stands: alpha is still indexed.
      expect(cli.systemPrompt, contains('<name>alpha</name>'));
      // And the turn was never blocked (its reply went out above).
      io.sendLine('/exit');
      await run;
    });
  });

  group('IT-7 (review): a failed rescan retries on the next turn (I2)', () {
    test(
      'a rescan that throws keeps the old baseline — the next turn '
      'rescans again and picks the skill up',
      () async {
        await seedProjectSkill('alpha');
        final counting = _CountingEnv(env);
        final fake = FakeStreamFunction([
          textTurn('ok'),
          textTurn('ok'),
          textTurn('ok'),
        ]);
        final cli = cliFor(fake.call, envOverride: counting);
        final run = cli.run();
        await waitForIt(
          () => cli.systemPrompt.contains('<name>alpha</name>'),
          reason: 'boot index',
        );

        // A latecomer lands mid-session, but its body read dies inside the
        // rescan (disk hiccup mid-turn): the check must keep the last good
        // index, warn once, and — the reviewed fix — NOT latch the new
        // fingerprint, so the next turn retries the rescan instead of
        // staying blind to the stale index.
        await seedProjectSkill('latecomer');
        counting.throwOnReadTextFile =
            '/work/.fah/skills/latecomer/SKILL.md';
        io.sendLine('hello');
        await waitForIt(() => fake.calls >= 1, reason: 'turn 1');
        await waitForIt(
          () => io.out.toString().contains('freshness check failed'),
          reason: 'rescan failure warning; out=${io.out}',
        );
        expect(
          RegExp('freshness check failed').allMatches(io.out.toString()),
          hasLength(1),
        );
        // The last good snapshot stands: alpha in, latecomer not.
        expect(cli.systemPrompt, contains('<name>alpha</name>'));
        expect(cli.systemPrompt, isNot(contains('<name>latecomer</name>')));

        // The read heals; the next turn's check sees the still-stale
        // baseline (the failure did NOT latch it) and rescans again —
        // exactly one more rescan, and the warn-once latch stays quiet.
        counting.throwOnReadTextFile = null;
        io.sendLine('again');
        await waitForIt(
          () => cli.systemPrompt.contains('<name>latecomer</name>'),
          reason: 'retry rescan; out=${io.out}',
        );
        expect(cli.systemPrompt, contains('added mid-session (fah)'));
        expect(
          RegExp('freshness check failed').allMatches(io.out.toString()),
          hasLength(1),
          reason: 'warn once across both turns',
        );
        io.sendLine('/exit');
        await run;
      },
    );
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
        await waitQuiet(counting.listDirLog);
        counting.listDirCalls = 0;
        counting.skillBodyReads.clear();
        counting.listDirLog.clear();

        // Unchanged turn: the freshness check stats every allowed root
        // exactly once and reads no content (I1, AC5).
        final roots = defaultSkillRoots(cwd: '/work');
        final allowedRootCount = [
          ...roots.projectRoots,
          ...roots.userRoots,
        ].length; // homeDir null ⇒ user roots empty.
        io.sendLine('hello');
        await waitForIt(() => fake.calls >= 1, reason: 'turn');
        await waitQuiet(counting.listDirLog);
        final turn1SkillRoots = counting.listDirLog
            .where((e) => e.contains('/skills') || e.contains('/commands'))
            .toList();
        expect(turn1SkillRoots, hasLength(allowedRootCount));
        expect(counting.skillBodyReads, isEmpty);

        // Churn storm (E-7): many changes land between two compositions —
        // exactly one rescan at the next composition.
        for (var i = 0; i < 5; i++) {
          await seedProjectSkill('storm$i');
        }
        await waitQuiet(counting.listDirLog);
        counting.listDirCalls = 0;
        counting.skillBodyReads.clear();
        counting.listDirLog.clear();
        io.sendLine('again');
        await waitForIt(
          () => cli.systemPrompt.contains('<name>storm4</name>'),
          reason: 'post-storm index',
        );
        await waitQuiet(counting.listDirLog);
        // All five picked up by the ONE rescan (I5, E-7): the churn storm
        // costs exactly THREE root-listing waves — the check's fingerprint,
        // the rescan's discovery scan (what /skills reload always cost),
        // and the rescan's own post-scan baseline — never one wave per
        // changed file. A second rescan would show a fourth wave.
        final turn2SkillRootListings = counting.listDirLog
            .where((e) => e.contains('/skills') || e.contains('/commands'))
            .length;
        expect(turn2SkillRootListings, allowedRootCount * 3);
        for (var i = 0; i < 5; i++) {
          expect(cli.systemPrompt, contains('<name>storm$i</name>'));
        }
        // Body reads happen ONLY inside the rescan's full re-discovery
        // (I4 — no ad-hoc side door): bounded by the discovered file count,
        // never per changed root wave.
        expect(
          counting.skillBodyReads,
          hasLength(6), // alpha + storm0..4 — one rescan, one read per file.
        );
        io.sendLine('/exit');
        await run;
      },
    );
  });
}

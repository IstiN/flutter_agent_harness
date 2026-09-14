/// Compaction report block (issue #276, AC1): the block renders the REAL
/// compaction pass outcome — exact before/after token numbers, the engine
/// (smol/main role) that did the summarizing (review major 3), records
/// hidden vs summarized — and a manual `/compact` that has nothing to do
/// prints a clean note instead of faking a compaction. The report is a UI
/// block: it must never leak into the model context (issue #276 AC5).
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  group('formatCompactionReport (UT-report)', () {
    test('renders exact numbers, the engine, and the record counts', () {
      final pass = AutoCompactorPass(
        pass: 1,
        tokensBefore: 210925,
        tokensAfter: 45123,
        fallback: 'smol',
        ok: true,
        summary: '## Decisions\n- ship it',
        hiddenRecords: 42,
        summarizedMessages: 17,
      );
      expect(formatCompactionReport(pass, auto: false), [
        'compacted · smol',
        'tokens: 210925 → 45123 (165802 freed · 79%)',
        'records: 42 hidden · 17 summarized',
        'summary:',
        '```',
        '## Decisions\n- ship it',
        '```',
      ]);
    });

    test('the auto header and pass number ride the same line', () {
      final pass = AutoCompactorPass(
        pass: 2,
        tokensBefore: 40000,
        tokensAfter: 20000,
        fallback: 'main',
        ok: true,
        summary: 's',
      );
      final lines = formatCompactionReport(pass, auto: true);
      expect(lines.first, 'auto-compacted · main · pass 2');
      // Zero before-count cannot divide: 0%.
      expect(lines[1], 'tokens: 40000 → 20000 (20000 freed · 50%)');
    });

    test('a pass without an engine names nothing instead of lying', () {
      final pass = AutoCompactorPass(
        pass: 1,
        tokensBefore: 1000,
        tokensAfter: 100,
        fallback: null,
        ok: true,
        summary: 's',
      );
      expect(formatCompactionReport(pass, auto: true).first, 'auto-compacted');
    });

    test('an empty summary still closes the fence (copyable block)', () {
      final pass = AutoCompactorPass(
        pass: 1,
        tokensBefore: 1000,
        tokensAfter: 100,
        fallback: 'smol',
        ok: true,
      );
      expect(formatCompactionReport(pass, auto: false).last, '```');
    });

    test('a restamp that grew the transcript clamps to 0 freed', () {
      final pass = AutoCompactorPass(
        pass: 1,
        tokensBefore: 8451,
        tokensAfter: 8481,
        fallback: 'main=test-provider/test-model',
        ok: true,
        summary: 's',
      );
      expect(
        formatCompactionReport(pass, auto: false)[1],
        'tokens: 8451 → 8481 (0 freed · 0%)',
      );
    });
  });

  group('manual /compact (UT-report)', () {
    late MemoryExecutionEnv env;
    late FakeCliIO io;

    setUp(() {
      env = MemoryExecutionEnv(cwd: '/work');
      io = FakeCliIO();
    });

    AgentCli cliFor(StreamFunction streamFunction, {Model? model}) => AgentCli(
      config: AgentCliConfig(
        model: model ?? testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        skillsAccess: SkillsAccess.granted,
        // The structured default (issue #287) gates every pass on the
        // same threshold the auto guard uses, so a manual /compact on a
        // small transcript is a no-op there. The report block under test
        // is the classic engine's — pin it (the documented rollback).
        compactionEngine: CompactionEngine.classic,
      ),
      io: io,
      streamFunction: streamFunction,
    );

    test(
      'an empty session prints the clean note, never a fake block',
      () async {
        final fake = FakeStreamFunction([textTurn('unused')]);
        final cli = cliFor(fake.call);
        final run = cli.run();
        io.sendLine('/compact');
        await waitForIt(() => io.out.toString().contains('nothing to compact'));
        io.sendLine('/exit');
        await run;

        final output = io.out.toString();
        expect(output, isNot(contains('● compacted')));
        expect(output, isNot(contains('● auto-compacted')));
        expect(fake.calls, 0); // no summarizer turn behind the note
        final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
        final sessions = await repo.list(cwd: '/work');
        expect(sessions, isEmpty); // untouched session leaves nothing behind
      },
    );

    test(
      'manual /compact renders the block with the real numbers and engine',
      () async {
        final fake = FakeStreamFunction([
          // A big answer crosses the noise floor: the freed delta must be
          // real, not estimator jitter.
          textTurn('a' * 20000),
          textTurn('SUMMARY TEXT'),
          textTurn('after'),
        ]);
        final cli = cliFor(fake.call);
        final run = cli.run();

        io.sendLine('q');
        await waitForIt(() => fake.calls == 1 && !cli.isBusy);
        io.sendLine('/compact');
        await waitForIt(() => io.out.toString().contains('● compacted'));
        io.sendLine('/exit');
        await run;

        final output = io.out.toString();
        // The engine line names the role that summarized (review major
        // 3): role=model, as the compactor labels its attempts.
        final header = RegExp(
          r'● compacted · (smol|main)=\S+',
        ).firstMatch(output);
        expect(header, isNotNull, reason: output);
        // Before → after with a REAL freed delta, self-consistent.
        final numbers = RegExp(
          r'tokens: (\d+) → (\d+) \((\d+) freed · (\d+)%\)',
        ).firstMatch(output);
        expect(numbers, isNotNull, reason: output);
        final before = int.parse(numbers!.group(1)!);
        final after = int.parse(numbers.group(2)!);
        final freed = int.parse(numbers.group(3)!);
        // The freed delta is the before/after pair, clamped at 0 for
        // estimator noise — exactly the pass event's numbers.
        expect(freed, before > after ? before - after : 0);
        expect(
          output,
          contains(RegExp(r'records: \d+ hidden · \d+ summarized')),
        );
        // The full summary is copyable out of the fenced block.
        expect(output, contains('```\nSUMMARY TEXT\n```'));
      },
    );

    test('the report never leaks into the model context (REG-leak)', () async {
      final fake = FakeStreamFunction([
        textTurn('answer'),
        textTurn('SUMMARY TEXT'),
        textTurn('after'),
      ]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('q');
      await waitForIt(() => fake.calls == 1 && !cli.isBusy);
      io.sendLine('/compact');
      await waitForIt(() => io.out.toString().contains('● compacted'));
      io.sendLine('next');
      await waitForIt(() => fake.calls == 3 && !cli.isBusy);
      io.sendLine('/exit');
      await run;

      // The turn AFTER the compaction is what the model actually sees:
      // the projected summary is there, the UI block is not.
      final messages = fake.contexts[2].messages;
      final serialized = messages
          .map((m) => m.toJson().toString())
          .join('\n---\n');
      expect(serialized, contains('<summary>'));
      expect(serialized, contains('SUMMARY TEXT'));
      expect(serialized, isNot(contains('● compacted')));
      expect(serialized, isNot(contains('tokens: ')));
      expect(serialized, isNot(contains('records: ')));
    });
  });
}

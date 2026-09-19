// Issue #673 — auto-compact mid-turn crashed the run with a raw
// "Null check operator used on a null value" right after a successful
// compaction ("[context overflowed — auto-compacted; continuing the turn]").
//
// Production chain reproduced here end to end, deterministically, over the
// scripted-LLM CLI harness (no network):
// 1. a marathon session carrying structured `hidden_range` records is
//    resumed WINDOWED (the CLI's `--session` resume: resident set = the
//    tail past the newest compaction record, bounded by the residency
//    cap — issue #135);
// 2. live appends evict the OLDEST resident records, so a hidden range
//    stays resident while some of the records it covers slide out;
// 3. a mid-turn TOOL-CALL phase overflows the window: the guard refuses to
//    send, auto-compaction frees the window, the CLI prints the
//    continuation notice;
// 4. the notice builder walks the hidden ranges against the RESIDENT
//    entries — `seqOf(id)` is null for the evicted ids and the raw `!` on
//    continuation_notice.dart killed the whole continuation.
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  late FakeCliIO io;

  setUp(() {
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  test('over-window continuation survives a hidden range with evicted '
      'records (windowed marathon resume)', () async {
    const window32k = Model(
      id: 'test-model',
      api: 'test-api',
      provider: 'test-provider',
      baseUrl: 'https://example.test',
      contextWindow: 32768,
      maxTokens: 4096,
    );
    final shell = FakeShell(stdout: 'x' * 32800);
    // ONE env for the seed and the CLI: the seeded file must be visible
    // to the process under test.
    final env = MemoryExecutionEnv(cwd: '/work', shell: shell);

    // --- Seed the marathon session -------------------------------------
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final seed = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await seed.appendSessionName('crash-seed');
    // The classic compaction record anchors the windowed resume's
    // boundary walk; its kept id points forward (the seed messages below),
    // which classicTransform reads as "keep everything after me".
    await seed.appendCompaction(
      summary: 'earlier support session',
      firstKeptEntryId: 'pending',
      tokensBefore: 0,
    );
    // 620 resident records: past the 600-record residency cap, so the
    // first live append evicts the oldest — the head of the hidden range.
    // Each stays tiny so the PROJECTED context (markers) stays under the
    // compaction trigger: the overflow must happen mid-turn, not pre-flight.
    final seedIds = <String>[
      for (var i = 0; i < 620; i++)
        await seed.appendMessage(UserMessage.text('s$i')),
    ];
    // The structured fold from the support session: hides the whole seed
    // span. After eviction the range record is STILL resident while its
    // oldest covered records are not — the starvation that fed the `!`.
    await seed.appendHiddenRange(recordIds: seedIds);
    // A tail so the hidden range itself is never the eviction candidate.
    for (var i = 0; i < 30; i++) {
      await seed.appendMessage(UserMessage.text('tail $i'));
    }

    // Session-start memory maintenance is due on a fresh env (no stamp);
    // suppress it so the scripted turns feed only the turn under test
    // (same pattern as agent_cli_test).
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');

    // --- Drive the real CLI against the windowed resume ----------------
    final fake = FakeStreamFunction([
      // 1. Mid-turn TOOL-CALL phase: three tool calls whose outputs
      //    (~8200 tokens each) balloon the next request past the window —
      //    the support incident's shape.
      toolTurn([
        ToolCall(
          id: 'c1',
          name: 'bash',
          arguments: const {'command': 'cat a.log'},
        ),
        ToolCall(
          id: 'c2',
          name: 'bash',
          arguments: const {'command': 'cat b.log'},
        ),
        ToolCall(
          id: 'c3',
          name: 'bash',
          arguments: const {'command': 'cat c.log'},
        ),
      ]),
      // 2. Consumed by the loop's mid-run relief attempt.
      textTurn('S'),
      // 3. Consumed as the post-run compaction summary.
      textTurn('S'),
      // 4. The continuation turn's final answer — only reachable when the
      //    notice builds without crashing.
      textTurn('continued after compaction'),
    ]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: window32k,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        // The windowed marathon resume (`fa --session crash-seed`).
        sessionName: 'crash-seed',
        providerKind: 'openai-completions',
        skillsAccess: SkillsAccess.granted,
        compactionEngine: CompactionEngine.classic,
      ),
      io: io,
      streamFunction: fake.call,
    );
    final run = cli.run();

    io.sendLine('go');
    await waitForIt(
      () => fake.calls >= 4 && !cli.isBusy,
      reason: 'auto-continuation after guard + compaction on the '
          'windowed resume',
    );
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    // The guard fired and the compaction ran…
    expect(output, contains('note: Context window exhausted'));
    expect(output, contains('auto-compacted; continuing'));
    // …and the turn CONTINUED to its final answer — on main it dies here
    // with a raw "Null check operator used on a null value" (the notice
    // builder asserts on an evicted record id).
    expect(output, isNot(contains('Null check operator')));
    expect(output, contains('continued after compaction'));

    // The turn kept living in the RESUMED session (653 seeded records and
    // counting) — not in some fresh file.
    final repoAfter = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final resumedMeta = await repoAfter.list(cwd: '/work');
    final session = await repoAfter.open(resumedMeta.first);
    final entries = await session.getEntries();
    expect(entries.length, greaterThan(653));

    // The continuation notice names the recoverables it could still see:
    // the hidden range is resident, so the notice carries the
    // compact_expand hint even though its oldest covered records slid out.
    final notice = entries
        .whereType<MessageRecord>()
        .map((r) => r.message)
        .whereType<UserMessage>()
        .last;
    final text = notice.content as String;
    expect(text, contains('<system-notice>'));
    expect(text, contains('context-window guard'));
    expect(text, contains('recoverable via compact_expand'));
  });
}

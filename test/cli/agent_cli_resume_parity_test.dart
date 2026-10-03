// gh-968 — CLI session resume: same-point continuation.
//
// Interactive resume, headless continuation and the live loop's
// between-turn rebuild share ONE session assembly: the windowed walk over
// the session records with the PARITY budget (effective window −
// system-prompt/tool-schema overhead − compaction reserve). The old walk
// budget priced the transcript alone against the window, so a resume
// materialized MORE context than the live loop carried before exit (the
// reported `127%/200k` footer) and tripped the over-window guard /
// auto-compaction on a fresh resume.
import 'dart:math' as math;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

const _window = 32768;
const _reserve = 8192;
// CompactionSettings.forWindow(32768): reserve = min(16384, window ~/ 4).
final _threshold = _window - _reserve;

Model get _model => const Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: _window,
  maxTokens: 4096,
);

void main() {
  late FakeCliIO io;

  setUp(() {
    io = FakeCliIO();
  });
  tearDown(() => io.close());

  Future<MemoryExecutionEnv> freshEnv() async {
    final env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
    // Suppress session-start memory maintenance (same pattern as
    // agent_cli_test) so the scripted turns feed only the turn under test.
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');
    return env;
  }

  /// Seeds a never-compacted session of [count] uniform messages priced
  /// ~[textChars] / 4 tokens each.
  Future<void> seedFlat(
    MemoryExecutionEnv env,
    String name,
    int count, {
    int textChars = 4000,
  }) async {
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final seed = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await seed.appendSessionName(name);
    for (var i = 0; i < count; i++) {
      await seed.appendMessage(UserMessage.text('m$i ${'a' * textChars}'));
    }
  }

  /// Seeds a session with a compaction boundary: [oldCount] dropped
  /// messages, then the boundary naming the first kept message, then
  /// [keptCount] live messages — the classic post-compaction shape.
  Future<void> seedWithBoundary(
    MemoryExecutionEnv env,
    String name,
    int oldCount,
    int keptCount, {
    int textChars = 4000,
  }) async {
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final seed = await repo.create(
      JsonlSessionCreateOptions(cwd: '/work', metadata: {'agent': 'cli'}),
    );
    await seed.appendSessionName(name);
    for (var i = 0; i < oldCount; i++) {
      await seed.appendMessage(UserMessage.text('old$i ${'a' * textChars}'));
    }
    // The first kept message must exist before the boundary names it.
    final firstKept = await seed.appendMessage(
      UserMessage.text('kept0 ${'a' * textChars}'),
    );
    await seed.appendCompaction(
      summary: 'earlier support session',
      firstKeptEntryId: firstKept,
      tokensBefore: 99999,
    );
    for (var i = 1; i < keptCount; i++) {
      await seed.appendMessage(UserMessage.text('kept$i ${'a' * textChars}'));
    }
  }

  AgentCli interactiveCli(
    MemoryExecutionEnv env,
    FakeStreamFunction stream, {
    int? contextWindowCap,
    CompactionSettings? compactionSettings,
  }) => AgentCli(
    config: AgentCliConfig(
      model: _model,
      apiKey: '[REDACTED:Sensitive Value]',
      env: env,
      sessionRoot: '/sessions',
      sessionName: 'parity-target',
      providerKind: 'openai-completions',
      skillsAccess: SkillsAccess.granted,
      compactionEngine: CompactionEngine.classic,
      contextWindowCap: contextWindowCap,
      compactionSettings: compactionSettings,
    ),
    io: io,
    streamFunction: stream.call,
  );

  AgentCli headlessCli(
    MemoryExecutionEnv env,
    FakeStreamFunction stream, {
    int? contextWindowCap,
    CompactionSettings? compactionSettings,
  }) => AgentCli(
    config: AgentCliConfig(
      model: _model,
      apiKey: '[REDACTED:Sensitive Value]',
      env: env,
      sessionRoot: '/sessions',
      sessionName: 'parity-target',
      providerKind: 'openai-completions',
      skillsAccess: SkillsAccess.granted,
      compactionEngine: CompactionEngine.classic,
      contextWindowCap: contextWindowCap,
      compactionSettings: compactionSettings,
    ),
    io: io,
    streamFunction: stream.call,
  );

  /// Drives one interactive turn ('go' → text reply) over a resumed
  /// session and returns the FIRST request context — the assembled
  /// resume projection plus the prompt message.
  Future<Context> resumeAndTurn(AgentCli cli, FakeStreamFunction stream) async {
    final run = cli.run();
    io.sendLine('go');
    await waitForIt(
      () => stream.calls >= 1 && !cli.isBusy,
      reason: 'the resumed session answers one turn',
    );
    io.sendLine('/exit');
    await run;
    return stream.contexts.first;
  }

  /// Role + text signature of a projected message list — the AC-R0
  /// token-for-token comparison basis.
  List<String> signatures(Context context) => [
    for (final message in context.messages)
      switch (message) {
        UserMessage() =>
          'user:${message.content is String ? message.content : (message.content as List).map((b) => b is TextContent ? b.text : 'image').join('|')}',
        AssistantMessage() =>
          'assistant:${message.content.map((b) => b is TextContent ? b.text : 'other').join('|')}',
        ToolResultMessage(:final toolCallId) => 'tool:$toolCallId',
        _ => message.runtimeType.toString(),
      },
  ];

  /// The unanchored system-prompt/tool-schema overhead of the harness
  /// CLI, measured off a captured request (≈ 8.5k estimated tokens).
  int overheadOf(Context context) => estimateRequestOverheadTokens(
    context.systemPrompt,
    context.tools ?? const [],
  );

  int transcriptTokens(Context context) =>
      estimateContextTokens(context.messages).tokens;

  int requestTokens(Context context) =>
      transcriptTokens(context) + overheadOf(context);

  test(
    'IT-NOGUARD (AC-R2, invariant R2): fills at ~50/90/99% of the '
    'compaction threshold resume with the FULL projection — no guard, no '
    'auto-compaction',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      // Probe: measure the CLI's own overhead off one small resume, and
      // reuse this run as the ~50% fill. The meter basis = transcript +
      // overhead, so a transcript of f × threshold − overhead reads f.
      final env = await freshEnv();
      await seedFlat(env, 'parity-target', 4);
      var stream = FakeStreamFunction([textTurn('ok')]);
      final probe = await resumeAndTurn(interactiveCli(env, stream), stream);
      final overhead = overheadOf(probe);
      // The small resume carried the whole 4-message session.
      expect(probe.messages, hasLength(5));
      expect(requestTokens(probe), lessThanOrEqualTo(_threshold));

      // Fill sizes derived from the measured overhead: the request basis
      // lands within one message of the target fill.
      int countFor(double fill) =>
          ((fill * _threshold - overhead) / 1000).floor().clamp(1, 100);
      for (final (fill, count) in [
        (0.9, countFor(0.9)),
        (0.99, countFor(0.99)),
      ]) {
        final fillEnv = await freshEnv();
        await seedFlat(fillEnv, 'parity-target', count);
        io = FakeCliIO();
        stream = FakeStreamFunction([textTurn('ok')]);
        final context = await resumeAndTurn(
          interactiveCli(fillEnv, stream),
          stream,
        );
        final estimate = requestTokens(context);
        expect(
          estimate,
          closeTo(fill * _threshold, 1100),
          reason: 'fill $fill: request basis $estimate',
        );
        // Under the compaction threshold and the guard…
        expect(estimate, lessThanOrEqualTo(_threshold));
        // …and the resume carried the WHOLE session (no trim, no
        // auto-compaction — full parity with the pre-exit transcript).
        expect(context.messages, hasLength(count + 1));
        final output = io.out.toString();
        expect(output, isNot(contains('Context window exhausted')));
        expect(output, isNot(contains('auto-compacted')));
      }
    },
  );

  test(
    'E1 / 127% regression (IT-PARITY): a never-compacted marathon far '
    'over the window resumes at the parity bound — no guard, no '
    'auto-compaction, older history lazy',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      // The marathon size derives from the MEASURED platform overhead
      // (issue #1151: builtin-skills metadata is permanent prompt
      // overhead; a frozen seed left only a ~50-token margin under the
      // threshold). A small probe resume captures the request basis the
      // meter uses; the transcript then seeds ~1.1k tokens PAST the
      // parity budget so the trim genuinely fires.
      final probeEnv = await freshEnv();
      await seedFlat(probeEnv, 'parity-target', 2);
      var stream = FakeStreamFunction([textTurn('ok')]);
      final probe = await resumeAndTurn(
        interactiveCli(probeEnv, stream),
        stream,
      );
      final overhead = overheadOf(probe);
      expect(probe.messages, hasLength(3));
      expect(requestTokens(probe), lessThanOrEqualTo(_threshold));

      // OLD budget (window − reserve, transcript-only) kept ~24.5k
      // resident; the meter (adding the overhead) read past 100% →
      // guard + auto-compaction on a fresh resume. The parity budget
      // must keep the meter at/below the threshold instead.
      final budgetCount = ((_threshold - overhead - 1100) / 1000).floor();
      expect(budgetCount, greaterThan(4), reason: 'probe overhead sane');
      final env = await freshEnv();
      await seedFlat(env, 'parity-target', budgetCount + 16);
      io = FakeCliIO();
      stream = FakeStreamFunction([textTurn('ok')]);
      final cli = interactiveCli(env, stream);
      final context = await resumeAndTurn(cli, stream);

      final output = io.out.toString();
      expect(output, isNot(contains('Context window exhausted')));
      expect(output, isNot(contains('auto-compacted')));
      expect(output, isNot(contains('Compacting context')));

      // The request basis (the meter's own numbers) sits at/below the
      // compaction threshold — strictly below the window.
      final estimate = requestTokens(context);
      expect(estimate, lessThanOrEqualTo(_threshold));
      expect(estimate, lessThan(_window));
      // The budget stop kept older history on disk: the projection is
      // the tail, not the whole file (laziness preserved).
      expect(context.messages.length, lessThan(budgetCount + 17));
      // The LIVE tail is intact — the prompt rides the request.
      expect((context.messages.last as UserMessage).content, 'go');
    },
  );

  test(
    'E4: a contextWindowCap below the catalog window clamps the parity '
    'budget the same way (headless continuation, 200k model capped to 32k)',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      final env = await freshEnv();
      await seedFlat(env, 'parity-target', 100);
      final stream = FakeStreamFunction([textTurn('ok')]);
      final cli = headlessCli(env, stream, contextWindowCap: 32768);
      final exit = await cli.runHeadless('go');
      expect(exit, 0);

      final output = io.out.toString();
      expect(output, isNot(contains('Context window exhausted')));
      expect(output, isNot(contains('auto-compacted')));
      final context = stream.contexts.first;
      expect(requestTokens(context), lessThanOrEqualTo(32768 - 8192));
      expect(context.messages.length, lessThan(101));
    },
  );

  test(
    'AC-R3 wiring: the resume budget honours a pinned compactionSettings '
    'override (the ACTIVE reserve, not forWindow)',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      // ~18k transcript tokens: over the default-reserve budget
      // (32768 − 8192 − overhead ≈ 16k) but under the override's
      // (32768 − 4096 − overhead ≈ 20k).
      final defaultEnv = await freshEnv();
      await seedFlat(defaultEnv, 'parity-target', 18);
      final defaultStream = FakeStreamFunction([textTurn('ok')]);
      final defaultExit = await headlessCli(
        defaultEnv,
        defaultStream,
      ).runHeadless('go');
      expect(defaultExit, 0);
      final trimmed = defaultStream.contexts.first.messages.length;
      expect(trimmed, lessThan(21), reason: 'the default reserve trims');

      io = FakeCliIO();
      final overrideEnv = await freshEnv();
      await seedFlat(overrideEnv, 'parity-target', 18);
      final overrideStream = FakeStreamFunction([textTurn('ok')]);
      final overrideExit = await headlessCli(
        overrideEnv,
        overrideStream,
        compactionSettings: const CompactionSettings(
          enabled: true,
          reserveTokens: 4096,
          keepRecentTokens: 8192,
        ),
      ).runHeadless('go');
      expect(overrideExit, 0);
      final kept = overrideStream.contexts.first.messages.length;

      // The smaller reserve keeps the whole file — the budget moved with
      // the ACTIVE settings.
      expect(kept, greaterThan(trimmed));
      expect(kept, 19);
    },
  );

  test(
    'IT-EQUIV (AC-R0): continuing a session headless and resuming it '
    'interactively produce IDENTICAL projections — boundary path',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      // Boundary path: the newest compaction boundary is reachable, so
      // the walk reconstructs the classic post-compaction projection.
      final headlessEnv = await freshEnv();
      await seedWithBoundary(headlessEnv, 'parity-target', 10, 10);
      final headlessStream = FakeStreamFunction([textTurn('ok')]);
      final headlessExit = await headlessCli(
        headlessEnv,
        headlessStream,
      ).runHeadless('go');
      expect(headlessExit, 0);

      io = FakeCliIO();
      final interactiveEnv = await freshEnv();
      await seedWithBoundary(interactiveEnv, 'parity-target', 10, 10);
      final interactiveStream = FakeStreamFunction([textTurn('ok')]);
      final interactiveContext = await resumeAndTurn(
        interactiveCli(interactiveEnv, interactiveStream),
        interactiveStream,
      );

      expect(
        signatures(headlessStream.contexts.first),
        signatures(interactiveContext),
      );
      // The boundary actually shaped the projection: the 10 old
      // messages are replaced by the summary, not replayed.
      final sigs = signatures(headlessStream.contexts.first);
      expect(sigs.where((s) => s.startsWith('user:old')), isEmpty);
      expect(sigs.where((s) => s.startsWith('user:kept')), hasLength(10));
    },
  );

  test(
    'IT-EQUIV (AC-R0): headless continuation and interactive resume over '
    'a boundary-less marathon trim to the SAME record (budget path)',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      // Marathon size derives from the MEASURED overhead (issue #1151:
      // builtin-skills metadata is permanent platform overhead — a
      // frozen seed sat on the record-bucket boundary). The two hosts'
      // prompts legitimately differ (interactive adds the mailbox
      // section), so the parity contract asserted here is the trim
      // FORMULA: both sides keep the newest records, never divergent
      // content — the interactive tail is a suffix of the headless tail.
      final headlessEnv = await freshEnv();
      await seedFlat(headlessEnv, 'parity-target', 40);
      final headlessStream = FakeStreamFunction([textTurn('ok')]);
      final headlessExit = await headlessCli(
        headlessEnv,
        headlessStream,
      ).runHeadless('go');
      expect(headlessExit, 0);

      io = FakeCliIO();
      final interactiveEnv = await freshEnv();
      await seedFlat(interactiveEnv, 'parity-target', 40);
      final interactiveStream = FakeStreamFunction([textTurn('ok')]);
      final interactiveContext = await resumeAndTurn(
        interactiveCli(interactiveEnv, interactiveStream),
        interactiveStream,
      );
      final headlessMessages = headlessStream.contexts.first.messages;
      final interactiveMessages = interactiveContext.messages;

      // Both trims genuinely fired (the file is ~5× the parity budget)…
      expect(headlessMessages.length, lessThan(41));
      expect(interactiveMessages.length, lessThan(41));
      // …both hosts obey the same budget shape: the request basis at or
      // under the threshold…
      expect(
        requestTokens(headlessStream.contexts.first),
        lessThanOrEqualTo(_threshold),
      );
      expect(requestTokens(interactiveContext), lessThanOrEqualTo(_threshold));
      // …and the kept tails agree record-for-record: the interactive
      // projection ends with exactly the records the headless one kept
      // (same drop-oldest rule, same newest-N tail — divergent content
      // would break same-point continuation).
      final shared = math.min(
        headlessMessages.length,
        interactiveMessages.length,
      );
      expect(
        signatures(
          interactiveContext,
        ).sublist(interactiveMessages.length - shared),
        signatures(
          headlessStream.contexts.first,
        ).sublist(headlessMessages.length - shared),
      );
    },
  );

  test(
    'IT-DOUBLE-RESUME (E5): resume → one short turn → resume again keeps '
    'the fill idempotent — the delta is exactly the appended turn, no '
    'ratchet-up across cycles',
    timeout: const Timeout(Duration(minutes: 5)),
    () async {
      final env = await freshEnv();
      await seedFlat(env, 'parity-target', 8);
      final firstStream = FakeStreamFunction([textTurn('done')]);
      final firstContext = await resumeAndTurn(
        interactiveCli(env, firstStream),
        firstStream,
      );
      final first = requestTokens(firstContext);

      // Second resume over the same (now longer) session.
      io = FakeCliIO();
      final secondStream = FakeStreamFunction([textTurn('again')]);
      final secondContext = await resumeAndTurn(
        interactiveCli(env, secondStream),
        secondStream,
      );
      final second = requestTokens(secondContext);

      // 'go' (1) + 'done' (1): the only projection delta; a couple of
      // tokens of slack for markers.
      expect(second, greaterThanOrEqualTo(first + 2));
      expect(second, lessThanOrEqualTo(first + 8));
      // No ratchet: still under the compaction threshold.
      expect(second, lessThanOrEqualTo(_threshold));
    },
  );
}

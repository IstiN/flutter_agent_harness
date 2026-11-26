// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-2411 × gh-2423 (C3) — the honest context notices inside the
/// SOFT-WINDOW regime: where the two notices sit relative to the regime
/// branches of `_maybeAutoCompact` (agent_cli_compaction.dart).
///
/// - The near-limit notice is SILENT while the regime is active: the
///   regime's own ONE warning per session is the only token-basis line the
///   session gets — even when the request estimate sits inside the
///   near-limit band on the notice's OWN predicate ([nearLimitReached]).
///   (The two bases can disagree in the regime: the regime prices the
///   calibrated overhead plus the RAW newest user turn, the request
///   estimate scales the whole request by the calibration.)
/// - The control: the same band OUTSIDE the regime still emits exactly one
///   notice per compaction cycle (the general contract is
///   `agent_cli_context_notices_test.dart` IT-near-limit).
/// - The regime's hide-only relief reports its hide exactly once: the
///   emergency tier's own post-hide notice, never a second one from the
///   caller — and never for a pass that hid nothing.
///
/// Fixture: the gh-241 seam (`tinyPrompt` + `tinyTools`), a MEASURED
/// session, the classic engine (no record tags — the recorded request IS
/// the trigger's basis). Every prompt is AIMED: the fixed overhead is
/// measured from a real request first and the ballast is solved against
/// the estimator itself, so the regime and the band are exact. Every test
/// then pins its own preconditions with the exported predicates
/// ([softWindowRegime], [nearLimitReached]) — a drifted fixture fails on
/// its precondition, never silently.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

const _warning = 'is below the fixed request overhead';
const _nearLimit =
    'update your working set with decisions, red tests and '
    'next steps, then KEEP WORKING';
const _postHide = 'records hidden; context now';

/// The near-limit fixture: window 40k, reserve 100 → trigger 39,900,
/// near-limit band [34,000, 39,900).
const _window = 40000;
const _settings = CompactionSettings(
  enabled: true,
  reserveTokens: 100,
  keepRecentTokens: 200,
);

/// The request estimate on the compaction trigger's own basis
/// (`_liveRequestTokens`: transcript + the request overhead, scaled by the
/// session's calibration).
int _requestTokens(Context context, OverheadCalibration calibration) =>
    estimateRequestTokens(
      context.messages,
      systemPrompt: context.systemPrompt,
      tools: context.tools ?? const [],
      calibration: calibration,
    );

/// Whether the soft-window regime holds for the recorded [context].
bool _regimeOf(
  Context context, {
  required int window,
  required CompactionSettings settings,
  required OverheadCalibration calibration,
}) => softWindowRegime(
  messages: context.messages,
  systemPrompt: context.systemPrompt,
  tools: context.tools ?? const [],
  window: window,
  reserveTokens: settings.reserveTokens,
  calibration: calibration,
);

/// A prompt whose transcript estimate is [tokens] — the estimator's own
/// number, solved by correction (`x` ballast after [head]).
String _aimedPrompt(String head, int tokens) {
  var chars = tokens * 4;
  for (var i = 0; i < 6; i++) {
    final estimate = estimateTokens(UserMessage.text('$head${'x' * chars}'));
    if (estimate == tokens) break;
    chars -= 4 * (estimate - tokens);
    if (chars < 0) chars = 0;
  }
  return '$head${'x' * chars}';
}

/// Every context notice of [context] containing [needle], oldest first.
List<String> _notices(Context context, String needle) => [
  for (final message in context.messages.whereType<UserMessage>())
    if (isContextNoticeText(userMessageText(message.content)) &&
        userMessageText(message.content).contains(needle))
      userMessageText(message.content),
];

/// The near-limit notices [context] was DELIVERED (after its own prompt):
/// everything before the prompt is replayed history.
int _deliveredAfterPrompt(Context context) {
  final prompt = context.messages.lastIndexWhere(
    (message) =>
        message is UserMessage &&
        !isContextNoticeText(userMessageText(message.content)),
  );
  expect(prompt, greaterThanOrEqualTo(0), reason: 'the request has a prompt');
  return _notices(
    Context(
      systemPrompt: context.systemPrompt,
      messages: context.messages.sublist(prompt + 1),
      tools: context.tools,
    ),
    _nearLimit,
  ).length;
}

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() async {
    env = MemoryExecutionEnv(cwd: '/work');
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  /// The regime fixture: the gh-241 seam, a MEASURED session (the relief
  /// and the skips act on measured estimates only), classic engine.
  AgentCli buildCli(
    FakeStreamFunction stream, {
    required int window,
    required CompactionSettings settings,
    required OverheadCalibration calibration,
    String sessionName = 'notices-target',
  }) => AgentCli(
    config: AgentCliConfig(
      systemPrompt: tinyPrompt,
      runtimeTools: tinyTools(const ['read', 'bash']),
      model: Model(
        id: 'tiny-window',
        api: 'test-api',
        provider: 'test-provider',
        baseUrl: 'https://example.test',
        contextWindow: window,
        maxTokens: 4096,
      ),
      apiKey: '[REDACTED:Sensitive-Value]',
      env: env,
      homeDir: '/home',
      sessionRoot: '/sessions',
      sessionName: sessionName,
      providerKind: 'openai-completions',
      compactionEngine: CompactionEngine.classic,
      compactionSettings: settings,
      initialOverheadCalibration: calibration,
    ),
    io: io,
    streamFunction: stream.call,
  );

  /// One HEADLESS probe run of the fixture: the fixed request overhead
  /// (system prompt + tool schemas) its request really carried.
  Future<int> headlessOverhead({
    required int window,
    required CompactionSettings settings,
    required OverheadCalibration calibration,
  }) async {
    final probe = FakeStreamFunction([textTurn('ok')]);
    final cli = buildCli(
      probe,
      window: window,
      settings: settings,
      calibration: calibration,
      sessionName: 'notices-probe',
    );
    expect(await cli.runHeadless('hello'), 0, reason: io.out.toString());
    // The probe left its own lines on the shared output: the run under
    // test starts from a clean page.
    io.out.clear();
    final context = probe.contexts.single;
    return estimateRequestOverheadTokens(
      context.systemPrompt,
      context.tools ?? const [],
    );
  }

  /// Every session record of the fixture's session root (the probe's
  /// tiny session carries neither hides nor notices).
  Future<List<SessionRecord>> allEntries() async {
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final entries = <SessionRecord>[];
    for (final metadata in await repo.list(cwd: '/work')) {
      entries.addAll(await (await repo.open(metadata)).getEntries());
    }
    return entries;
  }

  Future<String> diagnosticLog() async =>
      (await env.readTextFile('/home/.fah/logs/fa.log')).valueOrNull ?? '';

  test(
    'gh-2411 × gh-2423: in the soft-window regime the near-limit notice '
    'is SILENT — the regime\'s ONE warning is the only line, even with the '
    'estimate inside the near-limit band',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      // The session is calibrated at the 0.6 floor (a provider that
      // reported far less than the heuristic): on the regime's own basis
      // (calibrated overhead + the RAW prompt) it is deep in the regime,
      // while the request estimate — 0.6 × the whole request — is aimed
      // at 37k: inside the band and under the window. Nothing can be
      // trimmed, the request goes as is, and NO notice may claim that
      // "compaction will fold older records".
      const calibration = OverheadCalibration(0.6, measured: true);
      final overhead = await headlessOverhead(
        window: _window,
        settings: _settings,
        calibration: calibration,
      );
      final stream = FakeStreamFunction([textTurn('answered as is')]);
      final cli = buildCli(
        stream,
        window: _window,
        settings: _settings,
        calibration: calibration,
      );

      final exitCode = await cli.runHeadless(
        _aimedPrompt('count the words ', (37000 / 0.6).round() - overhead),
      );

      final out = io.out.toString();
      expect(exitCode, 0, reason: out);
      expect(stream.calls, 1, reason: 'one request, the final answer\n$out');
      // Precondition — the fixture IS in the regime AND inside the
      // near-limit band on the notice's own predicate.
      final request = stream.contexts.single;
      final tokens = _requestTokens(request, calibration);
      expect(
        _regimeOf(
          request,
          window: _window,
          settings: _settings,
          calibration: calibration,
        ),
        isTrue,
        reason: 'precondition: the soft-window regime holds (≈$tokens)',
      );
      expect(
        nearLimitReached(tokens: tokens, window: _window, settings: _settings),
        isTrue,
        reason:
            'precondition: the request is in the near-limit band '
            '(≈$tokens)',
      );
      expect(tokens, lessThan(_window), reason: 'the request is sendable');
      // The regime's own ONE warning (the post-run fold sights the
      // regime)…
      expect(_warning.allMatches(out), hasLength(1), reason: out);
      // …and no near-limit notice, on either surface.
      expect(
        _nearLimit.allMatches(out),
        isEmpty,
        reason: 'the near-limit notice is silent in the regime:\n$out',
      );
      expect(_notices(request, _nearLimit), isEmpty);
      expect(
        (await allEntries()).whereType<HiddenRangeRecord>(),
        isEmpty,
        reason: 'no pass ran',
      );
    },
  );

  test(
    'gh-2411 × gh-2423 — the control: the same near-limit band OUTSIDE '
    'the regime emits exactly ONE notice per compaction cycle, riding the '
    'next request last',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      // Same window and band; the session is calibrated at 1.0 and the
      // second prompt is aimed so the request sits at 37k — inside the
      // band but under the trigger on the regime's basis too: NOT the
      // regime. Prompts 2 and 3 both sight the band; the latch lets
      // exactly one notice through.
      const calibration = OverheadCalibration(1.0, measured: true);
      final stream = FakeStreamFunction([
        textTurn('first answer'),
        textTurn('second answer'),
        textTurn('third answer'),
      ]);
      final cli = buildCli(
        stream,
        window: _window,
        settings: _settings,
        calibration: calibration,
      );

      final run = cli.run();
      await waitForIt(() => cli.agent.state.tools.isNotEmpty);
      io.sendLine('hello');
      await waitForIt(
        () => stream.calls >= 1 && !cli.isBusy,
        reason: 'turn 1 settles',
      );
      // Aim prompt 2 from what the live session really carries.
      final opening = stream.contexts.first;
      final overhead = estimateRequestOverheadTokens(
        opening.systemPrompt,
        opening.tools ?? const [],
      );
      final carried = estimateContextTokens(cli.agent.state.messages).tokens;
      io.sendLine(_aimedPrompt('count the words ', 37000 - overhead - carried));
      await waitForIt(
        () => stream.calls >= 2 && !cli.isBusy,
        reason: 'turn 2 settles',
      );
      io.sendLine('and again');
      await waitForIt(
        () => stream.calls >= 3 && !cli.isBusy,
        reason: 'turn 3 settles',
      );
      io.sendLine('/exit');
      await run;

      final out = io.out.toString();
      expect(stream.calls, 3, reason: out);
      // Precondition — inside the band, OUTSIDE the regime.
      final second = stream.contexts[1];
      final tokens = _requestTokens(second, calibration);
      expect(
        _regimeOf(
          second,
          window: _window,
          settings: _settings,
          calibration: calibration,
        ),
        isFalse,
        reason: 'precondition: not the regime (≈$tokens)',
      );
      expect(
        nearLimitReached(tokens: tokens, window: _window, settings: _settings),
        isTrue,
        reason:
            'precondition: the request is in the near-limit band '
            '(≈$tokens)',
      );
      expect(
        nearLimitReached(
          tokens: _requestTokens(stream.contexts[2], calibration),
          window: _window,
          settings: _settings,
        ),
        isTrue,
        reason: 'precondition: the third boundary sights the band too',
      );
      // Not the regime ⇒ no regime warning at all.
      expect(_warning.allMatches(out), isEmpty, reason: out);
      // Exactly one notice across the sightings of the band…
      expect(
        _nearLimit.allMatches(out),
        hasLength(1),
        reason: 'one notice per compaction cycle:\n$out',
      );
      // …delivered to the model ONCE, and as fresh text only ever on the
      // request AFTER the cycle: the sighting is the post-run boundary of
      // turn 2 (the pre-flight of turn 2 measured the transcript BEFORE
      // the fat prompt joined it — IT-near-limit: "the post-run notice
      // rides the NEXT prompt"), so request 2 carried none, request 3
      // carries the one fresh delivery, and no later boundary delivers
      // another.
      expect(
        [for (final context in stream.contexts) _deliveredAfterPrompt(context)],
        [0, 0, 1],
        reason: 'one fresh delivery, ever',
      );
      final third = stream.contexts[2];
      final last = third.messages.last;
      expect(last, isA<UserMessage>(), reason: 'it rides its request LAST');
      expect(
        userMessageText((last as UserMessage).content),
        contains(_nearLimit),
      );
    },
  );

  group('the regime\'s hide-only relief (window 60k, reserve 3,000)', () {
    const window = 60000;
    const settings = CompactionSettings(
      enabled: true,
      reserveTokens: 3000,
      keepRecentTokens: 200,
    );
    const calibration = OverheadCalibration(1.0, measured: true);

    /// The prompt opens the session at ≈57.6k — the regime (over the
    /// 57k trigger, under the window); [reads] reads of ONE file stay
    /// under the window; the fat final reply pushes the transcript ≈3k
    /// past it — so the POST-RUN boundary runs the regime's LM-free
    /// relief ([_softWindowRelief] → the emergency tier).
    Future<({FakeStreamFunction stream, String out, String log})> runRelief(
      int reads,
    ) async {
      final overhead = await headlessOverhead(
        window: window,
        settings: settings,
        calibration: calibration,
      );
      env.writeFile('same.txt', List.filled(4, 'z' * 50).join('\n'));
      List<AssistantMessageEvent> read(String id) => toolTurn([
        ToolCall(id: id, name: 'read', arguments: {'path': 'same.txt'}),
      ]);
      final stream = FakeStreamFunction([
        for (var i = 1; i <= reads; i++) read('t$i'),
        textTurn('done: ${'y' * 12000}'),
      ]);
      final cli = buildCli(
        stream,
        window: window,
        settings: settings,
        calibration: calibration,
      );
      final exitCode = await cli.runHeadless(
        _aimedPrompt('count the words ', 57600 - overhead),
      );
      final out = io.out.toString();
      final log = await diagnosticLog();
      expect(exitCode, 0, reason: '$out\n--- LOG ---\n$log');
      return (stream: stream, out: out, log: log);
    }

    test(
      'gh-2411 × gh-2423: a hide pass in the regime (the post-run '
      'relief) reports its hide EXACTLY once — the emergency tier\'s own '
      'post-hide notice, persisted as a record',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        // Six reads of ONE file: only the newest 8 ledger entries are a
        // protected tail, so the relief's dedup pass folds the older
        // copies of the path.
        final run = await runRelief(6);
        final stream = run.stream;
        final why = '${run.out}\n--- LOG ---\n${run.log}';
        expect(stream.calls, 7, reason: 'six reads, the final answer\n$why');
        // Precondition — in the regime, every request sendable (the loop
        // guard never fired mid-run).
        final opening = _requestTokens(stream.contexts.first, calibration);
        expect(
          opening,
          greaterThanOrEqualTo(window - settings.reserveTokens),
          reason: 'precondition: over the trigger (≈$opening)\n$why',
        );
        for (final context in stream.contexts) {
          expect(
            _requestTokens(context, calibration),
            lessThan(window),
            reason: 'no over-window request\n$why',
          );
        }
        expect(_warning.allMatches(run.out), hasLength(1), reason: why);
        // ONE relief pass ran (its own log line)…
        expect(
          'over-window relief start sid='.allMatches(run.log),
          hasLength(1),
          reason: why,
        );
        // …hid records…
        final entries = await allEntries();
        expect(
          entries.whereType<HiddenRangeRecord>(),
          isNotEmpty,
          reason: 'precondition: the pass hid\n$why',
        );
        // …and is reported EXACTLY once, with real numbers.
        final lines = run.out
            .split('\n')
            .where((line) => line.contains(_postHide))
            .toList();
        expect(
          lines,
          hasLength(1),
          reason:
              'exactly one post-hide notice for the one hide pass:'
              '\n${run.out}',
        );
        final notice = RegExp(
          r'^compacted: (\d+) records hidden; context now ≈(\d+)/60000 '
          r'\(was ≈(\d+)\); (.*)$',
        ).firstMatch(lines.single)!;
        expect(int.parse(notice.group(1)!), greaterThan(0));
        expect(
          int.parse(notice.group(2)!),
          lessThan(int.parse(notice.group(3)!)),
          reason: 'a hide frees context',
        );
        // The notice is persisted as a synthetic record, exactly once.
        final persisted = entries.whereType<MessageRecord>().where(
          (record) =>
              record.message is UserMessage &&
              userMessageText(
                (record.message as UserMessage).content,
              ).contains(_postHide),
        );
        expect(persisted, hasLength(1));
        // No near-limit notice anywhere in the run (every estimate sat at
        // or over the trigger).
        expect(_nearLimit.allMatches(run.out), isEmpty, reason: run.out);
      },
    );

    test(
      'gh-2411 × gh-2423: a regime relief that hides NOTHING prints no '
      'post-hide notice',
      timeout: const Timeout(Duration(minutes: 3)),
      () async {
        // A single read: the dedup pass has one group per path and the
        // newest user turn is protected — the pass hides nothing, so no
        // notice may claim a hide.
        final run = await runRelief(1);
        expect(
          run.stream.calls,
          2,
          reason: 'one read, the final answer\n${run.out}',
        );
        final entries = await allEntries();
        expect(
          entries.whereType<HiddenRangeRecord>(),
          isEmpty,
          reason: 'precondition: the pass hid nothing',
        );
        // The regime's relief RAN (its own log line and warning)…
        expect(
          'over-window relief start sid='.allMatches(run.log),
          hasLength(1),
          reason: run.log,
        );
        expect(_warning.allMatches(run.out), hasLength(1), reason: run.out);
        // …and reported no hide.
        expect(
          run.out.split('\n').where((line) => line.contains(_postHide)),
          isEmpty,
          reason: 'no hide ⇒ no post-hide notice:\n${run.out}',
        );
      },
    );
  });
}

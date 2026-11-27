// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-2423 C3 — IT-7/IT-8/IT-11 through a REAL booted CLI (fake stream,
/// memory env, the structured-observability fold fixture): every hide pass
/// that ran in the run prints exactly one honest post-hide notice with the
/// harness's numbers, the near-limit notice fires once per cycle below the
/// trigger, the model sees the notice as a synthetic user record, and the
/// HEP frames carry numbers only (AC6, AC7, AC12).
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

final _postHideLine = RegExp(
  r'^compacted: (\d+) records hidden; context now ≈(\d+)/(\d+) '
  r'\(was ≈(\d+)\); (.*)$',
  multiLine: true,
);
final _nearLimitLine = RegExp(
  r'^context ≈(\d+)% \(≈(\d+)/(\d+)\): update your working set with '
  r'decisions, red tests and next steps, then KEEP WORKING; compaction '
  r'will fold older records$',
  multiLine: true,
);

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() async {
    env = MemoryExecutionEnv(cwd: '/work', shell: FakeShell());
    await env.writeFile('/work/.fah/memory/.last_maintenance', '');
    io = FakeCliIO();
    // Three huge files, read one per turn (the structured-observability
    // fixture). #2416 merge: the slim manifest shrank the real CLI
    // prompt+manifest overhead from ≈19.2k to ≈8.8k estimated tokens
    // (measured via estimateRequestOverheadTokens), so both scenarios
    // below now write their own files: the IT-post-hide 40k run reads
    // FIVE 750-line files (request k ≈ 8.8k + (k−1) × 750 tokens — the
    // FIFTH read's request lands at ≈38.8k, inside the (38k trigger,
    // 40k window) fold band the settle funnel folds exactly once in),
    // and the IT-near-limit 55k run reads FOUR 1000-token files (the run
    // ends ≈48.8k, inside the near-limit band, under the hide trigger).
    for (var i = 1; i <= 5; i++) {
      env.writeFile('big$i.txt', List.filled(750, 'x' * 40).join('\n'));
    }
  });

  tearDown(() => io.close());

  /// The content-aware fake (judge → hide picks, hand-over/checkpoint →
  /// a text transfer, agent → the next `read`, then `done`), recording
  /// every agent request. [files] = how many big files the run reads
  /// before the `done` answer (see setUp for the per-scenario geometry).
  ({StreamFunction stream, List<Context> contexts}) foldRun({int files = 5}) {
    var nextFile = 1;
    final contexts = <Context>[];
    List<AssistantMessageEvent> answer(Context context) {
      final system = context.systemPrompt ?? '';
      final last = context.messages.last;
      final text = last is UserMessage ? userMessageText(last.content) : '';
      if (isHandOverCall(context)) {
        return textTurn(
          handOverReplyFor(context, text: 'checkpoint: the file counting'),
        );
      }
      if (system.contains('context-hygiene judge')) {
        return textTurn('[2, 3, 4, 5, 6, 7, 8, 9, 10, 11]');
      }
      if (text.contains('<conversation>') || system.contains('hand off')) {
        return textTurn('checkpoint: the file counting investigation');
      }
      contexts.add(
        Context(
          systemPrompt: context.systemPrompt,
          messages: List.of(context.messages),
          tools: context.tools,
        ),
      );
      if (nextFile > files) return textTurn('done: all files counted');
      final file = nextFile++;
      return toolTurn([
        ToolCall(
          id: 't$file',
          name: 'read',
          arguments: {'path': 'big$file.txt'},
        ),
      ]);
    }

    return (
      contexts: contexts,
      stream: (model, context, {cancelToken}) {
        final stream = AssistantMessageEventStream();
        for (final event in answer(context)) {
          stream.push(event);
        }
        stream.end();
        return stream;
      },
    );
  }

  AgentCli buildCli(StreamFunction stream, {int contextWindow = 40000}) =>
      AgentCli(
        config: AgentCliConfig(
          model: Model(
            id: 'tiny-window',
            api: 'test-api',
            provider: 'test-provider',
            baseUrl: 'https://example.test',
            contextWindow: contextWindow,
            maxTokens: 4096,
          ),
          apiKey: '[REDACTED:Sensitive-Value]',
          env: env,
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          compactionSettings: const CompactionSettings(
            enabled: true,
            reserveTokens: 2000,
            keepRecentTokens: 2000,
          ),
        ),
        io: io,
        streamFunction: stream,
      );

  Future<Session> openRunSession() async {
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final sessions = await repo.list(cwd: '/work');
    return repo.open(sessions.single);
  }

  test(
    'IT-post-hide: one honest notice per hide pass, real numbers, delivered '
    'to the model before its next request',
    timeout: const Timeout(Duration(seconds: 180)),
    () async {
      final run = foldRun();
      final frames = <String>[];
      final cli = buildCli(run.stream);
      final code = await cli.runHeadless(
        'count the words',
        hep: HepWriter(emit: frames.add, fahVersion: '1.0.0'),
      );
      expect(code, 0, reason: io.out.toString());
      final out = io.out.toString();
      final session = await openRunSession();
      final entries = await session.getEntries();
      // BOTH hide mechanisms count (a classic `hidden_range` pass or the
      // structured settle funnel's checkpoint — whichever the fixture's
      // pipeline picks).
      expect(
        hiddenRangeIdsIn(entries),
        isNotEmpty,
        reason: 'the fixture must really hide\n$out',
      );

      // The dim line: real harness numbers, N > 0, the context SHRANK,
      // the one window, one of the two card variants of the last clause.
      final lines = _postHideLine.allMatches(out).toList();
      expect(lines, isNotEmpty, reason: out);
      for (final line in lines) {
        final hidden = int.parse(line.group(1)!);
        final now = int.parse(line.group(2)!);
        final window = int.parse(line.group(3)!);
        final before = int.parse(line.group(4)!);
        expect(hidden, greaterThan(0));
        expect(window, 40000);
        expect(now, lessThan(before), reason: 'a hide frees context: $line');
        expect(
          line.group(5),
          anyOf(
            'your working set is pinned — continue',
            'no working set yet — write one now with working_set(text), '
                'then continue',
          ),
          reason: '$line',
        );
        expect(containsForbiddenContextPhrase(line.group(0)!), isFalse);
      }
      // The model wrote no working set in this fixture ⇒ the honest variant.
      expect(
        out,
        contains(
          'no working set yet — write one now with working_set(text), '
          'then continue',
        ),
      );

      // The model saw it: a synthetic user record ahead of a later request.
      final noticeText = 'records hidden; context now ≈';
      final seeing = run.contexts
          .where(
            (c) => c.messages.whereType<UserMessage>().any(
              (m) => userMessageText(m.content).contains(noticeText),
            ),
          )
          .toList();
      expect(seeing, isNotEmpty, reason: 'the notice must reach the model');
      for (final context in seeing) {
        for (final message in context.messages.whereType<UserMessage>()) {
          final text = userMessageText(message.content);
          if (!text.contains(noticeText)) continue;
          expect(text, startsWith('<system-notice>'));
          expect(isSyntheticUserText(text), isTrue);
        }
      }
      // …and it is persisted as a record (the transcript carries it).
      final persisted = entries
          .whereType<MessageRecord>()
          .where(
            (r) =>
                r.message is UserMessage &&
                userMessageText(
                  (r.message as UserMessage).content,
                ).contains(noticeText),
          )
          .length;
      expect(persisted, lines.length, reason: 'one record per notice');

      // HEP: one `context_notice` frame per notice, numbers only, at most
      // one post-hide frame per compaction bracket.
      final notices = frames
          .map(jsonDecode)
          .whereType<Map<String, dynamic>>()
          .where((f) => f['type'] == 'context_notice')
          .toList();
      final postHide = notices.where((f) => f['kind'] == 'post-hide');
      expect(postHide.length, lines.length, reason: '$frames');
      final starts = frames.where(
        (f) => f.contains('"type":"compaction_start"'),
      );
      expect(postHide.length, lessThanOrEqualTo(starts.length));
      for (final frame in [
        ...notices,
        ...frames
            .map(jsonDecode)
            .whereType<Map<String, dynamic>>()
            .where((f) => f['type'] == 'working_set'),
      ]) {
        expect(frame.containsKey('text'), isFalse);
        expect(jsonEncode(frame), isNot(contains('KEEP WORKING')));
        expect(frame['window'], 40000);
      }
    },
  );

  test(
    'IT-near-limit: once per cycle, real numbers, always below the hide '
    'trigger',
    timeout: const Timeout(Duration(seconds: 180)),
    () async {
      // #2416 merge: this scenario's geometry differs from the IT-post-hide
      // one — FOUR read-cap-sized files (≈40.2k chars each ≈ 10.0k rendered
      // tokens at the harness's transcript density): the merged ≈8.8k
      // overhead + 4 reads puts the run's end ≈49.0k inside the near-limit
      // band and under the hide trigger, so nothing folds and the post-run
      // boundary check is the ONE notice.
      for (var i = 1; i <= 4; i++) {
        env.writeFile('big$i.txt', List.filled(980, 'x' * 40).join('\n'));
      }
      final run = foldRun(files: 4);
      // A 55k window: the run ends ≈49.0k estimated tokens — inside the
      // near-limit band [46,750, 54,800) and under the hide trigger, so
      // nothing folds and the post-run boundary check is the ONE notice.
      expect(
        await buildCli(
          run.stream,
          contextWindow: 55000,
        ).runHeadless('count the words'),
        0,
      );
      final out = io.out.toString();
      final lines = _nearLimitLine.allMatches(out).toList();
      // The post-run boundary check fires exactly once.
      expect(lines, hasLength(1), reason: out);
      for (final line in lines) {
        final percent = int.parse(line.group(1)!);
        final tokens = int.parse(line.group(2)!);
        final window = int.parse(line.group(3)!);
        expect(window, 55000);
        // min(0.85·W, trigger − max(2,000, 0.05·W)) = 46,750 here.
        expect(tokens, greaterThanOrEqualTo(46750), reason: '$line');
        expect(tokens, lessThan(54800), reason: 'before the trigger: $line');
        expect(percent, (tokens * 100 / window).round());
        expect(containsForbiddenContextPhrase(line.group(0)!), isFalse);
      }
      // The post-hide notices in the same run never exceed one per cycle
      // either: a notice is re-armed only by a hide.
      final postHide = _postHideLine.allMatches(out).length;
      expect(lines.length, lessThanOrEqualTo(postHide + 1));
      // The model saw the near-limit notice as a synthetic record too (the
      // post-run notice rides the NEXT prompt; in a single-shot headless
      // run nothing follows — the dim line and the HEP frame are the
      // human/supervisor receipts).
      expect(out, isNot(contains('at the limit')));
    },
  );
}

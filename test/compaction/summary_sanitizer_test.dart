// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// Issue #1131 — stale ephemeral claims in compaction summaries.
///
/// A compaction summary re-renders on every later turn, so a time-scoped
/// observation written at fold time ("your LAST tool call's RESULT was
/// dropped from context") re-renders forever as a current fact. Regression
/// coverage, three layers:
///
/// 1. the sanitizer itself (units, incl. E1 false-positive pins);
/// 2. the persist path (classic `compact`, branch summaries, structured
///    checkpoints) strips before recording and logs the fires;
/// 3. the render path (context projection) heals summaries poisoned by
///    older sessions without touching the session JSONL.

library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/projection.dart';
import 'package:test/test.dart';

/// The incident sentence (issue #1131, orchestrator session 01a06644-…).
const _incidentNote =
    '[CONTEXT NOTE — Your LAST tool call\'s RESULT was dropped from context; '
    'the drop happened DURING an earlier compacted span (the type 968 '
    'multi-file sweep). If you were mid-sweep, re-run only what you still '
    'need.]';

AssistantMessage _assistant(String text) {
  return AssistantMessage(
    content: [TextContent(text: text)],
    api: 'openai-completions',
    provider: 'openrouter',
    model: 'm1',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );
}

/// Fake summarizer: records every request, replays scripted results.
class _FakeSummarizer {
  _FakeSummarizer(this.results);

  final List<SummarizationResult> results;
  final prompts = <SummarizationRequest>[];

  Future<SummarizationResult> call(SummarizationRequest request) async {
    prompts.add(request);
    return results.removeAt(0);
  }
}

void main() {
  group('sanitizeSummary units', () {
    test('strips the incident claim (second person + drop)', () {
      final result = sanitizeSummary(
        '## Progress\n### Done\n- Fixed the login crash.\n'
        '$_incidentNote\n'
        '- The parser now handles unicode paths.\n',
      );
      expect(result.text, isNot(contains('was dropped')));
      expect(result.text, isNot(contains('mid-sweep')));
      expect(result.text, contains('Fixed the login crash.'));
      expect(result.text, contains('The parser now handles unicode paths.'));
    });

    test('reports every stripped span (the log payload)', () {
      final result = sanitizeSummary(
        'Your last tool call\'s result was dropped. Keep going.\n'
        '$_incidentNote\n',
      );
      expect(result.stripped, hasLength(2));
      expect(
        result.stripped.where((s) => s.contains('was dropped')),
        isNotEmpty,
      );
      expect(result.stripped.where((s) => s.contains('968')), isNotEmpty);
    });

    test('E1 pins: durable temporal facts survive verbatim', () {
      const durable =
          '## Key Decisions\n'
          '- **Pin**: the last release was v1.0.492.\n'
          '- The current maintainer is IstiN.\n'
          '- The user asked you to re-run the tests after the fix.\n';
      final result = sanitizeSummary(durable);
      expect(result.text, durable);
      expect(result.stripped, isEmpty);
    });

    test('clean summaries survive byte-identical', () {
      const clean =
          '## Open User Requests\n- [ ] ship it (asked 2026-09-30, r1)\n\n'
          '## Goal\nFix the compaction loop.\n';
      final result = sanitizeSummary(clean);
      expect(result.text, clean);
      expect(result.stripped, isEmpty);
    });

    test('a partially stripped bullet keeps its marker', () {
      final result = sanitizeSummary(
        '- [x] Landed the fix. Your last tool call was dropped.\n',
      );
      expect(result.text.trim(), '- [x] Landed the fix.');
      expect(result.stripped, hasLength(1));
    });
  });

  group('classic persist path (AC3)', () {
    test('compact() strips ephemeral claims and logs them in details', () async {
      const poisoned =
          '## Progress\n- Your LAST tool call\'s RESULT was dropped from '
          'context.\n- The login crash is fixed.\n';
      final manager = CompactionManager(
        summarize: _FakeSummarizer([
          SummarizationResult.success(poisoned),
        ]).call,
      );
      final result = await manager.compact(
        CompactionPreparation(
          firstKeptEntryId: 'r9',
          messagesToSummarize: [UserMessage.text('u1'), _assistant('a1')],
          turnPrefixMessages: const [],
          isSplitTurn: false,
          tokensBefore: 100,
        ),
      );
      expect(result.summary, isNot(contains('was dropped')));
      expect(result.summary, contains('The login crash is fixed.'));
      final details = result.details! as Map;
      final stripped = (details['sanitizedEphemeral'] as List).single as String;
      expect(stripped, contains('was dropped'));
    });
  });

  group('render path heals poisoned records (UT-1/AC1/E2)', () {
    late MemoryFileSystem fs;
    late JsonlSessionRepo repo;

    setUp(() {
      fs = MemoryFileSystem();
      repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
    });

    test('poisoned compaction record projects clean many turns later',
        () async {
      final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
      final firstId = await session.appendMessage(
        UserMessage.text('run the 968 sweep'),
      );
      await session.appendMessage(_assistant('sweeping'));
      await session.appendCompaction(
        summary:
            '## Progress\n- Fixed the parser.\n$_incidentNote\n',
        firstKeptEntryId: firstId,
        tokensBefore: 100,
      );
      // Simulate 20 later turns of history after the poisoned record.
      for (var i = 0; i < 20; i++) {
        await session.appendMessage(UserMessage.text('turn $i'));
      }
      final messages = await session.buildContextMessages();
      final summaryMessage = messages
          .whereType<UserMessage>()
          .singleWhere(
            (m) => (m.content as String).contains(compactionSummaryPrefix),
          );
      final summaryText = summaryMessage.content as String;
      expect(summaryText, startsWith(compactionSummaryPrefix));
      expect(summaryText, contains(compactionSummarySuffix));
      expect(summaryText, isNot(contains('was dropped')));
      expect(summaryText, isNot(contains('mid-sweep')));
      // Durable content of the same summary survives (E2: no JSONL rewrite,
      // only ephemeral phrasing suppressed).
      expect(summaryText, contains('Fixed the parser.'));
      // The persisted record is untouched (byte-identical JSONL invariant).
      final branch = await session.getBranch();
      final record = branch.whereType<CompactionRecord>().single;
      expect(record.summary, contains('was dropped'));
    });
  });

  group('branch summary persist path', () {
    test('generateBranchSummary sanitizes the LLM prose', () async {
      final fake = _FakeSummarizer([
        SummarizationResult.success(
          '## Goal\nFix the loop.\n$_incidentNote\n',
        ),
      ]);
      final result = await generateBranchSummary([
        MessageRecord(
          id: 'r1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('fix the loop'),
        ),
      ], summarize: fake.call);
      expect(result.summary, isNot(contains('was dropped')));
      expect(result.summary, contains('Fix the loop.'));
    });
  });

  group('structured checkpoint paths', () {
    test('checkpoint render sanitizes poisoned text (E2 for old checkpoints)',
        () {
      final path = <SessionRecord>[
        MessageRecord(
          id: 'r1',
          parentId: null,
          timestamp: DateTime.utc(2026),
          message: UserMessage.text('fix the loop'),
        ),
        CompactCheckpointRecord(
          id: 'r2',
          parentId: 'r1',
          timestamp: DateTime.utc(2026),
          firstRecordId: 'r1',
          lastRecordId: 'r1',
          text: 'Checkpoint: the loop was fixed. $_incidentNote',
          coversRecordIds: const ['r1'],
          flattenedRecordIds: const [],
        ),
      ];
      final messages = renderStructuredMessages(
        path: path,
        seqs: RecordSeqIndex(path),
        projectEntry: (record) =>
            record is MessageRecord ? [record.message] : const [],
      );
      final checkpoint = messages
          .whereType<UserMessage>()
          .firstWhere(
            (m) => (m.content as String).contains('Checkpoint:'),
          );
      final checkpointText = checkpoint.content as String;
      expect(checkpointText, isNot(contains('was dropped')));
      expect(checkpointText, contains('the loop was fixed'));
      // The span stamp survives: structured checkpoints render covers-scoped.
      expect(checkpointText, contains('covers:'));
    });
  });

  group('round-1 review pins (#1133)', () {
    test('T1: durable reported speech with second person survives', () {
      const durable =
          '## Open User Requests\n'
          '- [ ] The user asked you to re-run the full suite after the '
          'previous fix lands.\n'
          '- The user asked you to bump the version; CI currently fails on '
          'the release job.\n';
      final result = sanitizeSummary(durable);
      expect(result.text, durable);
      expect(result.stripped, isEmpty);
    });

    test('T2: unbracketed "context note:" mentions survive', () {
      const prose =
          'Documented the context note: format used by the pairing repairer. '
          'See the docs page [redaction] for details.\n';
      final result = sanitizeSummary(prose);
      expect(result.text, prose);
      expect(result.stripped, isEmpty);

      const bullets =
          '## Progress\n'
          '- Added a context note: renderer\n'
          '- Fixed the parser\n';
      final bulletsResult = sanitizeSummary(bullets);
      expect(bulletsResult.text, bullets);
      expect(bulletsResult.stripped, isEmpty);
    });

    test('T2: an unterminated bracketed opener is left untouched', () {
      const text =
          'See [context note: docs for the format\n- Fixed the parser\n';
      final result = sanitizeSummary(text);
      expect(result.text, text);
      expect(result.stripped, isEmpty);
    });

    test('T4: a bare list marker left by a strip is dropped, not duplicated',
        () {
      final result = sanitizeSummary(
        '## Next Steps\n1. Ship the release.\n2. You just ran the 968 sweep.\n',
      );
      expect(result.text, '## Next Steps\n1. Ship the release.\n');
      expect(result.stripped, hasLength(1));
    });

    test('T3: generateSummary heals previousSummary before the prompt',
        () async {
      const poisoned =
          '## Progress\n- Your LAST tool call\'s RESULT was dropped from '
          'context.\n- The login crash is fixed.\n';
      final fake = _FakeSummarizer([
        SummarizationResult.success(
          '## Progress\n- The login crash is fixed.',
        ),
      ]);
      await generateSummary(
        [UserMessage.text('u1'), _assistant('a1')],
        summarize: fake.call,
        previousSummary: poisoned,
      );
      final prompt = fake.prompts.single.prompt;
      expect(prompt, contains('<previous-checkpoint>'));
      // The healed checkpoint rides the prompt; the poison does not.
      expect(prompt, isNot(contains('was dropped')));
      expect(prompt, contains('The login crash is fixed.'));
    });
  });

  group('round-2 review pins (#1133)', () {
    test('R2-T1: possessive mentions of prior user artifacts survive', () {
      const constraints =
          '## Constraints & Preferences\n'
          '- Rebase your previous commits before every push.\n'
          '- Copy your last release notes into the announcement.\n';
      final result = sanitizeSummary(constraints);
      expect(result.text, constraints);
      expect(result.stripped, isEmpty);
    });

    test('R2-T2: a line-wrapped context note is stripped whole', () {
      const wrapped =
          '[CONTEXT NOTE — Your LAST tool call\'s RESULT was dropped from\n'
          'context; the drop happened DURING an earlier compacted span. If\n'
          'you were mid-sweep, re-run only what you still need.]\n'
          '- Fixed the parser\n';
      final result = sanitizeSummary(wrapped);
      expect(result.text, '- Fixed the parser\n');
      expect(result.stripped, hasLength(1));
      expect(result.stripped.single, contains('mid-sweep'));
    });

    test('R2-T2: a close beyond the 2-line window is not a note', () {
      const far =
          'Kept the [context note: one line\n\n\n\nthe close lands here]\n'
          '- Fixed the parser\n';
      final result = sanitizeSummary(far);
      expect(result.text, far);
      expect(result.stripped, isEmpty);
    });

    test('R2-T3: contracted and interpolated drop claims strip', () {
      final result = sanitizeSummary(
        'You\'ve just landed the fix. You\'re about to lose the staging '
        'env. You were just about to run the sweep when the turn ended.\n'
        '- The staging env still exists.\n',
      );
      expect(result.text, '- The staging env still exists.\n');
      expect(result.stripped, hasLength(3));
    });
  });

  group('round-3 review pins (#1133)', () {
    test('R3: modal "you just need/have to" instructions survive', () {
      const next =
          '## Next Steps\n'
          '1. You just need to re-run make to finish.\n'
          '2. You just have to wait for CI.\n';
      final result = sanitizeSummary(next);
      expect(result.text, next);
      expect(result.stripped, isEmpty);
    });

    test('R3: modal "if you just look" coaching survives', () {
      const coaching =
          'If you just look at the failing test, the cause is obvious.\n'
          '- The failing test is test/compaction/token_estimation_test.dart.\n';
      final result = sanitizeSummary(coaching);
      expect(result.text, coaching);
      expect(result.stripped, isEmpty);
    });

    test('R3: "you just" + past-tense event verb still strips', () {
      final result = sanitizeSummary(
        'You just pushed the branch. You just deleted the staging cluster.\n'
        '- The branch is feature/next on origin.\n',
      );
      expect(result.text, '- The branch is feature/next on origin.\n');
      expect(result.stripped, hasLength(2));
    });
  });

  group('round-4 review pins (#1133)', () {
    test('R4: common coding past-tense verbs strip', () {
      final result = sanitizeSummary(
        'You just fixed the login crash. You just added a regression test. '
        'You just merged the PR.\n'
        '- The PR is #1102 on origin.\n',
      );
      expect(result.text, '- The PR is #1102 on origin.\n');
      expect(result.stripped, hasLength(3));
    });

    test('R4: reported speech and present-tense duties survive', () {
      const durable =
          'You just said the opposite of what the log shows.\n'
          'You just head the review queue now, nothing else.\n'
          '- The log shows exit code 1.\n';
      final result = sanitizeSummary(durable);
      expect(result.text, durable);
      expect(result.stripped, isEmpty);
    });
  });

  group('round-5 review pins (#1133)', () {
    test('R5: common irregular past verbs strip', () {
      final result = sanitizeSummary(
        'You just found the bug. You just broke the build. '
        'You just sent the review. You just took the lock. '
        'You just left the meeting. You just lost the ticket.\n'
        '- The ticket is OPS-4821 on the board.\n',
      );
      expect(result.text, '- The ticket is OPS-4821 on the board.\n');
      expect(result.stripped, hasLength(6));
    });

    test('R5: reported-speech told survives like said', () {
      const durable =
          'You just told me to rebase first.\n'
          '- The rebase is pending on origin/main.\n';
      final result = sanitizeSummary(durable);
      expect(result.text, durable);
      expect(result.stripped, isEmpty);
    });

    test('R6: unambiguous irregular pasts strip', () {
      final result = sanitizeSummary(
        'You just began the retry. You just forgot the flag. '
        'You just sold the license. You just threw the switch.\n'
        '- The license key is in the vault.\n',
      );
      expect(result.text, '- The license key is in the vault.\n');
      expect(result.stripped, hasLength(4));
    });
  });
}

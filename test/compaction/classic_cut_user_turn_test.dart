// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// gh-2411, the classic cut: the cut stays the NATURAL one (a hard ceiling
/// at the newest turn left a long turn with nothing foldable and killed
/// the funnel backstop) — the invariant is the TEXT: when the cut SPLITS
/// the newest REAL user turn, its ask leaves the summarized turn prefix
/// and rides the summary VERBATIM ([CompactionPreparation.carriedUserTurn]).
/// A turn that is not the split one needs no carry: it sits in the kept
/// region. The emergency valve and the structured checkpoint range carry
/// the same invariant (see context_overhead_regression_test.dart).

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;
  late Session session;
  late CompactionManager manager;

  /// A tiny keep budget so a handful of records already forces a cut.
  const tinyKeep = CompactionSettings(
    enabled: true,
    reserveTokens: 16384,
    keepRecentTokens: 100,
  );

  setUp(() async {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
    session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    manager = CompactionManager(
      summarize: (_) async => SummarizationResult.success(''),
      settings: tinyKeep,
    );
  });

  test('the cut may split an OLDER turn — the newest real user turn rides '
      'the kept region untouched', () async {
    await session.appendMessage(UserMessage.text('first ask'));
    await session.appendMessage(_reply('o' * 400));
    await session.appendMessage(UserMessage.text('newest ask'));
    await session.appendMessage(_reply('r' * 120));
    final path = await session.getBranch();

    final preparation = manager.prepareCompaction(
      path,
      tokensBefore: 2000,
      settings: tinyKeep,
    );

    expect(preparation, isNotNull);
    expect(preparation!.isSplitTurn, isTrue);
    // The split turn is the OLDER one: its ask is the turn prefix…
    final prefix = preparation.turnPrefixMessages.whereType<UserMessage>();
    expect(prefix, hasLength(1));
    expect(userMessageText(prefix.single.content), 'first ask');
    // …nothing is carried (the newest real turn is not the split one)…
    expect(preparation.carriedUserTurn, isNull);
    expect(preparation.messagesToSummarize, isEmpty);
    // …and the kept region starts no later than the newest ask.
    final kept = path.indexWhere(
      (entry) => entry.id == preparation.firstKeptEntryId,
    );
    expect(kept, inInclusiveRange(0, 2));
  });

  test('a lone long turn: the ask is carried VERBATIM, the fold is the '
      "turn's own body", () async {
    await session.appendMessage(UserMessage.text('only ask'));
    await session.appendMessage(_reply('r' * 1200));

    final preparation = manager.prepareCompaction(
      await session.getBranch(),
      tokensBefore: 2000,
      settings: tinyKeep,
    );

    expect(preparation, isNotNull);
    expect(preparation!.isSplitTurn, isTrue);
    expect(preparation.messagesToSummarize, isEmpty);
    expect(preparation.turnPrefixMessages, isEmpty);
    final ask = preparation.carriedUserTurn;
    expect(ask, isNotNull, reason: 'the split turn IS the newest turn');
    expect(userMessageText(ask!.content), 'only ask');
    // The summary carries the ask verbatim, on top — the model still
    // sees the request the kept tail answers to.
    final result = await manager.compact(preparation);
    expect(result.summary, contains('only ask'));
    expect(result.summary, contains('kept verbatim'));
  });

  test('a synthetic user record (notice, marker) is not a turn — the carried '
      'ask is the real one', () async {
    await session.appendMessage(UserMessage.text('older ask'));
    await session.appendMessage(_reply('o' * 400));
    await session.appendMessage(UserMessage.text('newest real ask'));
    await session.appendMessage(_reply('r' * 800));
    // The natural cut lands AFTER the real turn (at the notice).
    await session.appendMessage(
      UserMessage.text(
        '<system-notice>background job finished</system-notice>',
      ),
    );

    final preparation = manager.prepareCompaction(
      await session.getBranch(),
      tokensBefore: 2000,
      settings: tinyKeep,
    );

    expect(preparation, isNotNull);
    expect(preparation!.isSplitTurn, isTrue);
    final ask = preparation.carriedUserTurn;
    expect(ask, isNotNull, reason: 'the real turn is the split one');
    expect(userMessageText(ask!.content), 'newest real ask');
    // The ask is in NEITHER summarized list — only older history folds.
    expect(preparation.messagesToSummarize, isNot(contains(ask)));
    expect(preparation.turnPrefixMessages, isNot(contains(ask)));
    final folded = preparation.messagesToSummarize.whereType<UserMessage>();
    expect(folded, hasLength(1));
    expect(userMessageText(folded.single.content), 'older ask');
  });
}

AssistantMessage _reply(String text) {
  return AssistantMessage(
    content: [TextContent(text: text)],
    api: 'openai-completions',
    provider: 'openrouter',
    model: 'm',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );
}

// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// Issue #148 + #266 — the `compact_expand` tool surface: every record
/// kind renders with its wrapper stripped once hidden, failure classes
/// answer with ONE honest message each, discovery lists hidden segments
/// (query-filterable, free), paging footers state the exact continue
/// call, and successes report the per-turn budget left.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/expand_tool.dart';
import 'package:flutter_agent_harness/src/compaction/structured/projection.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'm1',
  api: 'anthropic-messages',
  provider: 'p',
  baseUrl: 'http://localhost:1',
  contextWindow: 8000,
  maxTokens: 4096,
);

String _flat(Object? content) => content is String
    ? content
    : (content as List<Object>)
          .whereType<TextContent>()
          .map((b) => b.text)
          .join('\n');

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  /// A controller over [session]; null [pageChars]/[turnBudgetTokens]
  /// keep the production defaults.
  Future<CompactExpandController> controllerFor(
    Session? session, {
    int? pageChars,
    int? turnBudgetTokens,
  }) async {
    final agent = Agent(
      model: _model,
      streamFunction: (m, c, {cancelToken}) =>
          throw StateError('no LLM call expected'),
      toolRegistry: ToolRegistry(const []),
    );
    final controller = CompactExpandController(
      agent: agent,
      session: () => session,
      pageChars: pageChars ?? defaultExpandPageChars,
      turnBudgetTokens: turnBudgetTokens ?? defaultExpandTurnBudgetTokens,
    );
    addTearDown(controller.dispose);
    return controller;
  }

  Future<String> call(
    CompactExpandController controller, {
    Object? target,
    Object? query,
    int? page,
  }) async {
    final result = await controller.tool.execute(
      {
        if (target != null) 'target': target,
        if (query != null) 'query': query,
        if (page != null) 'page': page,
      },
      null,
      null,
    );
    return _flat(result.content);
  }

  Future<String> expand(
    CompactExpandController controller,
    Object target, {
    int? page,
  }) => call(controller, target: target, page: page);

  test('renders every record kind with the wrapper stripped', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    final ids = <String>[];
    Future<String> add(Future<String> Function() append) async {
      final id = await append();
      ids.add(id);
      return id;
    }

    await add(() => session.appendMessage(UserMessage.text('fix it')));
    await add(
      () => session.appendMessage(
        AssistantMessage(
          content: [
            ThinkingContent(thinking: 'reasoning here'),
            TextContent(text: 'probing'),
            ToolCall(id: 'c1', name: 'read', arguments: {'path': 'a.dart'}),
            ImageContent(data: 'aW1n', mimeType: 'image/png'),
          ],
          api: 'anthropic-messages',
          provider: 'p',
          model: 'm1',
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.utc(2026),
        ),
      ),
    );
    await add(
      () => session.appendMessage(
        ToolResultMessage(
          toolCallId: 'c1',
          toolName: 'read',
          content: [
            TextContent(text: 'file body'),
            ThinkingContent(thinking: 'not text'),
          ],
          isError: false,
          timestamp: DateTime.utc(2026),
        ),
      ),
    );
    await add(
      () => session.appendCustomMessageEntry(
        customType: 'notice',
        content: 'note from host',
        display: true,
      ),
    );
    await add(() => session.appendThinkingLevelChange('high'));
    await add(
      () => session.appendCompactCheckpoint(
        firstRecordId: ids.first,
        lastRecordId: ids.first,
        text: 'level-1 summary',
        coversRecordIds: [ids.first],
        flattenedRecordIds: const [],
      ),
    );

    // Hide records 2..7 so each becomes expandable; a visible record is
    // refused (F2) and is covered by its own test below.
    await session.appendHiddenRange(recordIds: ids.sublist(0, 6));

    final seqs = RecordSeqIndex(await session.getEntries());
    int seq(String id) => seqs.seqOf(id)!;
    final controller = await controllerFor(session);

    final user = await expand(controller, seq(ids[0]));
    expect(user, contains('[${seq(ids[0])} user]\nfix it'));
    // Every success states the remaining budget (AC3). The first expand
    // charges ~1 token, so ~31k of the 32k turn budget remain.
    expect(user, contains('· expand budget left: ~31k tokens]'));

    final assistant = await expand(controller, seq(ids[1]));
    expect(assistant, contains('<thinking>\nreasoning here'));
    expect(assistant, contains('probing'));
    expect(assistant, contains('tool_call read('));
    expect(assistant, contains('[image]'));

    final result = await expand(controller, seq(ids[2]));
    expect(result, contains('file body'));
    expect(result, contains('[${seq(ids[2])} tool_result · read]'));

    final custom = await expand(controller, seq(ids[3]));
    expect(custom, contains('[${seq(ids[3])} context]\nnote from host'));

    final system = await expand(controller, seq(ids[4]));
    expect(system, contains('system record — no content'));

    final ckpt = await expand(controller, seq(ids[5]));
    expect(ckpt, contains('[${seq(ids[5])} ckpt · covers 1 ids]'));
    expect(ckpt, contains('level-1 summary'));

    // Pure hide state carries no content of its own.
    expect(
      await expand(controller, seq((await session.getEntries()).last.id)),
      'record 8 carries no content to expand',
    );
  });

  test('failure classes answer with one honest message each (F2)', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await session.appendMessage(UserMessage.text('one'));
    await session.appendMessage(UserMessage.text('two'));
    final controller = await controllerFor(session);

    final dead = await controllerFor(null);
    expect(await expand(dead, '2'), 'no active session to expand from');

    expect(
      await expand(controller, 'not-a-target'),
      startsWith('target must be a numeric id or range'),
    );
    expect(
      await expand(controller, '5-2'),
      'inverted range 5-2 — use "min-max"',
    );
    // Out of range: single id and range share the same message shape,
    // and the valid-id span comes from the file order (header = line 1).
    expect(await expand(controller, '9'), 'no record 9 — valid ids 2-3');
    expect(
      await expand(controller, '9000-9002'),
      'no record 9000-9002 — valid ids 2-3',
    );
    // Visible records are told apart from missing ones.
    expect(
      await expand(controller, '2'),
      'record 2 is visible, nothing to expand',
    );
  });

  test(
    'classic-folded, hidden, and off-branch records all expand (F2)',
    () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      final ids = <String>[];
      for (var i = 0; i < 4; i++) {
        ids.add(await session.appendMessage(UserMessage.text('m$i')));
      }
      // Legacy compaction folds m0-m1 away; the hidden range covers m3.
      // Both stay on the active branch (compaction → hidden-range chain).
      ids.add(
        await session.appendCompaction(
          summary: 'legacy sum',
          firstKeptEntryId: ids[2],
          tokensBefore: 100,
        ),
      );
      ids.add(await session.appendHiddenRange(recordIds: [ids[3]]));
      // A side branch off m3 carries the branch summary...
      final branchId = await session.moveTo(
        ids[3],
        summary: 'old branch went here',
      );
      ids.add(branchId!);
      // ...and the active leaf returns to the compaction branch, leaving
      // the branch summary off-branch.
      await session.moveTo(ids[5]);

      final seqs = RecordSeqIndex(await session.getEntries());
      final controller = await controllerFor(session);

      // Folded by the classic summary — off the projected path.
      expect(await expand(controller, seqs.seqOf(ids[0])!), contains('m0'));
      // Hidden by range.
      expect(await expand(controller, seqs.seqOf(ids[3])!), contains('m3'));
      // Off-branch.
      expect(
        await expand(controller, seqs.seqOf(branchId)!),
        contains('old branch went here'),
      );
      // The legacy summary itself sits on the path — visible, refused.
      expect(
        await expand(controller, seqs.seqOf(ids[4])!),
        'record ${seqs.seqOf(ids[4])} is visible, nothing to expand',
      );
    },
  );

  test(
    'discovery: no target lists hidden segments with previews (F1b)',
    () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(UserMessage.text('alpha'));
      const toolCallId = 'c1';
      await session.appendMessage(
        AssistantMessage(
          content: [
            ToolCall(id: toolCallId, name: 'grep', arguments: {'q': 'x'}),
          ],
          api: 'anthropic-messages',
          provider: 'p',
          model: 'm1',
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.utc(2026),
        ),
      );
      final resultId = await session.appendMessage(
        ToolResultMessage(
          toolCallId: toolCallId,
          toolName: 'grep',
          content: [TextContent(text: 'grep hit line')],
          isError: false,
          timestamp: DateTime.utc(2026),
        ),
      );
      await session.appendHiddenRange(recordIds: [resultId]);

      final seqs = RecordSeqIndex(await session.getEntries());
      final controller = await controllerFor(session);

      final index = await call(controller);
      expect(index, startsWith('hidden segments (compact_expand reopens any'));
      // The visible user turn is NOT in the index.
      expect(index, isNot(contains('alpha')));
      // The hidden tool result lists id, kind, size, preview.
      expect(
        index,
        contains(
          '[${seqs.seqOf(resultId)}:hidden·tool_result·4·"grep hit line"]',
        ),
      );
      // Discovery is free — no budget consumed.
      expect(controller.spentTokens, 0);

      // Everything visible → the honest empty index.
      final emptySession = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await emptySession.appendMessage(UserMessage.text('only'));
      final empty = await controllerFor(emptySession);
      expect(
        await call(empty),
        'no hidden segments — everything in this session is visible in context',
      );
    },
  );

  test(
    'discovery: query filters previews AND full hidden content (F1b)',
    () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      final body = '${List.filled(120, 'x').join()} NEEDLE in the tail';
      final resultId = await session.appendMessage(
        ToolResultMessage(
          toolCallId: 'c1',
          toolName: 'grep',
          content: [TextContent(text: body)],
          isError: false,
          timestamp: DateTime.utc(2026),
        ),
      );
      await session.appendHiddenRange(recordIds: [resultId]);
      final seqs = RecordSeqIndex(await session.getEntries());
      final controller = await controllerFor(session);

      // The needle sits past the 80-char preview — only a content scan
      // finds it (AC5).
      final hit = await call(controller, query: 'needle');
      expect(hit, contains('1 hidden segments match "needle"'));
      expect(hit, contains('[${seqs.seqOf(resultId)}:hidden·tool_result·'));

      expect(
        await call(controller, query: 'zzz-nowhere'),
        'no hidden segments match "zzz-nowhere" — valid ids 2-3 '
        '(drop query for the full index)',
      );
      // Kind names rank as preview-class hits.
      expect(
        await call(controller, query: 'tool_result'),
        contains('1 hidden'),
      );
    },
  );

  test('a pasted marker string resolves like the bare id', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await session.appendMessage(UserMessage.text('find me'));
    final lastId = (await session.getEntries()).last.id;
    await session.appendHiddenRange(recordIds: [lastId]);
    final seqs = RecordSeqIndex(await session.getEntries());
    final target = seqs.seqOf(lastId)!;
    final controller = await controllerFor(session);
    expect(
      await expand(controller, '[$target:hidden·tool_result·4.5k]'),
      contains('find me'),
    );
  });

  test(
    'paging: giant segments slice by page with the exact continue footer',
    () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      final body = List.filled(250, 'x').join();
      await session.appendMessage(UserMessage.text(body));
      await session.appendHiddenRange(
        recordIds: [(await session.getEntries()).last.id],
      );
      final seqs = RecordSeqIndex(await session.getEntries());
      final target = seqs.seqOf((await session.getEntries()).first.id)!;
      // pageChars 100 → 3 pages over 250 chars.
      final controller = await controllerFor(session, pageChars: 100);

      final page1 = await expand(controller, target, page: 1);
      expect(page1, startsWith('[expand $target · expand budget left:'));
      expect(
        page1,
        endsWith(
          '[page 1/3 — continue with compact_expand '
          '{"target": "$target", "page": 2}]',
        ),
      );
      expect(page1, isNot(contains(body)), reason: 'only the first slice');

      final page2 = await expand(controller, target, page: 2);
      expect(page2, contains(body.substring(100, 200)));

      final page3 = await expand(controller, target, page: 3);
      expect(page3, endsWith('[end of record $target]'));

      expect(
        await expand(controller, target, page: 0),
        'page 0 out of range (1-3) for target $target',
      );
      expect(
        await expand(controller, target, page: 9),
        'page 9 out of range (1-3) for target $target',
      );
    },
  );

  test(
    'budget charges per delivered page, so giants stay expandable',
    () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(
        UserMessage.text(List.filled(400, 'y').join()),
      );
      await session.appendHiddenRange(
        recordIds: [(await session.getEntries()).last.id],
      );
      final seqs = RecordSeqIndex(await session.getEntries());
      final target = seqs.seqOf((await session.getEntries()).first.id)!;

      // Single page bigger than the whole budget: denied, nothing spent,
      // and the message names the reset (F2). 100 estimated tokens for
      // the page do not fit a 10-token budget.
      final tiny = await controllerFor(session, turnBudgetTokens: 10);
      expect(
        await expand(tiny, target),
        'expand budget exhausted for this turn (0k tokens) — '
        'it resets on the next user turn',
      );
      expect(tiny.spentTokens, 0, reason: 'denied expand spends nothing');

      // The same record pages through a small budget a page at a time
      // (S6: paging a giant segment must stay possible).
      final paged = await controllerFor(
        session,
        pageChars: 100,
        turnBudgetTokens: 60,
      );
      final afterPage1 = await expand(paged, target, page: 1);
      expect(afterPage1, contains('page 1/5'));
      final firstCharge = paged.spentTokens;
      expect(firstCharge, greaterThan(0), reason: 'one page = ~25 tokens');
      expect(
        afterPage1,
        contains('· expand budget left: ~${60 - firstCharge} tokens]'),
      );
      expect(await expand(paged, target, page: 2), contains('page 2/5'));
      expect(
        paged.spentTokens,
        firstCharge * 2,
        reason: 'pages accumulate, page by page',
      );
      // Budget 60 fits two ~25-token pages; the third is denied.
      expect(
        await expand(paged, target, page: 3),
        'expand budget exhausted for this turn (0k tokens) — '
        'it resets on the next user turn',
      );
      expect(
        paged.spentTokens,
        firstCharge * 2,
        reason: 'denied page spends nothing',
      );

      final roomy = await controllerFor(session, turnBudgetTokens: 10 * 1024);
      expect(await expand(roomy, target), contains('yyyy'));
      expect(roomy.spentTokens, greaterThan(0));
    },
  );
}

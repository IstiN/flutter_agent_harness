// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// Issue #148 — the `compact_expand` tool surface: every record kind
/// renders with its wrapper stripped, error and paging paths return
/// structured notes, and the per-turn budget gates runaway expands.

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

  Future<String> expand(
    CompactExpandController controller,
    Object target, {
    int? page,
  }) async {
    final result = await controller.tool.execute(
      {'target': target, if (page != null) 'page': page},
      null,
      null,
    );
    return _flat(result.content);
  }

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
    await add(
      () => session.appendCompaction(
        summary: 'legacy sum',
        firstKeptEntryId: ids.first,
        tokensBefore: 100,
      ),
    );
    final last = ids.last;
    final branchId = await session.moveTo(
      last,
      summary: 'old branch went here',
    );
    expect(branchId, isNotNull);
    ids.add(branchId!);

    final hiddenId = await session.appendHiddenRange(recordIds: [ids.first]);

    final seqs = RecordSeqIndex(await session.getEntries());
    int seq(String id) => seqs.seqOf(id)!;
    final controller = await controllerFor(session);

    final user = await expand(controller, seq(ids[0]));
    expect(user, contains('[${seq(ids[0])} user]\nfix it'));

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

    final legacy = await expand(controller, seq(ids[6]));
    expect(legacy, contains('legacy-ckpt · classic · not-expandable'));
    expect(legacy, contains('legacy sum'));

    final branch = await expand(controller, seq(ids[7]));
    expect(
      branch,
      contains('[${seq(ids[7])} branch-summary]\nold branch went here'),
    );

    // Pure hide state carries no content of its own.
    final hidden = await expand(controller, seq(hiddenId));
    expect(hidden, contains('no expandable records'));
  });

  test('a pasted marker string resolves like the bare id', () async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await session.appendMessage(UserMessage.text('find me'));
    final seqs = RecordSeqIndex(await session.getEntries());
    final target = seqs.seqOf((await session.getEntries()).last.id)!;
    final controller = await controllerFor(session);
    expect(
      await expand(controller, '[$target:hidden·tool_result·4.5k]'),
      contains('find me'),
    );
  });

  test(
    'error paths: no session, bad target, inverted and empty ranges',
    () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
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
      expect(
        await expand(controller, '9000-9002'),
        allOf(
          contains('no expandable records'),
          contains('out of range: 9000-9002'),
        ),
      );
    },
  );

  test(
    'paging: giant segments slice by page with a continuation footer',
    () async {
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      final body = List.filled(250, 'x').join();
      await session.appendMessage(UserMessage.text(body));
      final seqs = RecordSeqIndex(await session.getEntries());
      final target = seqs.seqOf((await session.getEntries()).last.id)!;
      // pageChars 100 → 3 pages over 250 chars.
      final controller = await controllerFor(session, pageChars: 100);

      final page1 = await expand(controller, target, page: 1);
      expect(page1, startsWith('[expand $target]\n'));
      expect(
        page1,
        endsWith(
          '[page 1/3 — compact_expand target=$target, page: 2 continues]',
        ),
      );
      expect(page1, isNot(contains(body)), reason: 'only the first slice');

      final page2 = await expand(controller, target, page: 2);
      expect(page2, contains(body.substring(100, 200)));

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
      final seqs = RecordSeqIndex(await session.getEntries());
      final target = seqs.seqOf((await session.getEntries()).last.id)!;

      // Single page bigger than the whole budget: denied, nothing spent.
      final tiny = await controllerFor(session, turnBudgetTokens: 10);
      expect(await expand(tiny, target), contains('Expand selectively'));
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
      expect(await expand(paged, target, page: 2), contains('page 2/5'));
      expect(
        paged.spentTokens,
        firstCharge * 2,
        reason: 'pages accumulate, page by page',
      );
      // Budget 60 fits two ~25-token pages; the third is denied.
      expect(
        await expand(paged, target, page: 3),
        contains('Expand selectively'),
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

// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-2423 C1 — the `working_set` tool (replaces gh-210's `recite_goal`):
/// read tier, one-string schema, save / clear / over-cap refusal with the
/// previous snapshot kept, the redaction report, the session binding (the
/// zone-scoped store wins over the constructed one — a task child's own
/// session over the host's), and the DATA contract: the tool never carries
/// an argument that reaches a tool, a shell or a network (AC1, AC12).
/// The approval-gate independence lives in
/// `test/approval/working_set_independence_test.dart`.
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;
  late Session session;

  setUp(() async {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
    session = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
  });

  WorkingSetStore store() =>
      SessionWorkingSetStore(session: () async => session);

  Future<List<CustomRecord>> stored() async => (await session.getEntries())
      .whereType<CustomRecord>()
      .where((r) => r.customType == workingSetRecordType)
      .toList();

  group('working_set tool surface', () {
    test('is a read-tier tool with a one-string schema', () {
      final tool = workingSetTool();
      expect(tool.name, 'working_set');
      expect(tool.tier, ApprovalTier.read);
      final properties = (tool.parameters['properties'] as Map<String, Object?>)
          .keys
          .toSet();
      expect(properties, {'text'}, reason: 'no shell / network surface');
      expect(tool.parameters['required'], ['text']);
    });

    test('the schema fits the 1,000-wire-char pin (AC11)', () {
      final wire = jsonEncode(workingSetTool().toJson());
      expect(wire.length, lessThanOrEqualTo(1000), reason: wire);
    });
  });

  group('working_set saves', () {
    test(
      'appends a custom working_set record to the session, latest wins',
      () async {
        final tool = workingSetTool(store: store());
        final result = await tool.execute(
          {'text': '  ship the login fix  '},
          null,
          null,
        );
        expect(result.terminate, isFalse);
        expect(
          _textOf(result),
          'working set saved: 18 chars — pinned in every request, '
          'survives compaction',
        );
        final records = await stored();
        expect(records, hasLength(1));
        expect(
          workingSetFromPayload(records.single.data)!.text,
          'ship the login fix',
        );

        await tool.execute({'text': 'second snapshot'}, null, null);
        final latest = await store().load();
        expect(latest!.text, 'second snapshot');
        expect(await stored(), hasLength(2), reason: 'append-only');
      },
    );

    test(
      'an empty text clears the slot (a clear record, no tombstone)',
      () async {
        final tool = workingSetTool(store: store());
        await tool.execute({'text': 'to be cleared'}, null, null);
        final result = await tool.execute({'text': ''}, null, null);
        expect(_textOf(result), 'working set cleared');
        final latest = await store().load();
        expect(latest, isNotNull);
        expect(latest!.isClear, isTrue);
      },
    );

    test('a multi-line text is stored verbatim', () async {
      final tool = workingSetTool(store: store());
      await tool.execute(
        {'text': 'decisions: A\nred list: B\nnext: C'},
        null,
        null,
      );
      expect(
        (await store().load())!.text,
        'decisions: A\nred list: B\nnext: C',
      );
    });
  });

  group('working_set over-cap (E1)', () {
    test('4097 chars is REFUSED with the count; nothing is appended', () async {
      final tool = workingSetTool(store: store());
      await tool.execute({'text': 'previous snapshot'}, null, null);
      final result = await tool.execute(
        {'text': 'x' * (workingSetMaxChars + 1)},
        null,
        null,
      );
      expect(
        _textOf(result),
        contains('working set NOT saved: 4097 chars is over the 4096-char cap'),
      );
      expect(_textOf(result), contains('previous working set stays pinned'));
      expect(await stored(), hasLength(1), reason: 'no record appended');
      expect((await store().load())!.text, 'previous snapshot');
    });

    test('exactly 4096 chars is accepted', () async {
      final tool = workingSetTool(store: store());
      final result = await tool.execute(
        {'text': 'y' * workingSetMaxChars},
        null,
        null,
      );
      expect(_textOf(result), startsWith('working set saved: 4096 chars'));
    });
  });

  group('working_set without a session', () {
    test('answers gracefully when no store is bound at all', () async {
      final result = await workingSetTool().execute(
        {'text': 'notes'},
        null,
        null,
      );
      expect(_textOf(result), contains('no session to store a working set'));
      expect(result.terminate, isFalse);
    });

    test('a non-string argument is a usage hint, never a write', () async {
      final tool = workingSetTool(store: store());
      final result = await tool.execute({'text': 7}, null, null);
      expect(_textOf(result), contains('{"text": "..."}'));
      expect(await stored(), isEmpty);
    });

    test('a cancelled token aborts before any write', () async {
      final source = CancelTokenSource()..cancel();
      final tool = workingSetTool(store: store());
      await expectLater(
        tool.execute({'text': 'x'}, source.token, null),
        throwsA(anything),
      );
      expect(await stored(), isEmpty);
    });

    test('a failed append returns the failure to the agent', () async {
      final tool = workingSetTool(
        store: SessionWorkingSetStore(
          session: () async => throw StateError('disk full'),
        ),
      );
      final result = await tool.execute({'text': 'x'}, null, null);
      expect(_textOf(result), contains('working set NOT saved'));
      expect(_textOf(result), contains('disk full'));
    });
  });

  group('working_set session binding', () {
    test('the zone-scoped store wins over the constructed one', () async {
      final hostStore = store();
      final tool = workingSetTool(store: hostStore);
      final childSession = await repo.create(
        JsonlSessionCreateOptions(cwd: '/child'),
      );
      final childStore = SessionWorkingSetStore(
        session: () async => childSession,
      );
      await runWithWorkingSetStore(
        childStore,
        () => tool.execute({'text': 'the child notes'}, null, null),
      );
      expect(await stored(), isEmpty, reason: 'the host slot is untouched');
      final childEntries = await childSession.getEntries();
      expect(childEntries.whereType<CustomRecord>().map((r) => r.customType), [
        workingSetRecordType,
      ]);
      // Outside the scope the constructed store answers again.
      expect(activeWorkingSetStore(), isNull);
      await tool.execute({'text': 'host notes'}, null, null);
      expect((await hostStore.load())!.text, 'host notes');
    });

    test(
      'the store reloads from the file (a new instance sees the record)',
      () async {
        await workingSetTool(
          store: store(),
        ).execute({'text': 'survives the restart'}, null, null);
        final reopened = await repo.open(await session.getMetadata());
        final fresh = SessionWorkingSetStore(session: () async => reopened);
        expect((await fresh.load())!.text, 'survives the restart');
      },
    );
  });

  group('working_set redaction (E14, AC12)', () {
    test('a secret is redacted before the record is written', () async {
      const secret = 'sk-live-abcdefghijklmnop';
      final pipeline = RedactionPipeline(registeredSecrets: const [secret]);
      final tool = workingSetTool(
        store: SessionWorkingSetStore(
          session: () async => session,
          redaction: pipeline,
        ),
      );
      final result = await tool.execute(
        {'text': 'use the key $secret for the staging call'},
        null,
        null,
      );
      final text = _textOf(result);
      expect(text, isNot(contains(secret)));
      expect(text, contains('redacted: 1'));
      final raw = (await fs.readTextFile(
        (await session.getMetadata()).path,
      )).valueOrNull!;
      expect(raw, isNot(contains(secret)), reason: 'byte-scan of the file');
      expect(raw, contains('[REDACTED:'));
      final latest = await store().load();
      expect(latest!.text, isNot(contains(secret)));
      expect(latest.text, contains('[REDACTED:'));
    });
  });
}

String _textOf(ToolExecutionResult result) =>
    result.content.map((block) => (block as TextContent).text).join();

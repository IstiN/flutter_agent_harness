// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

@TestOn('vm')
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

void main() {
  test('JSONL catalog reads names, first prompt, exact cwd and lastActiveAt '
      'without opening whole transcripts', () async {
    final env = MemoryExecutionEnv();
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final named = await repo.create(
      JsonlSessionCreateOptions(
        id: '123e4567-e89b-12d3-a456-426614174000',
        cwd: '/work/flutter_agent',
      ),
    );
    await named.appendMessage(
      UserMessage.text('  First prompt\n with detail '),
    );
    await named.appendMessage(UserMessage.text('later prompt'));
    await named.appendSessionName('Roster work');
    final snippetOnly = await repo.create(
      JsonlSessionCreateOptions(id: 'snippet', cwd: '/work/other'),
    );
    await snippetOnly.appendMessage(UserMessage.text('Snippet title'));

    final store = JsonlSessionCatalogStore(repo: repo);
    final rows = await store.loadSessions(
      liveSessionIds: {'123e4567-e89b-12d3-a456-426614174000'},
    );

    expect(rows, hasLength(2));
    final namedRow = rows.singleWhere((row) => row.id == named.cachedId);
    expect(namedRow.sessionName, 'Roster work');
    expect(namedRow.title, 'Roster work');
    expect(namedRow.snippet, 'First prompt with detail');
    expect(namedRow.displayName, 'Roster work');
    expect(namedRow.cwd, '/work/flutter_agent');
    expect(namedRow.cwdSlug, 'flutter_agent');
    expect(namedRow.live, isTrue);
    expect(namedRow.lastActiveAt, isNotNull);
    final snippetRow = rows.singleWhere((row) => row.id == 'snippet');
    expect(snippetRow.title, isNull);
    expect(snippetRow.displayName, 'Snippet title');
    expect(snippetRow.live, isFalse);
  });

  test('catalog cache does not rescan an unchanged transcript and refreshes '
      'after append', () async {
    final env = MemoryExecutionEnv();
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final session = await repo.create(
      JsonlSessionCreateOptions(id: 'cached', cwd: '/work/cache'),
    );
    await session.appendMessage(UserMessage.text('Before'));
    final store = JsonlSessionCatalogStore(repo: repo);

    final first = await store.loadSessions();
    final second = await store.loadSessions();
    expect(second.single.snippet, first.single.snippet);
    expect(store.debugTranscriptScans, 1);

    await session.appendMessage(UserMessage.text('After'));
    final third = await store.loadSessions();
    expect(store.debugTranscriptScans, 2);
    expect(third.single.snippet, 'Before');
    expect(
      third.single.lastActiveAt.isAfter(first.single.lastActiveAt) ||
          third.single.lastActiveAt.isAtSameMomentAs(first.single.lastActiveAt),
      isTrue,
    );
  });
}

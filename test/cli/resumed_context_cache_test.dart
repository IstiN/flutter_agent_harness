import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// The warm-switch context cache (gh-1734 root cause 3): a resumed
/// session whose file is unchanged since the last open/switch reuses the
/// built [SessionContext] instead of re-paying the projection walk.
/// Entries are keyed by (path, size, mtime); every hit hands out a fresh
/// message list so a consumer mutating it can never corrupt the cache.
void main() {
  SessionContext contextOf(String marker) => SessionContext(
    messages: [UserMessage.text(marker)],
    thinkingLevel: 'off',
    model: null,
    activeToolNames: null,
  );

  test('misses on an empty cache', () {
    final cache = ResumedContextCache();
    expect(
      cache.match('/s/a.jsonl', sizeBytes: 10, mtimeMs: 1),
      isNull,
    );
  });

  test('hits on the same path + size + mtime', () {
    final cache = ResumedContextCache()
      ..remember(
        '/s/a.jsonl',
        sizeBytes: 10,
        mtimeMs: 1,
        context: contextOf('a'),
      );
    final hit = cache.match('/s/a.jsonl', sizeBytes: 10, mtimeMs: 1);
    expect(hit, isNotNull);
    expect(hit!.messages.single, isA<UserMessage>());
    expect((hit.messages.single as UserMessage).text, 'a');
  });

  test('misses when the size changes (an append landed)', () {
    final cache = ResumedContextCache()
      ..remember(
        '/s/a.jsonl',
        sizeBytes: 10,
        mtimeMs: 1,
        context: contextOf('a'),
      );
    expect(cache.match('/s/a.jsonl', sizeBytes: 11, mtimeMs: 1), isNull);
  });

  test('misses when the mtime changes', () {
    final cache = ResumedContextCache()
      ..remember(
        '/s/a.jsonl',
        sizeBytes: 10,
        mtimeMs: 1,
        context: contextOf('a'),
      );
    expect(cache.match('/s/a.jsonl', sizeBytes: 10, mtimeMs: 2), isNull);
  });

  test('misses for a different path with identical stats', () {
    final cache = ResumedContextCache()
      ..remember(
        '/s/a.jsonl',
        sizeBytes: 10,
        mtimeMs: 1,
        context: contextOf('a'),
      );
    expect(cache.match('/s/b.jsonl', sizeBytes: 10, mtimeMs: 1), isNull);
  });

  test('re-remembering the same path refreshes the entry', () {
    final cache = ResumedContextCache()
      ..remember(
        '/s/a.jsonl',
        sizeBytes: 10,
        mtimeMs: 1,
        context: contextOf('old'),
      )
      ..remember(
        '/s/a.jsonl',
        sizeBytes: 20,
        mtimeMs: 2,
        context: contextOf('new'),
      );
    expect(cache.match('/s/a.jsonl', sizeBytes: 10, mtimeMs: 1), isNull);
    final hit = cache.match('/s/a.jsonl', sizeBytes: 20, mtimeMs: 2);
    expect((hit!.messages.single as UserMessage).text, 'new');
  });

  test('each hit hands out a fresh message list', () {
    final cache = ResumedContextCache()
      ..remember(
        '/s/a.jsonl',
        sizeBytes: 10,
        mtimeMs: 1,
        context: contextOf('a'),
      );
    cache.match('/s/a.jsonl', sizeBytes: 10, mtimeMs: 1)!.messages.clear();
    final second = cache.match('/s/a.jsonl', sizeBytes: 10, mtimeMs: 1);
    expect(second!.messages, hasLength(1));
  });

  test('evicts the least-recently-used entry beyond the capacity', () {
    final cache = ResumedContextCache(capacity: 2)
      ..remember(
        '/s/a.jsonl',
        sizeBytes: 1,
        mtimeMs: 1,
        context: contextOf('a'),
      )
      ..remember(
        '/s/b.jsonl',
        sizeBytes: 1,
        mtimeMs: 1,
        context: contextOf('b'),
      )
      // A hit on `a` refreshes it — `b` becomes the LRU entry.
      ..match('/s/a.jsonl', sizeBytes: 1, mtimeMs: 1)
      ..remember(
        '/s/c.jsonl',
        sizeBytes: 1,
        mtimeMs: 1,
        context: contextOf('c'),
      );
    expect(
      cache.match('/s/a.jsonl', sizeBytes: 1, mtimeMs: 1),
      isNotNull,
      reason: 'the refreshed entry survives',
    );
    expect(
      cache.match('/s/b.jsonl', sizeBytes: 1, mtimeMs: 1),
      isNull,
      reason: 'the least-recently-used entry was evicted',
    );
    expect(cache.match('/s/c.jsonl', sizeBytes: 1, mtimeMs: 1), isNotNull);
  });

  test('clear() empties the cache', () {
    final cache = ResumedContextCache()
      ..remember(
        '/s/a.jsonl',
        sizeBytes: 10,
        mtimeMs: 1,
        context: contextOf('a'),
      )
      ..clear();
    expect(cache.length, 0);
    expect(cache.match('/s/a.jsonl', sizeBytes: 10, mtimeMs: 1), isNull);
  });
}

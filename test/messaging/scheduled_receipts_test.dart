import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// The scheduled-message receipt trail (gh-1180 AC4): append-only JSONL,
/// best-effort by contract — a failing write is reported through onError
/// and never breaks scheduling or waking.
void main() {
  test(
    'appends JSONL events with a timestamp, event name, and fields',
    () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      const path = '/sessions/--work--/messages/_scheduled/receipts.jsonl';
      final log = ScheduledReceiptLog(env: env, path: () => path);
      await log.append('scheduled', {'id': 'a1', 'dueMs': 123});
      await log.append('delivered', {'id': 'a1', 'lagMs': 45});
      final text = (await env.readTextFile(path)).valueOrNull!;
      final lines = text.trim().split('\n');
      expect(lines, hasLength(2));
      final first = jsonDecode(lines[0]) as Map<String, dynamic>;
      expect(first['event'], 'scheduled');
      expect(first['id'], 'a1');
      expect(first['dueMs'], 123);
      expect(first['ts'], isA<String>());
      final second = jsonDecode(lines[1]) as Map<String, dynamic>;
      expect(second['event'], 'delivered');
      expect(second['lagMs'], 45);
    },
  );

  test('appends are serialized in call order (no interleaved lines)', () async {
    final env = MemoryExecutionEnv(cwd: '/work');
    const path = '/sessions/--work--/messages/_scheduled/receipts.jsonl';
    final log = ScheduledReceiptLog(env: env, path: () => path);
    // Fire 50 appends without awaiting each: the chained tail keeps the
    // file line-ordered.
    for (var i = 0; i < 50; i++) {
      unawaited(log.append('e$i', {'i': i}));
    }
    await log.append('last', {});
    final text = (await env.readTextFile(path)).valueOrNull!;
    final lines = text.trim().split('\n');
    expect(lines, hasLength(51));
    final events = [
      for (final line in lines)
        (jsonDecode(line) as Map<String, dynamic>)['event'],
    ];
    expect(events.last, 'last');
    for (var i = 0; i < 50; i++) {
      expect(events[i], 'e$i');
    }
  });

  test(
    'a failing backend never throws: onError fires, append completes',
    () async {
      final errors = <String>[];
      final log = ScheduledReceiptLog(
        env: _BrokenEnv(),
        path: () => '/x/receipts.jsonl',
        onError: errors.add,
      );
      // Must complete normally — the trail is best-effort (AC4 contract).
      await log.append('wake_attempted', {'lane': 'chatter'});
      expect(errors, hasLength(1));
      expect(errors.single, contains('receipt write deferred'));
    },
  );

  test(
    'a throwing backend is contained: onError fires, append never throws',
    () async {
      final errors = <String>[];
      final log = ScheduledReceiptLog(
        env: _ThrowingEnv(),
        path: () => '/x/receipts.jsonl',
        onError: errors.add,
      );
      await log.append('wake_refused', {'reason': 'cap'});
      expect(errors.single, contains('receipt write deferred'));
    },
  );

  group('fd pressure (issue #2415 — defer, warn once, flush on recover)', () {
    test('a failing table defers with ONE warning and flushes the whole '
        'backlog in order on the first successful write', () async {
      final env = _FlakyEnv();
      final errors = <String>[];
      final log = ScheduledReceiptLog(
        env: env,
        path: () => '/x/receipts.jsonl',
        onError: errors.add,
      );
      env.failing = true;
      await log.append('wake_attempted', {'lane': 'a'});
      await log.append('wake_attempted', {'lane': 'b'});
      await log.append('wake_attempted', {'lane': 'c'});
      // One warning for the whole pressure window — no per-tick spam.
      expect(errors, hasLength(1));
      expect(errors.single, contains('receipt write deferred'));
      // Nothing lost, nothing yet on disk.
      expect(await env.text(), isNull);

      // Recover: the next append flushes the backlog plus itself.
      env.failing = false;
      await log.append('delivered', {'id': 'a'});
      final events = [
        for (final line in (await env.text())!.trim().split('\n'))
          (jsonDecode(line) as Map<String, dynamic>)['event'],
      ];
      expect(events, [
        'wake_attempted',
        'wake_attempted',
        'wake_attempted',
        'delivered',
      ]);
      // Still exactly one warning for the whole window.
      expect(errors, hasLength(1));
    });

    test('a new pressure window after recovery warns again', () async {
      final env = _FlakyEnv();
      final errors = <String>[];
      final log = ScheduledReceiptLog(
        env: env,
        path: () => '/x/receipts.jsonl',
        onError: errors.add,
      );
      env.failing = true;
      await log.append('wake_attempted', {'lane': 'a'});
      expect(errors, hasLength(1));
      env.failing = false;
      await log.append('delivered', {'id': 'a'});
      expect(errors, hasLength(1));
      env.failing = true;
      await log.append('wake_refused', {'lane': 'b'});
      expect(errors, hasLength(2));
      expect(errors.last, contains('receipt write deferred'));
      // The refused line stays pending; the delivered one landed.
      expect((await env.text())!.contains('delivered'), isTrue);
      expect((await env.text())!.contains('wake_refused'), isFalse);
    });
  });

  group('deliveredIds (issue #2384 AC1 — fired-timer evidence)', () {
    test(
      'collects only the delivered event ids, tolerates a torn tail line',
      () async {
        final env = MemoryExecutionEnv(cwd: '/work');
        const path = '/sessions/--work--/messages/_scheduled/receipts.jsonl';
        final log = ScheduledReceiptLog(env: env, path: () => path);
        await log.append('scheduled', {'id': 'a1', 'dueMs': 1});
        await log.append('delivered', {'id': 'a1', 'lagMs': 5});
        await log.append('delivered', {'id': 'a2', 'lagMs': 7});
        await log.append('delivery_failed', {'id': 'a3', 'error': 'x'});
        await log.append('wake_refused', {'lane': 'idle', 'reason': 'cap'});
        await log.append('delivered', {'id': 'a4', 'lagMs': 9});
        // A torn tail line (crash mid-append) must not break the reader.
        await env.appendFile(path, '{"event": "delivered", "id": "to');
        expect(await log.deliveredIds(), {'a1', 'a2', 'a4'});
      },
    );

    test('a missing or empty trail yields an empty set', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final log = ScheduledReceiptLog(
        env: env,
        path: () => '/sessions/--work--/messages/_scheduled/receipts.jsonl',
      );
      expect(await log.deliveredIds(), isEmpty);
    });
  });
}

/// An env whose `appendFile` reports a backend error (disk full, denied…).
final class _BrokenEnv implements ExecutionEnv {
  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      Future.value(
        Err(
          FileError(
            FileErrorCode.unknown,
            'injected append failure',
            path: path,
          ),
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// An env whose `appendFile` THROWS (the hostile shape).
final class _ThrowingEnv implements ExecutionEnv {
  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      Future.error(StateError('injected append throw'));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// An env whose `appendFile` fails while [failing] (the fd-pressure
/// simulation: an errno-24-shaped backend error), and delegates to an
/// in-memory store otherwise.
final class _FlakyEnv implements ExecutionEnv {
  final _delegate = MemoryExecutionEnv(cwd: '/work');

  bool failing = false;

  /// The trail text as the backend holds it, or null when nothing was
  /// ever written.
  Future<String?> text() =>
      _delegate.readTextFile('/x/receipts.jsonl').then((r) => r.valueOrNull);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) {
    if (failing) {
      return Future.value(
        Err(
          FileError(
            FileErrorCode.unknown,
            'Cannot open file (errno 24: Too many open files)',
            path: path,
          ),
        ),
      );
    }
    return _delegate.appendFile(path, content);
  }

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _delegate.readTextFile(path);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

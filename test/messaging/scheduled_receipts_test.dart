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
      addTearDown(log.dispose);
      // Must complete normally — the trail is best-effort (AC4 contract).
      await log.append('wake_attempted', {'lane': 'chatter'});
      expect(errors, hasLength(1));
      expect(errors.single, contains('receipt write failed'));
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
      addTearDown(log.dispose);
      await log.append('wake_refused', {'reason': 'cap'});
      expect(errors.single, contains('receipt write failed'));
    },
  );

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

  group('gh-2415: fd pressure never loses a receipt', () {
    Future<void> drainWithin(ScheduledReceiptLog log) async {
      for (var i = 0; i < 300 && log.pendingCount > 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(log.pendingCount, 0, reason: 'the backoff retries flush it');
    }

    test('N failing ticks → ONE deferral warning, every receipt kept in '
        'memory, then flushed in order with one recovery line', () async {
      const path = '/sessions/--work--/messages/_scheduled/receipts.jsonl';
      final env = _FlakyEnv(failures: 5);
      final errors = <String>[];
      final log = ScheduledReceiptLog(
        env: env,
        path: () => path,
        onError: errors.add,
        retryBaseDelay: const Duration(milliseconds: 5),
        retryMaxDelay: const Duration(milliseconds: 40),
      );
      addTearDown(log.dispose);
      for (var i = 0; i < 5; i++) {
        await log.append('delivered', {'id': 'a$i'});
        expect(log.pendingCount, i + 1);
      }
      // The backoff gate held the tick storm off the backend: ONE
      // attempt so far, ONE warning — not one per tick.
      expect(env.attempts, 1);
      expect(errors, hasLength(1));
      expect(errors.single, contains('receipt write deferred: fd pressure'));
      // The count named at the (single) warning is what was pending
      // THEN — the four later ticks were gated off the backend.
      expect(errors.single, contains('1 receipt(s) kept in memory'));
      // Pending receipts are still delivered evidence (the event
      // happened; only its persistence is deferred).
      expect(await log.deliveredIds(), {'a0', 'a1', 'a2', 'a3', 'a4'});
      await drainWithin(log);
      expect(errors, hasLength(2), reason: 'no repeated warnings');
      expect(
        errors.last,
        contains('receipt write recovered: 5 receipt(s) flushed'),
      );
      // Five failed retries + one success = six attempts, all under
      // the cap.
      expect(env.attempts, 6);
      final text = (await env.readTextFile(path)).valueOrNull!;
      final events = [
        for (final line in text.trim().split('\n'))
          (jsonDecode(line) as Map<String, dynamic>)['id'],
      ];
      expect(events, ['a0', 'a1', 'a2', 'a3', 'a4'], reason: 'order kept');
      // Healthy again: the next append lands at once, no warning.
      await log.append('wake_attempted', {'lane': 'x'});
      expect(env.attempts, 7);
      expect(log.pendingCount, 0);
      expect(errors, hasLength(2));
    });

    test('a non-fd failure keeps the "receipt write failed" wording and still '
        'never loses the line', () async {
      const path = '/sessions/--work--/messages/_scheduled/receipts.jsonl';
      final env = _FlakyEnv(failures: 1, fdPressure: false);
      final errors = <String>[];
      final log = ScheduledReceiptLog(
        env: env,
        path: () => path,
        onError: errors.add,
        retryBaseDelay: const Duration(milliseconds: 5),
      );
      addTearDown(log.dispose);
      await log.append('scheduled', {'id': 's1'});
      expect(errors.single, contains('receipt write failed'));
      expect(errors.single, isNot(contains('fd pressure')));
      expect(log.pendingCount, 1);
      await drainWithin(log);
      expect(
        (await env.readTextFile(path)).valueOrNull,
        contains('"scheduled"'),
      );
      expect(
        errors.last,
        contains('receipt write recovered: 1 receipt(s) flushed'),
      );
    });

    test(
      'dispose cancels the retry timer and drops the pending queue',
      () async {
        final env = _FlakyEnv(failures: 100);
        final errors = <String>[];
        final log = ScheduledReceiptLog(
          env: env,
          path: () => '/x/receipts.jsonl',
          onError: errors.add,
          retryBaseDelay: const Duration(milliseconds: 5),
        );
        await log.append('delivered', {'id': 'a1'});
        expect(log.pendingCount, 1);
        log.dispose();
        expect(log.pendingCount, 0);
        final attempts = env.attempts;
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(env.attempts, attempts, reason: 'no retry after dispose');
      },
    );
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

/// An env whose `appendFile` fails [failures] times (errno 24 — the fd
/// pressure shape — or a generic error) and then delegates to memory.
final class _FlakyEnv implements ExecutionEnv {
  _FlakyEnv({required this.failures, this.fdPressure = true});

  final MemoryExecutionEnv _delegate = MemoryExecutionEnv(cwd: '/work');
  int failures;
  final bool fdPressure;
  int attempts = 0;

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) {
    attempts++;
    if (failures > 0) {
      failures--;
      return Future.value(
        Err(
          FileError(
            FileErrorCode.unknown,
            fdPressure
                ? 'Cannot open file (errno 24: Too many open files)'
                : 'injected append failure',
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

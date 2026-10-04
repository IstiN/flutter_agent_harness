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
      await log.append('wake_refused', {'reason': 'cap'});
      expect(errors.single, contains('receipt write failed'));
    },
  );
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

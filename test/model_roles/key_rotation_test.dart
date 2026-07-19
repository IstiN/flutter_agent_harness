import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('collectKeyStack', () {
    test('collects the base name then numbered suffixes in order', () {
      final stack = collectKeyStack({
        'OPENAI_API_KEY': 'k1',
        'OPENAI_API_KEY_2': 'k2',
        'OPENAI_API_KEY_10': 'k10',
        'OPENAI_API_KEY_3': 'k3',
        'OTHER_KEY': 'x',
      }, 'OPENAI_API_KEY');
      expect(stack.map((c) => c.name), [
        'OPENAI_API_KEY',
        'OPENAI_API_KEY_2',
        'OPENAI_API_KEY_3',
        'OPENAI_API_KEY_10',
      ]);
      expect(stack.map((c) => c.value), ['k1', 'k2', 'k3', 'k10']);
    });

    test('skips empty values and tolerates gaps', () {
      final stack = collectKeyStack({'K': 'k1', 'K_2': '', 'K_5': 'k5'}, 'K');
      expect(stack.map((c) => c.name), ['K', 'K_5']);
    });

    test('returns empty when no key matches the base name', () {
      expect(collectKeyStack({'OTHER': 'x'}, 'K'), isEmpty);
    });

    test('numbered keys alone form a stack without the bare name', () {
      final stack = collectKeyStack({'K_2': 'k2', 'K_3': 'k3'}, 'K');
      // The bare name is preferred but not required for a stack to exist.
      expect(stack.map((c) => c.name), ['K_2', 'K_3']);
    });
  });

  group('ApiKeyRing', () {
    ApiKeyRing ring({int keys = 3, int? startIndex, DateTime Function()? now}) {
      return ApiKeyRing(
        baseName: 'K',
        credentials: [
          for (var i = 1; i <= keys; i++) ApiKeyCredential('K_$i', 'v$i'),
        ],
        startIndex: startIndex,
        now: now,
      );
    }

    test('requires at least one credential', () {
      expect(
        () => ApiKeyRing(baseName: 'K', credentials: const []),
        throwsArgumentError,
      );
    });

    test('session affinity: the current key stays put until it fails', () {
      final r = ring(startIndex: 1);
      expect(r.currentCredential.name, 'K_2');
      expect(r.availableCredential!.name, 'K_2');
      expect(r.availableCredential!.name, 'K_2');
    });

    test('round-robin start: new rings start one slot later per base name', () {
      // Fresh base name for this test to isolate the static counter.
      final base = 'RR_${DateTime.now().microsecondsSinceEpoch}';
      final first = ApiKeyRing(
        baseName: base,
        credentials: const [
          ApiKeyCredential('a', '1'),
          ApiKeyCredential('b', '2'),
          ApiKeyCredential('c', '3'),
        ],
      );
      final second = ApiKeyRing(
        baseName: base,
        credentials: const [
          ApiKeyCredential('a', '1'),
          ApiKeyCredential('b', '2'),
          ApiKeyCredential('c', '3'),
        ],
      );
      expect(first.currentCredential.name, 'a');
      expect(second.currentCredential.name, 'b');
    });

    test('availableCredential skips keys in backoff', () {
      var now = DateTime.utc(2026);
      final r = ring(startIndex: 0, now: () => now);
      r.reportRateLimited('K_1', const Duration(minutes: 1));
      expect(r.availableCredential!.name, 'K_2');
      // Affinity moved to the healthy key.
      expect(r.availableCredential!.name, 'K_2');
      r.reportRateLimited('K_2', const Duration(minutes: 1));
      expect(r.availableCredential!.name, 'K_3');
      r.reportRateLimited('K_3', const Duration(minutes: 1));
      expect(r.availableCredential, isNull);
      // Backoff expiry frees keys again.
      now = now.add(const Duration(minutes: 2));
      expect(r.availableCredential, isNotNull);
    });

    test('rotate advances past the failing key round-robin', () {
      final r = ring(startIndex: 0);
      expect(r.rotate('K_1')!.name, 'K_2');
      expect(r.rotate('K_2')!.name, 'K_3');
      expect(r.rotate('K_3')!.name, 'K_1');
      r.reportRateLimited('K_1', const Duration(minutes: 5));
      expect(r.rotate('K_3')!.name, 'K_2');
    });

    test('rotate returns null when every key is benched', () {
      final r = ring(keys: 2, startIndex: 0);
      r.reportRateLimited('K_1', const Duration(minutes: 1));
      r.reportRateLimited('K_2', const Duration(minutes: 1));
      expect(r.rotate('K_1'), isNull);
    });

    test('earliestBackoffEnd reports the soonest free moment', () {
      var now = DateTime.utc(2026);
      final r = ring(startIndex: 0, now: () => now);
      expect(r.earliestBackoffEnd, isNull);
      r.reportRateLimited('K_1', const Duration(minutes: 2));
      r.reportRateLimited('K_2', const Duration(minutes: 1));
      expect(r.earliestBackoffEnd, now.add(const Duration(minutes: 1)));
      now = now.add(const Duration(minutes: 1, seconds: 1));
      expect(r.earliestBackoffEnd, now.add(const Duration(seconds: 59)));
    });

    test('stickTo pins affinity to a credential', () {
      final r = ring(startIndex: 0);
      r.stickTo(const ApiKeyCredential('K_3', 'v3'));
      expect(r.currentCredential.name, 'K_3');
      r.stickTo(const ApiKeyCredential('unknown', 'x'));
      expect(r.currentCredential.name, 'K_3');
    });

    test('fromSecrets returns null without keys and builds otherwise', () {
      expect(ApiKeyRing.fromSecrets(const {}, 'K'), isNull);
      final r = ApiKeyRing.fromSecrets(
        const {'K': 'v', 'K_2': 'v2'},
        'K',
        startIndex: 0,
      );
      expect(r, isNotNull);
      expect(r!.length, 2);
      expect(r.currentCredential.name, 'K');
    });
  });
}

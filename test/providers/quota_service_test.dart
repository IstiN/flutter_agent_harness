// IT-3..6 for issue #823: ProviderQuotaService (AC3, AC7, AC8 feed, E3-E6).
// Fake clock throughout; no real IO anywhere.
import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

class FakeAdapter implements QuotaAdapter {
  FakeAdapter(this.onFetch);
  int calls = 0;
  final Future<QuotaFetchResult> Function() onFetch;

  @override
  Future<QuotaFetchResult> fetch() async {
    calls++;
    return onFetch();
  }
}

QuotaFetchResult metered({
  double used = 48.2,
  double limit = 150,
  DateTime? resetsAt,
}) => QuotaFetchResult.ok(
  ProviderQuota(used: used, limit: limit, resetsAt: resetsAt),
);

void main() {
  var t = DateTime.utc(2026, 9, 30, 6, 30);
  DateTime fakeNow() => t;

  ProviderQuotaService serviceWith({
    Map<String, QuotaAdapter> adapters = const {},
    Set<String> unmeteredProviders = const {},
    Duration ttl = const Duration(minutes: 15),
  }) => ProviderQuotaService(
    adapters: adapters,
    unmeteredProviders: unmeteredProviders,
    now: fakeNow,
    ttl: ttl,
  );

  setUp(() {
    t = DateTime.utc(2026, 9, 30, 6, 30);
  });

  group('IT-3 TTL cache with a fake clock (AC3)', () {
    test('entry cached within ttl, refetched past ttl', () async {
      final adapter = FakeAdapter(() async => metered());
      final service = serviceWith(adapters: {'openrouter': adapter});

      await service.quotaFor('openrouter');
      expect(adapter.calls, 1);

      t = t.add(const Duration(minutes: 14));
      await service.quotaFor('openrouter');
      expect(adapter.calls, 1, reason: 'inside 15 min ttl');

      t = t.add(const Duration(minutes: 2));
      await service.quotaFor('openrouter');
      expect(adapter.calls, 2, reason: 'ttl expired');
    });

    test('forceRefresh bypasses the ttl', () async {
      final adapter = FakeAdapter(() async => metered());
      final service = serviceWith(adapters: {'openrouter': adapter});

      await service.quotaFor('openrouter');
      await service.quotaFor('openrouter', forceRefresh: true);
      expect(adapter.calls, 2);
    });

    test('concurrent callers coalesce to one fetch', () async {
      final gate = Completer<QuotaFetchResult>();
      final adapter = FakeAdapter(() => gate.future);
      final service = serviceWith(adapters: {'openrouter': adapter});

      final a = service.quotaFor('openrouter');
      final b = service.quotaFor('openrouter');
      final c = service.refresh('openrouter');
      expect(adapter.calls, 1, reason: 'in-flight fetch is shared');

      gate.complete(metered());
      final results = await Future.wait([a, b, c]);
      for (final r in results) {
        expect(r.quota!.limit, 150);
      }
      expect(adapter.calls, 1);
    });
  });

  group('IT-3 hanging fetch never blocks (AC3)', () {
    test(
      'peek returns null immediately while fetch hangs; stream completes',
      () async {
        final gate = Completer<QuotaFetchResult>();
        final adapter = FakeAdapter(() => gate.future);
        final service = serviceWith(adapters: {'openrouter': adapter});

        final peeked = service.peek('openrouter');
        expect(peeked, isNull, reason: 'cold cache renders … without awaiting');

        // The chat hot path: a streaming turn completes while the quota fetch
        // is still hanging.
        var streamDone = false;
        Future<void> chatTurn() async {
          await Future<void>.delayed(Duration.zero);
          await Future<void>.delayed(Duration.zero);
          streamDone = true;
        }

        await chatTurn();
        expect(streamDone, isTrue);
        expect(gate.isCompleted, isFalse);

        gate.complete(metered());
        await pumpEventQueue();
        final fresh = service.peek('openrouter');
        expect(fresh!.quota!.limit, 150);
      },
    );
  });

  group('AC7 unmetered and capability-less providers', () {
    test('unmetered reports silently with zero fetches', () async {
      final adapter = FakeAdapter(() async => metered());
      final service = serviceWith(
        adapters: {'openrouter': adapter},
        unmeteredProviders: {'dial', 'ollama'},
      );
      final result = await service.quotaFor('dial');
      expect(result.quota!.isUnmetered, isTrue);
      expect(adapter.calls, 0);
      expect(service.peek('ollama')!.quota!.isUnmetered, isTrue);
    });

    test('capability-less provider renders unknown, never throws', () async {
      final adapter = FakeAdapter(() async => metered());
      final service = serviceWith(
        adapters: {'openrouter': adapter},
        unmeteredProviders: {'dial'},
      );
      final result = await service.quotaFor('anthropic');
      expect(result.quota, isNull);
      expect(result.reason, isNotNull);
      expect(service.peek('anthropic')!.isUnknown, isTrue);
    });
  });

  group('E3 expired key: one attempt per refresh, no retry storm', () {
    test('401 result cached for the ttl, single endpoint hit', () async {
      final adapter = FakeAdapter(
        () async => QuotaFetchResult.unknown('HTTP 401'),
      );
      final service = serviceWith(adapters: {'openrouter': adapter});

      final first = await service.quotaFor('openrouter');
      expect(first.reason, 'HTTP 401');
      await service.quotaFor('openrouter');
      service.peek('openrouter');
      expect(adapter.calls, 1, reason: 'no retry storm inside ttl');

      t = t.add(const Duration(minutes: 16));
      await service.quotaFor('openrouter');
      expect(adapter.calls, 2, reason: 'exactly one new attempt after ttl');
    });
  });

  group('E4 past resetsAt auto-invalidates the cache entry', () {
    test('stale limit after billing reset does not persist', () async {
      // First fetch reports a reset already in the future.
      final resetAt = t.add(const Duration(minutes: 10));
      final gated = FakeAdapter(() async => metered(resetsAt: resetAt));
      final service2 = serviceWith(adapters: {'openrouter': gated});
      await service2.quotaFor('openrouter');
      expect(gated.calls, 1);

      // Clock passes the reset: entry must be invalidated.
      t = resetAt.add(const Duration(minutes: 1));
      expect(
        service2.peek('openrouter'),
        isNull,
        reason: 'reset overdue entry dropped',
      );
      await pumpEventQueue();
      expect(gated.calls, 2, reason: 'background refetch kicked');
      expect(formatQuotaReset(resetAt, t), 'reset overdue');
    });
  });

  group('E5 provider removed from config mid-session', () {
    test('retainOnly drops orphan cache entries', () async {
      final orphan = FakeAdapter(() async => metered(used: 150, limit: 150));
      final service = serviceWith(
        adapters: {
          'openrouter': FakeAdapter(() async => metered()),
          'removed-provider': orphan,
        },
      );
      await service.quotaFor('openrouter');
      await service.quotaFor('removed-provider');
      expect(service.isDepleted('removed-provider'), isTrue);

      service.retainOnly({'openrouter'});
      expect(
        service.isDepleted('removed-provider'),
        isFalse,
        reason: 'orphan cache entry dropped, cannot steer anything',
      );
      expect(
        service.peek('openrouter')!.quota,
        isNotNull,
        reason: 'configured provider keeps its entry',
      );
    });
  });

  group('E6 concurrent refresh spam coalesces', () {
    test('five concurrent refreshes hit the endpoint once', () async {
      final gate = Completer<QuotaFetchResult>();
      final adapter = FakeAdapter(() => gate.future);
      final service = serviceWith(adapters: {'openrouter': adapter});

      final turns = List.generate(5, (_) => service.refresh('openrouter'));
      expect(adapter.calls, 1);
      gate.complete(metered());
      await Future.wait(turns);
      expect(adapter.calls, 1);
    });
  });

  group('fetch timeout bounds every adapter (review round 1)', () {
    test(
      'a hung endpoint degrades to unknown(timeout), never wedges',
      () async {
        // A dedicated service with a tiny bound: the fetch must resolve to a
        // cached unknown well under the test timeout.
        final bounded = ProviderQuotaService(
          adapters: {
            'openrouter': FakeAdapter(
              () => Completer<QuotaFetchResult>().future,
            ),
          },
          now: fakeNow,
          fetchTimeout: const Duration(milliseconds: 30),
        );
        final result = await bounded.refresh('openrouter');
        expect(result.quota, isNull);
        expect(result.reason, 'timeout');
        // The failure is cached like any unknown: peek is terminal, no storm.
        expect(bounded.peek('openrouter')!.reason, 'timeout');
      },
    );

    test(
      'hasSource gates badge surfaces: adapter or unmetered marking',
      () async {
        final service = serviceWith(
          adapters: {'openrouter': FakeAdapter(() async => metered())},
          unmeteredProviders: {'dial'},
        );
        expect(service.hasSource('openrouter'), isTrue);
        expect(service.hasSource('dial'), isTrue);
        expect(
          service.hasSource('anthropic'),
          isFalse,
          reason: 'adapter-less providers never badge',
        );
      },
    );
  });

  group('AC8 QuotaFeed depletion signal (soft, resolver-facing)', () {
    test(
      'isDepleted true only for fresh, exhausted, metered entries',
      () async {
        final adapter = FakeAdapter(() async => metered(used: 150, limit: 150));
        final service = serviceWith(adapters: {'openrouter': adapter});

        expect(
          service.isDepleted('openrouter'),
          isFalse,
          reason: 'nothing fetched yet',
        );
        await service.quotaFor('openrouter');
        expect(service.isDepleted('openrouter'), isTrue);

        t = t.add(const Duration(minutes: 16));
        expect(
          service.isDepleted('openrouter'),
          isFalse,
          reason: 'stale entries must not steer the resolver',
        );
      },
    );

    test('unmetered and unknown providers are never depleted', () async {
      final service = serviceWith(
        unmeteredProviders: {'dial'},
        adapters: {
          'openrouter': FakeAdapter(
            () async => QuotaFetchResult.unknown('HTTP 401'),
          ),
        },
      );
      expect(service.isDepleted('dial'), isFalse);
      await service.quotaFor('openrouter');
      expect(
        service.isDepleted('openrouter'),
        isFalse,
        reason: 'unknown is not depleted',
      );
    });
  });

  group('service robustness', () {
    test('a throwing adapter degrades to unknown, never propagates', () async {
      final adapter = FakeAdapter(() async => throw StateError('bug'));
      final service = serviceWith(adapters: {'openrouter': adapter});
      final result = await service.quotaFor('openrouter');
      expect(result.quota, isNull);
      expect(result.reason, isNotNull);
    });

    test('refresh of an unknown provider is a safe unknown', () async {
      final service = serviceWith();
      final result = await service.refresh('ghost');
      expect(result.quota, isNull);
      expect(result.reason, isNotNull);
    });

    test('default wall clock serves static results without injection', () {
      final service = ProviderQuotaService(unmeteredProviders: {'dial'});
      expect(service.peek('dial')!.quota!.isUnmetered, isTrue);
    });

    test('changes fires after a completed fetch (UI invalidation)', () async {
      final adapter = FakeAdapter(() async => metered());
      final service = serviceWith(adapters: {'openrouter': adapter});
      final events = <void>[];
      final sub = service.changes.listen(events.add);
      await service.quotaFor('openrouter');
      await pumpEventQueue();
      expect(events, hasLength(1));
      await sub.cancel();
    });
  });
}

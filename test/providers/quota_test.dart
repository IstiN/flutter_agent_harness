// UT-1..3 for issue #823: ProviderQuota model + QuotaUnit (pure, no IO).
//
// UT-1 — serialization round-trip; unknown vs unmetered distinct (AC1).
// UT-2 — rendered strings: `$48.20/$150`, `1840/2000`, `11d` (AC4/E2 edge).
// UT-3 — null-limit => no-cap semantics (AC2).
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 30, 6, 30);

  group('UT-1 ProviderQuota serialization (AC1)', () {
    test('metered quota round-trips', () {
      final q = ProviderQuota(
        used: 48.2,
        limit: 150,
        unit: QuotaUnit.currencyUsd,
        resetsAt: DateTime.utc(2026, 10, 11),
        updatedAt: now,
      );
      final r = ProviderQuota.fromJson(q.toJson());
      expect(r.used, 48.2);
      expect(r.limit, 150);
      expect(r.unit, QuotaUnit.currencyUsd);
      expect(r.resetsAt, q.resetsAt);
      expect(r.updatedAt, q.updatedAt);
      expect(r.isUnmetered, isFalse);
    });

    test('requests unit round-trips', () {
      final q = ProviderQuota(
        used: 160,
        limit: 2000,
        unit: QuotaUnit.requests,
        updatedAt: now,
      );
      final r = ProviderQuota.fromJson(q.toJson());
      expect(r.unit, QuotaUnit.requests);
      expect(r.used, 160);
      expect(r.limit, 2000);
      expect(r.resetsAt, isNull);
    });

    test('unmetered round-trips and keeps its unit', () {
      final q = ProviderQuota.unmetered(updatedAt: now);
      final r = ProviderQuota.fromJson(q.toJson());
      expect(r.isUnmetered, isTrue);
      expect(r.unit, QuotaUnit.unmetered);
      expect(r.toJson()['unit'], 'unmetered');
    });

    test('unknown and unmetered are distinct states', () {
      final unknown = QuotaFetchResult.unknown('HTTP 401');
      final unmetered = QuotaFetchResult.ok(ProviderQuota.unmetered(updatedAt: now));
      expect(unknown.quota, isNull);
      expect(unknown.isUnknown, isTrue);
      expect(unmetered.quota, isNotNull);
      expect(unmetered.quota!.isUnmetered, isTrue);
      expect(unmetered.isUnknown, isFalse);
      expect(unmetered.reason, isNull);
      expect(unknown.reason, 'HTTP 401');
    });

    test('fromJson tolerates missing optional fields', () {
      final r = ProviderQuota.fromJson({
        'used': 1.0,
        'limit': 2.0,
        'unit': 'requests',
        'updatedAt': now.toIso8601String(),
      });
      expect(r.resetsAt, isNull);
      expect(r.isUnmetered, isFalse);
    });

    test('fromJson falls back to epoch when updatedAt is absent', () {
      final r = ProviderQuota.fromJson({'used': 1.0, 'limit': 2.0});
      expect(r.updatedAt, DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
    });

    test('unknown unit strings fall back to currencyUsd', () {
      expect(QuotaUnit.fromJson('bogus'), QuotaUnit.currencyUsd);
      expect(QuotaUnit.fromJson(null), QuotaUnit.currencyUsd);
    });

    test('toString renders via the shared formatters', () {
      final q = ProviderQuota(used: 48.2, limit: 150, updatedAt: now);
      expect(q.toString(), contains(r'$48.20/$150'));
      final unknown = QuotaFetchResult.unknown('HTTP 401');
      expect(unknown.toString(), contains('HTTP 401'));
      expect(
        QuotaFetchResult.ok(q).toString(),
        contains('QuotaFetchResult'),
      );
    });
  });

  group('UT-2 rendered strings (AC4/E2)', () {
    test(r'currency renders $48.20/$150', () {
      final q = ProviderQuota(used: 48.2, limit: 150, updatedAt: now);
      expect(formatQuotaAmount(48.2, QuotaUnit.currencyUsd), r'$48.20');
      expect(formatQuotaAmount(150, QuotaUnit.currencyUsd), r'$150');
      expect(formatQuotaUsedLimit(q), r'$48.20/$150');
    });

    test('requests render 1840/2000', () {
      final q = ProviderQuota(
        used: 1840,
        limit: 2000,
        unit: QuotaUnit.requests,
        updatedAt: now,
      );
      expect(formatQuotaAmount(1840, QuotaUnit.requests), '1840');
      expect(formatQuotaUsedLimit(q), '1840/2000');
    });

    test('tokens render plain integers', () {
      final q = ProviderQuota(
        used: 1234,
        limit: 8000,
        unit: QuotaUnit.tokens,
        updatedAt: now,
      );
      expect(formatQuotaUsedLimit(q), '1234/8000');
    });

    test('reset countdown renders 11d / hours / minutes', () {
      expect(formatQuotaReset(now.add(const Duration(days: 11)), now), '11d');
      expect(formatQuotaReset(now.add(const Duration(hours: 5)), now), '5h');
      expect(formatQuotaReset(now.add(const Duration(minutes: 3)), now), '3m');
      expect(formatQuotaReset(now.add(const Duration(seconds: 30)), now), '<1m');
    });

    test('overdue reset renders reset overdue (E4)', () {
      expect(
        formatQuotaReset(now.subtract(const Duration(hours: 1)), now),
        'reset overdue',
      );
    });

    test('null reset renders empty, never a null literal (E2)', () {
      expect(formatQuotaReset(null, now), '');
      expect(formatQuotaUsedLimit(null), 'unknown');
      expect(formatQuotaUsedLimit(null), isNot(contains('null')));
    });

    test(r'badge renders [OR $48/$150 · 11d] for a metered provider', () {
      final q = ProviderQuota(
        used: 48.2,
        limit: 150,
        resetsAt: now.add(const Duration(days: 11)),
        updatedAt: now,
      );
      expect(
        formatQuotaBadge(shortName: 'OR', quota: q, now: now),
        r'[OR $48/$150 · 11d]',
      );
    });

    test('badge renders ellipsis on cold cache, silent for unmetered', () {
      expect(formatQuotaBadge(shortName: 'OR', quota: null, now: now), '[OR …]');
      expect(
        formatQuotaBadge(
          shortName: 'DL',
          quota: ProviderQuota.unmetered(updatedAt: now),
          now: now,
        ),
        '',
      );
    });

    test(r'badge renders unlimited, used-only, and requests forms', () {
      expect(
        formatQuotaBadge(
          shortName: 'OR',
          quota: ProviderQuota(updatedAt: now),
          now: now,
        ),
        '[OR unlimited]',
      );
      expect(
        formatQuotaBadge(
          shortName: 'OR',
          quota: ProviderQuota(used: 48.2, updatedAt: now),
          now: now,
        ),
        r'[OR $48/no cap]',
      );
      expect(
        formatQuotaBadge(
          shortName: 'GH',
          quota: ProviderQuota(
            used: 160,
            limit: 2000,
            unit: QuotaUnit.requests,
            resetsAt: now.add(const Duration(days: 3)),
            updatedAt: now,
          ),
          now: now,
        ),
        '[GH 160/2000 · 3d]',
      );
    });
  });

  group('UT-3 null-limit semantics (AC2)', () {
    test('used with null limit renders no cap', () {
      final q = ProviderQuota(used: 48.2, limit: null, updatedAt: now);
      expect(q.limit, isNull);
      expect(q.remaining, isNull);
      expect(q.isDepleted, isFalse);
      expect(formatQuotaUsedLimit(q), r'$48.20/no cap');
    });

    test('neither used nor limit renders unlimited', () {
      final q = ProviderQuota(updatedAt: now);
      expect(formatQuotaUsedLimit(q), 'unlimited');
    });

    test('unknown usage under a known limit never renders null (E2)', () {
      final q = ProviderQuota(used: null, limit: 150, updatedAt: now);
      final s = formatQuotaUsedLimit(q);
      expect(s, isNot(contains('null')));
      expect(s, r'…/$150');
    });

    test('depletion and remaining derivation', () {
      expect(
        ProviderQuota(used: 150, limit: 150, updatedAt: now).isDepleted,
        isTrue,
      );
      expect(
        ProviderQuota(used: 160, limit: 150, updatedAt: now).isDepleted,
        isTrue,
      );
      expect(
        ProviderQuota(used: 48.2, limit: 150, updatedAt: now).remaining,
        101.8,
      );
      expect(ProviderQuota(used: null, limit: 150, updatedAt: now).isDepleted,
          isFalse);
      expect(ProviderQuota.unmetered(updatedAt: now).isDepleted, isFalse);
    });

    test('reset overdue detection for cache invalidation (E4)', () {
      final q = ProviderQuota(
        used: 1,
        limit: 2,
        resetsAt: now.subtract(const Duration(minutes: 1)),
        updatedAt: now,
      );
      expect(q.isResetOverdue(now), isTrue);
      expect(q.isResetOverdue(now.subtract(const Duration(minutes: 2))), isFalse);
      expect(ProviderQuota(used: 1, limit: 2, updatedAt: now).isResetOverdue(now),
          isFalse);
    });
  });
}

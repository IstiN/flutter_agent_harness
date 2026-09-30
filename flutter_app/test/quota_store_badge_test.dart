// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// QuotaStore badge contract (issue #823 app surface): faked adapter, no
// network — cold renders `[OR …]`, metered renders the remaining string,
// unmetered and non-quota endpoints render nothing.
import 'package:fa/services/quota_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAdapter implements QuotaAdapter {
  QuotaFetchResult next = const QuotaFetchResult.unknown('HTTP 401');

  @override
  Future<QuotaFetchResult> fetch() async => next;
}

void main() {
  const orUrl = 'https://openrouter.ai/api/v1';

  test(r'badge: cold → [OR …], metered → [OR $48/$150], unmetered → none', () async {
    // Non-quota endpoints never badge.
    final adapter = _FakeAdapter();
    final store = QuotaStore.forTest(
      ProviderQuotaService(adapters: {'openrouter': adapter}),
    );
    expect(store.badgeForBaseUrl('https://example.com/v1'), isNull);

    // Metered: one real fetch, then the remaining string.
    adapter.next = QuotaFetchResult.ok(ProviderQuota(used: 48.2, limit: 150));
    await store.service.refresh('openrouter');
    expect(store.badgeForBaseUrl(orUrl), r'[OR $48/$150]');

    // Cold cache on a fresh store — synchronous ellipsis form.
    final cold = QuotaStore.forTest(
      ProviderQuotaService(adapters: {'openrouter': _FakeAdapter()}),
    );
    expect(cold.badgeForBaseUrl(orUrl), '[OR …]');

    // Unmetered stays silent (no chip).
    final silent = QuotaStore.forTest(
      ProviderQuotaService(unmeteredProviders: {'openrouter'}),
    );
    expect(silent.badgeForBaseUrl(orUrl), isNull);
  });
}

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
  _FakeAdapter({this.next = const QuotaFetchResult.unknown('HTTP 401')});

  QuotaFetchResult next;

  @override
  Future<QuotaFetchResult> fetch() async => next;
}

void main() {
  const orUrl = 'https://openrouter.ai/api/v1';

  test(
    r'badge: cold → [OR …], metered → [OR $48/$150], unmetered → none',
    () async {
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

      // Dark CodeMie adapter (endpoint not pinned, review round 1): a
      // terminal unknown must never pin a `[CodeMie …]` to the header.
      const cmUrl = 'https://codemie.lab.example/code-assistant-api/v1';
      final dark = QuotaStore.forTest(
        ProviderQuotaService(
          adapters: {
            'codemie': _FakeAdapter(
              next: const QuotaFetchResult.unknown('endpoint not pinned'),
            ),
          },
        ),
      );
      await dark.service.refresh('codemie');
      expect(
        dark.badgeForBaseUrl(cmUrl),
        isNull,
        reason: 'dark adapter renders no header badge',
      );

      // Adapter-less ids are equally silent (no source, no fetch, no badge).
      final sourceless = QuotaStore.forTest(
        ProviderQuotaService(adapters: {
          'openrouter': _FakeAdapter(),
        }),
      );
      expect(sourceless.badgeForBaseUrl(cmUrl), isNull,
          reason: 'no codemie adapter: peek is terminal unknown, never cold');
    },
  );

  test('app-side fetch timeout is the generous 12s default (review round 2)',
      () {
    // The app runs on mobile networks where >5s to reach the endpoint is
    // normal; a timeout caches as an unknown for the full TTL, so the
    // shared instance must not inherit the CLI's tight 5s bound.
    expect(
      QuotaStore.instance.service.fetchTimeout,
      const Duration(seconds: 12),
    );
  });
}

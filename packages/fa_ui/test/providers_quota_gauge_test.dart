// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// W-IT-1..2 for issue #823: the providers-list quota gauge states and
// pull-to-refresh over every configured quota source. Faked quota service
// (real ProviderQuotaService + a gated adapter double) — no network.
import 'dart:async';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [QuotaAdapter] double: counts fetches; the first fetch blocks on
/// [release] so cold→data transitions are deterministic.
class _FakeQuotaAdapter implements QuotaAdapter {
  _FakeQuotaAdapter(this.result);

  int calls = 0;
  QuotaFetchResult result;
  final Completer<QuotaFetchResult> _gate = Completer<QuotaFetchResult>();

  /// Releases the pending (and every later) fetch with [result].
  void release() => _gate.complete(result);

  @override
  Future<QuotaFetchResult> fetch() async {
    calls++;
    return _gate.future;
  }
}

ProviderQuota _meteredQuota() => ProviderQuota(
  used: 48.2,
  limit: 150,
  // +12h headroom so the render-clock skew never drops the day count.
  resetsAt: DateTime.now().add(const Duration(days: 11, hours: 12)),
);

ProvidersSection _section(
  ProviderRegistry registry,
  ProviderQuotaService? quotas, {
  List<FaOnDeviceRoute> onDeviceProviders = const [],
}) => ProvidersSection(
  registry: registry,
  quotas: quotas,
  onDeviceProviders: onDeviceProviders,
);

Future<void> _pumpSection(WidgetTester tester, ProvidersSection section) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: section)));
}

void main() {
  const orBaseUrl = 'https://openrouter.ai/api/v1';
  const cmBaseUrl = 'https://auth.codemie.lab.epam.com/code-assistant-api';

  group('W-IT-1 gauge states', () {
    testWidgets('cold renders … then metered bar+text when the fetch lands', (
      tester,
    ) async {
      final adapter = _FakeQuotaAdapter(QuotaFetchResult.ok(_meteredQuota()));
      final service = ProviderQuotaService(adapters: {'openrouter': adapter});
      final registry = ProviderRegistry.inMemory();
      final provider = await registry.add(
        name: 'OpenRouter',
        baseUrl: orBaseUrl,
        modelId: 'm',
      );
      // The gauge renders for CONNECTED rows only (review round 1).
      registry.rememberKey(provider.id, 'k');

      await _pumpSection(tester, _section(registry, service));

      // Cold cache: synchronous ellipsis; the peek kicked exactly one
      // background refresh (no storm).
      expect(find.text('…'), findsOneWidget);
      expect(adapter.calls, 1);

      adapter.release();
      await tester.pumpAndSettle();

      expect(find.text(r'$48.20/$150 · 11d'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('unmetered renders the silent label', (tester) async {
      final service = ProviderQuotaService(unmeteredProviders: {'webllm'});
      await _pumpSection(
        tester,
        _section(
          ProviderRegistry.inMemory(),
          service,
          onDeviceProviders: [
            FaOnDeviceRoute(
              label: 'WebLLM (browser)',
              id: 'webllm',
              pageBuilder: (context, onApply) => const SizedBox.shrink(),
            ),
          ],
        ),
      );

      expect(find.text('unmetered'), findsOneWidget);
    });

    testWidgets('unknown result renders the reason without crashing', (
      tester,
    ) async {
      final adapter = _FakeQuotaAdapter(
        const QuotaFetchResult.unknown('HTTP 401'),
      );
      final service = ProviderQuotaService(adapters: {'openrouter': adapter});
      final registry = ProviderRegistry.inMemory();
      final provider = await registry.add(
        name: 'OpenRouter',
        baseUrl: orBaseUrl,
        modelId: 'm',
      );
      registry.rememberKey(provider.id, 'k');

      await _pumpSection(tester, _section(registry, service));
      expect(find.text('…'), findsOneWidget);

      adapter.release();
      await tester.pumpAndSettle();

      expect(find.text('unknown (HTTP 401)'), findsOneWidget);
    });

    testWidgets('no quota store renders no gauge at all', (tester) async {
      final registry = ProviderRegistry.inMemory();
      await registry.add(name: 'OpenRouter', baseUrl: orBaseUrl, modelId: 'm');

      await _pumpSection(tester, _section(registry, null));

      expect(find.text('…'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });
  });

  group('W-IT-2 pull-to-refresh', () {
    testWidgets('refreshes every configured provider with a quota source', (
      tester,
    ) async {
      final or = _FakeQuotaAdapter(QuotaFetchResult.ok(_meteredQuota()));
      final cm = _FakeQuotaAdapter(
        QuotaFetchResult.ok(ProviderQuota(used: 1, limit: 2)),
      );
      or.release();
      cm.release();
      final service = ProviderQuotaService(
        adapters: {'openrouter': or, 'codemie': cm},
      );
      final registry = ProviderRegistry.inMemory();
      final orProvider = await registry.add(
        name: 'OpenRouter',
        baseUrl: orBaseUrl,
        modelId: 'a',
      );
      final cmProvider = await registry.add(
        name: 'CodeMie',
        baseUrl: cmBaseUrl,
        modelId: 'b',
      );
      // Connected rows only are gauged and refreshed (review round 1).
      registry.rememberKey(orProvider.id, 'k');
      registry.rememberKey(cmProvider.id, 'k');

      await _pumpSection(tester, _section(registry, service));
      // The build-time cold peeks already fetched once (released above).
      await tester.pumpAndSettle();
      expect(or.calls, 1);
      expect(cm.calls, 1);

      // Pull-to-refresh over the providers list.
      await tester.fling(find.byType(ListView), const Offset(0, 300), 1200);
      await tester.pump();
      await tester.pumpAndSettle();

      expect(or.calls, 2, reason: 'pull-to-refresh re-fetches openrouter');
      expect(cm.calls, 2, reason: 'pull-to-refresh re-fetches codemie');
    });

    testWidgets('unconnected custom row renders no gauge and is not '
        'refreshed (review round 1)', (tester) async {
      final or = _FakeQuotaAdapter(QuotaFetchResult.ok(_meteredQuota()));
      final service = ProviderQuotaService(adapters: {'openrouter': or});
      final registry = ProviderRegistry.inMemory();
      // No rememberKey: the row exists but has no stored connection.
      await registry.add(name: 'OpenRouter', baseUrl: orBaseUrl, modelId: 'm');

      await _pumpSection(tester, _section(registry, service));
      await tester.pumpAndSettle();

      // A doomed `unknown (no api key)` must not render, and the adapter
      // must never be hit for a row the user has not connected.
      expect(find.text('…'), findsNothing);
      expect(find.textContaining('unknown'), findsNothing);
      expect(or.calls, 0);

      await tester.fling(find.byType(ListView), const Offset(0, 300), 1200);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(or.calls, 0, reason: 'pull-to-refresh skips unconnected rows');
    });
  });
}

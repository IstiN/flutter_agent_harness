// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart' show providerMarkKeyForBaseUrl;
import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;

import '../gemma/gemma_types.dart' show gemmaProviderKind;
import 'provider_registry.dart';
import '../transformers_js/transformers_js_types.dart'
    show transformersJsProviderKind;
import '../webllm/webllm_types.dart' show webLlmProviderKind;

/// App-wide view of provider quota (issue #823): builds the
/// [ProviderQuotaService] over the app's stored keys (OpenRouter live,
/// CodeMie dark until its endpoint is pinned), bridges the service's
/// `changes` stream into ChangeNotifier so header/list surfaces repaint,
/// and renders the active provider's header badge.
///
/// The app-side fetch timeout is deliberately more generous (12s vs the
/// CLI's 5s, review round 2): on mobile a constrained network can
/// legitimately take >5s to reach the endpoint, and a timeout caches as
/// an unknown for the full TTL — one slow attempt would blank the
/// gauge/badge for 15 minutes.
class QuotaStore extends ChangeNotifier {
  QuotaStore._({
    ProviderRegistry? registry,
    ProviderQuotaService? service,
    Duration fetchTimeout = const Duration(seconds: 12),
  }) {
    _registry = registry;
    _service =
        service ??
        ProviderQuotaService(
          adapters: {
            'openrouter': OpenRouterQuotaAdapter(
              client: http.Client(),
              resolveApiKey: () async => _storedKey('openrouter'),
            ),
            'codemie': CodeMieQuotaAdapter(
              client: http.Client(),
              resolveSessionCookie: () async => _storedKey('codemie'),
            ),
          },
          unmeteredProviders: {
            webLlmProviderKind,
            gemmaProviderKind,
            transformersJsProviderKind,
            'dial',
          },
          fetchTimeout: fetchTimeout,
        );
    // The instance lives for the whole app run — no cancellation needed.
    _service.changes.listen((_) => notifyListeners());
  }

  /// The shared instance; boot attaches the persisted registry.
  static final QuotaStore instance = QuotaStore._();

  /// Test seam.
  factory QuotaStore.forTest(ProviderQuotaService service) =>
      QuotaStore._(service: service);

  ProviderRegistry? _registry;
  late final ProviderQuotaService _service;

  /// The underlying service (gauges and the badge read through it).
  ProviderQuotaService get service => _service;

  /// Boot wiring: the persisted registry backs key resolution and prunes
  /// cache entries for providers the registry no longer holds (E5).
  void attachRegistry(ProviderRegistry registry) {
    _registry = registry;
    _service.retainOnly({
      for (final provider in registry.providers)
        if (_markToQuotaId.containsKey(
          providerMarkKeyForBaseUrl(provider.baseUrl),
        ))
          _markToQuotaId[providerMarkKeyForBaseUrl(provider.baseUrl)]!,
    });
  }

  /// The key/cookie stored for the first custom provider on a
  /// quota-marked endpoint — the same registry path the editor writes.
  String? _storedKey(String mark) {
    final registry = _registry;
    if (registry == null) return null;
    for (final provider in registry.providers) {
      if (providerMarkKeyForBaseUrl(provider.baseUrl) == mark) {
        return registry.keyFor(provider.id);
      }
    }
    return null;
  }

  /// Endpoint mark -> quota service id (the two quota-marked endpoints).
  static const _markToQuotaId = {
    'openrouter': 'openrouter',
    'codemie': 'codemie',
  };

  /// The header badge for the ACTIVE provider's endpoint: `[OR $48/$150 ·
  /// 11d]`, `[OR …]` while cold, null when the endpoint has no renderable
  /// badge — unmetered, not a quota-marked provider, or a terminal unknown
  /// (the dark CodeMie adapter must never pin a `[CodeMie …]` to the
  /// header; review round 1).
  String? badgeForBaseUrl(String? baseUrl) {
    final mark = (baseUrl == null || baseUrl.isEmpty)
        ? ''
        : providerMarkKeyForBaseUrl(baseUrl);
    final id = _markToQuotaId[mark];
    if (id == null) return null;
    final result = _service.peek(id);
    // Terminal unknown (dark adapter, rejected auth): no badge — the
    // failure reason lives in the meters, not the compact chrome.
    if (result != null && result.quota == null) return null;
    final badge = formatQuotaBadge(
      shortName: id == 'openrouter' ? 'OR' : 'CodeMie',
      quota: result?.quota,
      now: DateTime.now(),
    );
    return badge.isEmpty ? null : badge;
  }
}

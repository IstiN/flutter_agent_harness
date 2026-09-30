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
class QuotaStore extends ChangeNotifier {
  QuotaStore._({ProviderRegistry? registry, ProviderQuotaService? service}) {
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

  /// Boot wiring: the persisted registry backs key resolution.
  void attachRegistry(ProviderRegistry registry) => _registry = registry;

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

  /// The header badge for the ACTIVE provider's endpoint: `[OR $48/$150 ·
  /// 11d]`, `[OR …]` while cold, null when the endpoint has no quota badge
  /// (unmetered, or not a quota-marked provider).
  String? badgeForBaseUrl(String? baseUrl) {
    final mark = (baseUrl == null || baseUrl.isEmpty)
        ? ''
        : providerMarkKeyForBaseUrl(baseUrl);
    final String id;
    final String shortName;
    if (mark == 'openrouter') {
      id = 'openrouter';
      shortName = 'OR';
    } else if (mark == 'codemie') {
      id = 'codemie';
      shortName = 'CodeMie';
    } else {
      return null;
    }
    final badge = formatQuotaBadge(
      shortName: shortName,
      quota: _service.peek(id)?.quota,
      now: DateTime.now(),
    );
    return badge.isEmpty ? null : badge;
  }
}

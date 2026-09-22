// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:flutter/widgets.dart' show VoidCallback;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:fa_ui/fa_ui.dart' show modelsDispatchHintForEntry;

import 'package:fa/services/analytics.dart';

/// The provider editor's endpoint model quick-select: fetches the
/// endpoint's model list through the core [fetchModelsForEndpoint] dispatch
/// (DIAL deployments, the CodeMie marker, the bundled Codex catalog, the
/// Copilot token exchange, else plain OpenAI `/models`) with a 400 ms
/// debounce on endpoint/key edits and a stale-response guard. Silent on
/// failure — free-text entry always works, the field just loses its
/// suggestions; a bundled-catalog answer drives the field's provenance
/// note. Extracted from the settings form's state (settings.dart line
/// budget, issue #771 review).
final class EndpointModelsController {
  /// Creates the controller. The form wires its state in: [mutate] wraps
  /// the form's `setState` (mounted-guarded), the value callbacks read the
  /// live endpoint fields, [identityKind] surfaces the selected registry
  /// entry's persisted provider identity, [fetchEnabled] gates on-device
  /// presets (no endpoint to fetch), and [overrideFetcher] is the test
  /// seam winning over the dispatch.
  EndpointModelsController({
    required this.mutate,
    required this.baseUrl,
    required this.apiKey,
    required this.identityKind,
    required this.fetchEnabled,
    required this.overrideFetcher,
  });

  final void Function(VoidCallback fn) mutate;
  final String Function() baseUrl;
  final String Function() apiKey;
  final String? Function() identityKind;
  final bool Function() fetchEnabled;
  final ModelsEndpointFetcher? Function() overrideFetcher;

  /// The endpoint's `/models` ids feeding the model field's quick select.
  /// Free text always stays valid (the field is a RawAutocomplete).
  List<String> models = const [];

  /// Endpoint-reported per-model limits (see [parseModelsResponse]),
  /// applied to the [AgentConfig] at connect — same source of truth as the
  /// CLI's auto-correction instead of the hardcoded defaults.
  Map<String, int> contextWindows = const {};
  Map<String, int> maxTokens = const {};
  bool loading = false;

  /// Whether the model list answered from the bundled offline catalog (the
  /// live fetch failed) — drives the field's provenance note.
  bool fromBundledCatalog = false;

  /// Stale-response guard: bumped per fetch, only the latest applies.
  var _generation = 0;
  Timer? _debounce;

  /// Debounced refetch of the endpoint's model list.
  void schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      unawaited(fetch());
    });
  }

  /// Fetches the endpoint's model list through the core dispatch, hinted
  /// by the selected entry's persisted identity over URL matching.
  Future<void> fetch() async {
    if (!fetchEnabled()) return;
    final endpointUrl = baseUrl().trim();
    if (endpointUrl.isEmpty) return;
    final generation = ++_generation;
    mutate(() => loading = true);
    var bundled = false;
    try {
      final key = apiKey().trim();
      final override = overrideFetcher();
      final (ids, windows, caps) = override != null
          ? await override(endpointUrl, apiKey: key)
          : await fetchModelsForEndpoint(
              endpointUrl,
              apiKey: key,
              provider: modelsDispatchHintForEntry(identityKind(), endpointUrl),
              onBundledFallback: () => bundled = true,
            );
      if (generation != _generation) return;
      mutate(() {
        models = ids;
        contextWindows = windows;
        maxTokens = caps;
        fromBundledCatalog = bundled;
      });
      AppAnalytics.instance.modelsFetchResult(ids.length, fromBundled: bundled);
    } on Object {
      if (generation != _generation) return;
      mutate(() {
        models = const [];
        contextWindows = const {};
        maxTokens = const {};
        fromBundledCatalog = false;
      });
    } finally {
      if (generation == _generation) mutate(() => loading = false);
    }
  }

  /// Cancels the pending debounce timer.
  void dispose() {
    _debounce?.cancel();
  }
}

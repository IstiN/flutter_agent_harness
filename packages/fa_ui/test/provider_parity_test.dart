// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cross-surface provider parity guard: every CLI catalog provider must be
/// reachable from the app's "Add provider" picker — the CLI and the app
/// cannot drift apart in what they offer.
///
/// Adding a provider? Add it to BOTH:
/// - `providerCatalog` (lib/src/model_roles/provider_catalog.dart) — the CLI;
/// - `defaultAddProviderPresets` (add_provider_picker.dart) — the app;
/// or exempt it in [appOnlyExemptions] below with a reason (like the
/// settings parity registry in the core).
void main() {
  /// Catalog providers deliberately not listed in the app's add-provider
  /// picker. Comment each with WHY — the CLI-only settings registry pattern.
  const appOnlyExemptions = <String, String>{};

  test('every catalog provider is offered in the app add-provider picker', () {
    final pickerKeys = {
      for (final preset in defaultAddProviderPresets) preset.key,
    };
    for (final spec in providerCatalog.values) {
      if (appOnlyExemptions.containsKey(spec.name)) continue;
      expect(
        pickerKeys,
        contains(spec.name),
        reason:
            '${spec.name} is in the CLI providerCatalog but missing from '
            'defaultAddProviderPresets (fa_ui) — the app cannot add it. Add '
            'an AddProviderPreset or exempt it in appOnlyExemptions with a '
            'reason.',
      );
    }
  });

  test('every picker preset key maps to a real flow', () {
    // Auth-flow presets need a host callback; key-based presets must carry
    // a base URL (the editor's prefill).
    for (final preset in defaultAddProviderPresets) {
      const authFlows = {'codemie', 'chatgpt', 'copilot', 'openrouter'};
      if (authFlows.contains(preset.key) || preset.key == 'custom') {
        continue;
      }
      expect(
        preset.baseUrl,
        isNotNull,
        reason: '${preset.key} is a key-based preset without a baseUrl',
      );
    }
  });

  test('hostedProviderPresets and the add-picker stay in sync for shared '
      'key-based presets', () {
    // The hosted presets drive the model pickers; the add-picker drives the
    // setup flows. A preset listed for adding must also resolve for picking
    // when it is a first-class hosted preset.
    final hosted = {for (final p in hostedProviderPresets) p.name};
    for (final preset in defaultAddProviderPresets) {
      if (preset.key == 'dial') {
        expect(
          hosted,
          contains('dial'),
          reason: 'DIAL must appear in the model pickers too',
        );
      }
    }
  });
}

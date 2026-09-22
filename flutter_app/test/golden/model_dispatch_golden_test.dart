// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

library;

/// Issue #771 golden: the bundled-catalog provenance note — the new
/// user-visible state a codex provider shows when its live model fetch
/// fails. The frame pumps the PRODUCTION dispatch path (401 from the
/// codex wire -> bundled catalog + note), not a `modelsFetcher` override.
///
/// Generate with `flutter test test/golden --update-goldens`; review the
/// PNG by eye before committing.

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'golden_test_helper.dart';

void main() {
  setUpAll(ensureGoldenFonts);

  setUp(
    () => setModelsDispatchClientForTesting(
      MockClient((request) async => http.Response('unauthorized', 401)),
    ),
  );
  tearDown(() => setModelsDispatchClientForTesting(null));

  testWidgets('a stale codex provider lists the bundled catalog with the '
      'provenance note', (tester) async {
    final registry = ProviderRegistry.inMemory();
    final provider = await registry.add(
      name: 'ChatGPT Codex',
      baseUrl: chatGptCodexBaseUrl,
      modelId: 'gpt-5.6-sol',
      kind: 'chatgpt-codex',
    );
    registry.rememberKey(provider.id, 'blob');

    await pumpGolden(
      tester,
      MediaSlotModelPage(
        provider: provider,
        registry: registry,
        initialModel: '',
      ),
      wrap: (child) => Scaffold(body: child),
    );
    await tester.pumpAndSettle();

    // The state under test is actually on screen: bundled ids plus the
    // provenance note, fetched through the production dispatch.
    expect(find.text('gpt-5.6-sol', findRichText: true), findsWidgets);
    expect(find.textContaining('bundled catalog'), findsOneWidget);
    await expectGolden(tester, 'model_dispatch_bundled_note');
  });
}

/// Golden for the AIIN connect flow's model picker (`aiin_connect_flow.dart`).
///
/// The page is private and only renders mid-flow, so the test drives
/// `runAiinConnectFlow` to it with the injectable seams: a fake
/// `aiinConnectFn` (skips the browser/loopback OAuth) and `HttpOverrides`
/// that block the `/v1/models` HTTP call — the flow answers the network
/// failure with its manual-entry picker (the documented offline path).
/// The golden captures the pushed picker page; cancelling it exercises the
/// flow's clean-abort path.
library;

import 'dart:io';

import 'package:fa/services/aiin_connect_flow.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

/// Blocks every dart:io HTTP client so the flow's model fetch fails
/// deterministically (no live network in golden tests).
final class _BlockingHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _ThrowingHttpClient();
}

final class _ThrowingHttpClient implements HttpClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw const SocketException('blocked in golden test');
}

Future<AiinConnectResult> _fakeConnect() async {
  return AiinConnectResult(
    apiKey: const AiinApiKey(
      raw: 'sk-aiin-test',
      id: 'key-1',
      prefix: 'sk-aiin-test',
      createdAt: '2026-01-01T00:00:00Z',
    ),
    tokens: AiinOAuthTokens(
      accessToken: 'access',
      refreshToken: 'refresh',
      tokenType: 'Bearer',
      expiresIn: 3600,
      refreshExpiresIn: 86400,
    ),
    email: 'dev@aiin.by',
  );
}

void main() {
  setUpAll(ensureGoldenFonts);

  setUp(() {
    HttpOverrides.global = _BlockingHttpOverrides();
  });

  tearDown(() {
    HttpOverrides.global = null;
  });

  testWidgets('AIIN connect flow renders the model picker page', (
    tester,
  ) async {
    // Reset inside the body: the binding verifies foundation debug vars
    // right after the test body, before package:test teardowns run.
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await pumpGolden(
        tester,
        const SizedBox.shrink(),
        size: goldenSizeTall,
        wrap: (child) => Scaffold(body: child),
      );
      // Start the flow AFTER the scaffold exists — it presents a snackbar
      // and then pushes the picker page over this shell.
      final context = tester.element(find.byType(Scaffold));
      final flow = runAiinConnectFlow(
        context: context,
        registry: ProviderRegistry.inMemory(),
        service: null,
        lastConnectionStore: LastConnectionStore.inMemory(),
        aiinConnectFn: _fakeConnect,
      );
      await tester.pumpAndSettle();

      // The manual-entry picker is the flow's rendered surface (the
      // blocked model fetch answers empty): app bar + autofocus field.
      expect(find.text('AIIN model'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      await expectGolden(tester, 'aiin_model_picker');

      // Cancel: the flow aborts cleanly without touching the registry.
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(await flow, isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

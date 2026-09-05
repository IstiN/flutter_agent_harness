// The AIIN connect flow's paste-key fallback: when the AIIN OAuth proxy
// rejects our redirect ("client_redirect_uri is not allowed"), the flow
// must still complete — cabinet key paste → model pick → provider saved.
import 'dart:convert';

import 'package:fa/services/aiin_connect_flow.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

MockClient _redirectBlockedClient() => MockClient((request) async {
      final url = request.url.toString();
      if (url.contains('/api/oauth-proxy/providers')) {
        return _json({'providers': ['google']});
      }
      if (url.contains('/api/oauth-proxy/initiate')) {
        return _json(
          const {
            'error': 'invalid_provider',
            'message': 'client_redirect_uri is not allowed',
          },
          400,
        );
      }
      return _json(const {'error': 'unexpected'}, 404);
    });

void main() {
  testWidgets('AIIN connect falls back to the paste-key dialog when the '
      'service blocks the redirect, and completes the connect', (tester) async {
    final registry = ProviderRegistry.inMemory();
    BuildContext? flowContext;
    Future<bool>? done;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Builder(
              builder: (context) {
                flowContext = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );

    done = runAiinConnectFlow(
      context: flowContext!,
      registry: registry,
      service: null,
      lastConnectionStore: LastConnectionStore.inMemory(),
      aiinHttpClient: _redirectBlockedClient(),
      // The test VM has no dart:html — simulate a real popup.
      aiinOpenPopupFn: () => true,
      aiinNavigatePopupFn: (_) {},
    );

    // The paste-key dialog appears (initiate was rejected).
    await tester.pumpAndSettle();
    expect(find.text('AIIN API key'), findsOneWidget);
    expect(find.text('Open the AIIN cabinet'), findsOneWidget);

    // An invalid key keeps Connect disabled.
    await tester.enterText(find.byType(TextField), 'not-a-key');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Connect'),
          )
          .onPressed,
      isNull,
    );

    // A valid key enables Connect.
    await tester.enterText(find.byType(TextField), 'sk-aiin-test-1234567890');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Connect'),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    // The model picker opens (no models fetched) — use the manual entry.
    expect(find.text('AIIN model'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'kimi-k2');
    await tester.tap(find.text('Use'));
    final completed = await done;
    expect(completed, isTrue);

    // The provider was saved under the AIIN endpoint with the pasted key.
    expect(registry.providers, hasLength(1));
    final provider = registry.providers.single;
    expect(provider.baseUrl, 'https://api.aiin.by/v1');
    expect(provider.modelId, 'kimi-k2');
    expect(provider.name, startsWith('AIIN'));
    expect(registry.keyFor(provider.id), 'sk-aiin-test-1234567890');
  });
}

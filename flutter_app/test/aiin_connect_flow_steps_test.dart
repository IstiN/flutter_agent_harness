// Direct step coverage for the AIIN connect flow's web and desktop
// branches (issue #486): `runAiinWebConnect` is the kIsWeb hop (unreachable
// from the VM without the public step seam), the desktop branch is driven
// end-to-end through `runAiinConnectFlow` with a linux platform override.
// No real network: the OAuth exchange rides a mock backend, the CLI flow
// is stubbed via `aiinConnectFn`.
import 'dart:async';
import 'dart:convert';

import 'package:fa/services/aiin_connect_flow.dart';
import 'package:fa/services/aiin_web_auth.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

/// Mock AIIN backend serving the OAuth exchange + key registration (same
/// contract the aiin_web_auth_test coordinator suite runs against).
MockClient _mockBackend() => MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/oauth-proxy/exchange') {
        return _json(const {
          'access_token': 'jwt-a.jwt-b.jwt-c',
          'refresh_token': 'refresh-1',
          'token_type': 'Bearer',
          'expires_in': 3600,
        });
      }
      if (path == '/v1/keys') {
        return _json({
          'id': 'key-1',
          'prefix': 'sk-aiin-abc12345',
          'key': 'sk-aiin-' + ('a' * 32),
        }, 201);
      }
      return http.Response('not found', 404);
    });

Future<BuildContext> _pumpHost(tester) async {
  BuildContext? flowContext;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            flowContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return flowContext!;
}

void main() {
  // No KeychainStore channel in the test VM (issue #329 gate hangs without
  // an answer): report "no secure store" so the flow falls back to the
  // session keys store.
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('fah/keychain'), (
      call,
    ) async => null);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('fah/keychain'), null);
    debugDefaultTargetPlatformOverride = null;
  });

  group('runAiinWebConnect (the kIsWeb hop)', () {
    testWidgets('a completed OAuth round-trip connects and saves the '
        'provider', (tester) async {
      final registry = ProviderRegistry.inMemory();
      final context = await _pumpHost(tester);
      final done = runAiinWebConnect(
        context: context,
        registry: registry,
        service: null,
        lastConnectionStore: LastConnectionStore.inMemory(),
        aiinHttpClient: _mockBackend(),
        aiinOpenPopupFn: () => true,
        aiinNavigatePopupFn: (url) {
          // The hosted page redirects back with OUR state.
          final state = Uri.parse(url).queryParameters['state']!;
          scheduleMicrotask(
            () => AiinWebAuthCoordinator.instance.complete(
              code: 'c-1',
              state: state,
            ),
          );
        },
        aiinModelsFetcher: (baseUrl, {required apiKey}) async =>
            ['moonshotai/kimi-k2', 'deepseek-ai/deepseek-v3'],
      );

      // The model picker opens with the fetched list; pick one.
      await tester.pumpAndSettle();
      expect(find.text('2 models'), findsOneWidget);
      await tester.tap(find.text('moonshotai/kimi-k2'));
      expect(await done, isTrue);
      await tester.pump(const Duration(seconds: 5)); // expire status snackbars

      final provider = registry.providers.single;
      expect(provider.baseUrl, aiinDefaultChatBaseUrl);
      expect(provider.modelId, 'moonshotai/kimi-k2');
      expect(registry.keyFor(provider.id), startsWith('sk-aiin-'));
    });
    testWidgets('a timeout falls back to the paste-key dialog and '
        'completes', (tester) async {
      final registry = ProviderRegistry.inMemory();
      final context = await _pumpHost(tester);
      final done = runAiinWebConnect(
        context: context,
        registry: registry,
        service: null,
        lastConnectionStore: LastConnectionStore.inMemory(),
        aiinHttpClient: _mockBackend(),
        aiinOpenPopupFn: () => true,
        aiinNavigatePopupFn: (_) {},
        aiinWebTimeout: const Duration(milliseconds: 200),
        aiinModelsFetcher: (baseUrl, {required apiKey}) async => [],
      );

      // No callback arrives — the timeout lands in the paste-key path.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(); // one frame for the fallback dialog
      expect(find.text('AIIN API key'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField),
        'sk-aiin-test-1234567890',
      );
      await tester.pump(); // rebuild: the Connect button enables
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();

      // No models fetched → the manual-entry picker; type the id.
      expect(find.text('AIIN model'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'kimi-k2');
      await tester.tap(find.text('Use'));
      expect(await done, isTrue);
      expect(registry.providers.single.modelId, 'kimi-k2');
      await tester.pump(const Duration(seconds: 5)); // expire status snackbars
    });
    testWidgets('a blocked popup reports false without any dialog',
        (tester) async {
      final registry = ProviderRegistry.inMemory();
      final context = await _pumpHost(tester);
      final done = runAiinWebConnect(
        context: context,
        registry: registry,
        service: null,
        lastConnectionStore: LastConnectionStore.inMemory(),
        aiinOpenPopupFn: () => false,
        aiinNavigatePopupFn: (_) {},
      );
      expect(await done, isFalse);
      expect(find.text('AIIN API key'), findsNothing);
      expect(registry.providers, isEmpty);
      expect(AiinWebAuthCoordinator.instance.lastFailure, 'popup_blocked');
      await tester.pump(const Duration(seconds: 5)); // expire status snackbars
    });
    testWidgets('a cancelled callback (empty code) falls back to paste and '
        'a dialog cancel aborts', (tester) async {
      final registry = ProviderRegistry.inMemory();
      final context = await _pumpHost(tester);
      final done = runAiinWebConnect(
        context: context,
        registry: registry,
        service: null,
        lastConnectionStore: LastConnectionStore.inMemory(),
        aiinHttpClient: _mockBackend(),
        aiinOpenPopupFn: () => true,
        aiinNavigatePopupFn: (url) {
          scheduleMicrotask(
            () => AiinWebAuthCoordinator.instance.complete(),
          );
        },
      );
      await tester.pumpAndSettle();
      expect(find.text('AIIN API key'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      expect(await done, isFalse);
      expect(registry.providers, isEmpty);
      await tester.pump(const Duration(seconds: 5)); // expire status snackbars
    });
  });

  group('desktop hop end-to-end (linux override)', () {
    testWidgets('a successful sign-in picks a model and saves the provider',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final registry = ProviderRegistry.inMemory();
      final context = await _pumpHost(tester);
      final done = runAiinConnectFlow(
        context: context,
        registry: registry,
        service: null,
        lastConnectionStore: LastConnectionStore.inMemory(),
        aiinConnectFn: () async => AiinConnectResult(
          apiKey: const AiinApiKey(
            raw: 'sk-aiin-desktop-000000000000',
            id: 'key-9',
            prefix: 'sk-aiin-desktop',
            createdAt: '2026-09-16T00:00:00Z',
          ),
          tokens: const AiinOAuthTokens(
            accessToken: 'jwt-a.jwt-b.jwt-c',
            refreshToken: 'refresh-1',
            tokenType: 'Bearer',
            expiresIn: 3600,
            refreshExpiresIn: 86400,
          ),
          email: 'user@aiin.by',
        ),
        aiinModelsFetcher: (baseUrl, {required apiKey}) async =>
            ['moonshotai/kimi-k2'],
      );

      // The opening snackbar names the browser hop; then the picker.
      await tester.pumpAndSettle();
      expect(find.text('AIIN model'), findsOneWidget);
      await tester.tap(find.text('moonshotai/kimi-k2'));
      expect(await done, isTrue);
      await tester.pump(const Duration(seconds: 4)); // expire the snackbar

      final provider = registry.providers.single;
      // The entry is named after the account email.
      expect(provider.name, 'user@aiin.by');
      expect(provider.modelId, 'moonshotai/kimi-k2');
      expect(registry.keyFor(provider.id), 'sk-aiin-desktop-000000000000');
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a null sign-in result falls back to the paste dialog and '
        'a cancel aborts', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final registry = ProviderRegistry.inMemory();
      final context = await _pumpHost(tester);
      final done = runAiinConnectFlow(
        context: context,
        registry: registry,
        service: null,
        lastConnectionStore: LastConnectionStore.inMemory(),
        aiinConnectFn: () async => null,
      );
      await tester.pumpAndSettle();
      expect(find.text('AIIN API key'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      expect(await done, isFalse);
      expect(registry.providers, isEmpty);
      await tester.pump(const Duration(seconds: 4)); // expire the snackbar
      debugDefaultTargetPlatformOverride = null;
    });
  });
}

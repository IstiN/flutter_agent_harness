// Direct step coverage for the AIIN connect flow's web and desktop
// branches (issue #486): `runAiinWebConnect` is the kIsWeb hop (unreachable
// from the VM without the public step seam), the desktop branch is driven
// end-to-end through `runAiinConnectFlow` with a linux platform override.
// No real network: the OAuth exchange rides a mock backend, the CLI flow
// is stubbed via `aiinConnectFn`.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Socket;

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
          'key': 'sk-aiin-${'a' * 32}',
        }, 201);
      }
      return http.Response('not found', 404);
    });

Future<BuildContext> _pumpHost(WidgetTester tester) async {
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

  /// Mocks the iOS `fah/web_auth_session` channel: [behavior] answers the
  /// `authenticate` call; `cancel` completes the pending session with null
  /// (the real sheet's canceledLogin path). Returns the mutable harness.
  ({
    String? Function() openedUrl,
    int Function() cancelCount,
  }) mockAuthSessionChannel(
    Object? Function(String url) behavior,
  ) {
    final opened = <String>[];
    Completer<Object?>? session;
    var cancels = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('fah/web_auth_session'), (
      call,
    ) async {
      if (call.method == 'authenticate') {
        final url = (call.arguments as Map)['url'] as String;
        opened.add(url);
        session = Completer<Object?>();
        // The sheet answers only when it CLOSES (cancel below).
        behavior(url);
        return session!.future;
      }
      if (call.method == 'cancel') {
        cancels++;
        session?.complete(null);
        return null;
      }
      return null;
    });
    return (openedUrl: () => opened.isEmpty ? null : opened.single,
        cancelCount: () => cancels);
  }

  group('mobile hop end-to-end (iOS auth-session override)', () {
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('fah/web_auth_session'),
              null);
    });

    testWidgets('the sheet opens the hosted page, the loopback callback '
        'lands and the sheet dismisses itself into the model picker',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final harness = mockAuthSessionChannel((url) => null);
      final registry = ProviderRegistry.inMemory();
      final context = await _pumpHost(tester);
      // The whole connect (loopback server + auth-session channel) runs
      // inside ONE runAsync scope — runAsync is not reentrant, and the
      // server's socket events only dispatch in the real-async zone.
      await tester.runAsync(() async {
        unawaited(
          runAiinConnectFlow(
            context: context,
            registry: registry,
            service: null,
            lastConnectionStore: LastConnectionStore.inMemory(),
            aiinHttpClient: _mockBackend(),
            aiinModelsFetcher: (baseUrl, {required apiKey}) async =>
                ['moonshotai/kimi-k2'],
          ).then(
            (_) {},
            onError: (Object _) {},
          ),
        );

        // The flow binds its loopback server and opens the auth session.
        for (var i = 0; i < 100 && harness.openedUrl() == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final login = Uri.parse(harness.openedUrl()!);
        expect(login.host, 'auth.aiin.by');
        expect(login.path, '/login');
        final redirect =
            Uri.parse(login.queryParameters['client_redirect_uri']!);
        expect(redirect.host, '127.0.0.1');

        // The AIIN proxy redirects the sheet to the loopback server with
        // the code + our state — a REAL round-trip against the flow's
        // server, over a raw socket (the binding mocks HttpClient with
        // 400s, but not raw sockets).
        final socket = await Socket.connect('127.0.0.1', redirect.port);
        socket.add(
          utf8.encode(
            'GET /callback?code=c-1&state=${login.queryParameters['state']} '
            'HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n',
          ),
        );
        await socket.flush();
        final reply = utf8.decode(
          await socket.first.timeout(const Duration(seconds: 10)),
        );
        expect(reply, contains('200'));
        socket.destroy();
        for (var i = 0; i < 100 && harness.cancelCount() == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      // The sheet was dismissed through the channel's cancel.
      expect(harness.cancelCount(), 1);

      // Exchange (mock backend) → the model picker opens. The pick-and-save
      // tail is platform-independent — covered by the desktop/android
      // widget tests; driving it here would await a real-zone future past
      // the test binding's teardown (it never completes the test cleanly).
      for (var i = 0; i < 40 && find.text('AIIN model').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('AIIN model'), findsOneWidget);
      expect(registry.providers, isEmpty);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('an auth session that cannot start falls back to the paste '
        'dialog and a cancel aborts', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      mockAuthSessionChannel(
        (url) => throw PlatformException(code: 'auth_session_unavailable'),
      );
      final registry = ProviderRegistry.inMemory();
      final context = await _pumpHost(tester);
      final done = runAiinConnectFlow(
        context: context,
        registry: registry,
        service: null,
        lastConnectionStore: LastConnectionStore.inMemory(),
      );
      // Let the loopback bind + the failing session start settle.
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.text('AIIN API key'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      expect(await done, isFalse);
      expect(registry.providers, isEmpty);
      await tester.pump(const Duration(seconds: 4)); // expire the snackbar
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('android runs the same loopback flow through the external '
        'browser and saves the provider', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final registry = ProviderRegistry.inMemory();
      final context = await _pumpHost(tester);
      final done = runAiinConnectFlow(
        context: context,
        registry: registry,
        service: null,
        lastConnectionStore: LastConnectionStore.inMemory(),
        aiinConnectFn: () async => AiinConnectResult(
          apiKey: const AiinApiKey(
            raw: 'sk-aiin-android-00000000000',
            id: 'key-9',
            prefix: 'sk-aiin-android',
            createdAt: '2026-09-26T00:00:00Z',
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
      await tester.pumpAndSettle();
      expect(find.text('AIIN model'), findsOneWidget);
      await tester.tap(find.text('moonshotai/kimi-k2'));
      expect(await done, isTrue);
      await tester.pump(const Duration(seconds: 4)); // expire the snackbar
      expect(registry.providers.single.name, 'user@aiin.by');
      expect(
        registry.keyFor(registry.providers.single.id),
        'sk-aiin-android-00000000000',
      );
      debugDefaultTargetPlatformOverride = null;
    });
  });
}

// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/aiin_connect_flow.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/ui/screens/settings_tiles.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fa_ui/fa_ui.dart';

/// A service recording [reconfigure] calls (nothing else is exercised) —
/// the same seam the chatgpt/copilot connect-flow tests use.
final class _RecordingService extends AgentService {
  _RecordingService()
    : super(
        agent: Agent(
          model: Model(
            id: 'test-model',
            api: 'test-api',
            provider: 'test',
            baseUrl: 'https://example.com',
            contextWindow: 100000,
            maxTokens: 4096,
          ),
          systemPrompt: 'You are Fa.',
          streamFunction: (model, context, {cancelToken}) =>
              AssistantMessageEventStream(),
          toolRegistry: ToolRegistry(const []),
        ),
        env: MemoryExecutionEnv(),
        sessionsRoot: '/sessions',
      );

  AgentConfig? reconfigured;

  @override
  Future<void> reconfigure(
    AgentConfig config, {
    bool fromProviderAddFlow = false,
  }) async {
    reconfigured = config;
  }
}

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

AiinConnectResult _signIn() => AiinConnectResult(
  apiKey: AiinApiKey(
    raw: 'sk-aiin-desktop-000000000000',
    id: 'key-9',
    prefix: 'sk-aiin-desktop',
    createdAt: '2026-09-16T00:00:00Z',
  ),
  tokens: const AiinOAuthTokens(
    accessToken: 'at',
    refreshToken: 'rt',
    tokenType: 'Bearer',
    expiresIn: 3600,
    refreshExpiresIn: 86400,
  ),
  email: 'user@aiin.by',
);

/// gh-2466: the settings form's vision switch derives from the ENDPOINT's
/// reported input modalities when the `/models` answer carries them — the
/// AIN gateway serves multimodal ids the id heuristic cannot see
/// (`mistralai/mistral-large-4-0` is text+image) and serves text-only ids
/// with image in the name. The heuristic keeps covering unreported ids.
void main() {
  // No KeychainStore channel in the test VM: report "no secure store" so
  // the flow falls back to the session keys store.
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('fah/keychain'),
          (call) async => null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('fah/keychain'), null);
    debugDefaultTargetPlatformOverride = null;
    // An abandoned flow (a pending model picker) must not poison the next
    // test's single-flight guard.
    resetAiinConnectFlightForTests();
  });

  testWidgets('endpoint-reported image modalities check the vision switch '
      '(heuristic-missed id)', (tester) async {
    Future<ModelsEndpointInfo> modelsWithModalities(
      String baseUrl, {
      required String apiKey,
    }) async => (
      const ['mistralai/mistral-large-4-0', 'sao10k/l3-lunaris-8b'],
      const <String, int>{},
      const <String, int>{},
      const {
        'mistralai/mistral-large-4-0': ['text', 'image'],
        'sao10k/l3-lunaris-8b': ['text'],
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AgentSettingsForm(
              registry: ProviderRegistry.inMemory(),
              modelsFetcher: modelsWithModalities,
              onConnect: (_) async {},
            ),
          ),
        ),
      ),
    );
    // Provider-first form: pick a provider (OpenRouter) to reveal the
    // config fields.
    await tester.ensureVisible(find.text('OpenRouter'));
    await tester.tap(find.text('OpenRouter'));
    await tester.pumpAndSettle();
    // The debounced endpoint fetch lands.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    bool visionValue() {
      final rowFinder = find.widgetWithText(
        SettingsSwitchRow,
        'Supports images (vision)',
      );
      expect(rowFinder, findsOneWidget);
      return tester.widget<SettingsSwitchRow>(rowFinder).value;
    }

    // A heuristic-missed id with a reported image modality → checked.
    await tester.enterText(
      find.widgetWithText(TextField, 'Model id'),
      'mistralai/mistral-large-4-0',
    );
    await tester.pump();
    expect(visionValue(), isTrue, reason: 'the endpoint reported image');

    // A reported text-only id → unchecked (the heuristic would keep the
    // previous value; the endpoint's word wins).
    await tester.enterText(
      find.widgetWithText(TextField, 'Model id'),
      'sao10k/l3-lunaris-8b',
    );
    await tester.pump();
    expect(visionValue(), isFalse, reason: 'the endpoint reported text-only');
  });

  testWidgets(
    'the connect config carries the endpoint-derived vision verdict',
    (tester) async {
      AgentConfig? connected;
      Future<ModelsEndpointInfo> modelsWithModalities(
        String baseUrl, {
        required String apiKey,
      }) async => (
        const ['mistralai/mistral-large-4-0'],
        const <String, int>{'mistralai/mistral-large-4-0': 1048576},
        const <String, int>{},
        const {
          'mistralai/mistral-large-4-0': ['text', 'image'],
        },
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AgentSettingsForm(
                registry: ProviderRegistry.inMemory(),
                modelsFetcher: modelsWithModalities,
                onConnect: (config) async => connected = config,
              ),
            ),
          ),
        ),
      );
      // Provider-first form: pick a provider (OpenRouter) to reveal the
      // config fields.
      await tester.ensureVisible(find.text('OpenRouter'));
      await tester.tap(find.text('OpenRouter'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'API key'),
        'sk-test',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Model id'),
        'mistralai/mistral-large-4-0',
      );
      await tester.pump();
      await tester.ensureVisible(find.text('Start chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start chat'));
      await tester.pumpAndSettle();

      expect(connected, isNotNull);
      expect(connected!.supportsImages, isTrue);
      expect(connected!.contextWindow, 1048576);
    },
  );

  testWidgets('the AIN connect flow derives the vision verdict from the '
      'endpoint modalities (gh-2466 review)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final registry = ProviderRegistry.inMemory();
    final service = _RecordingService();
    final context = await _pumpHost(tester);
    final done = runAiinConnectFlow(
      context: context,
      registry: registry,
      service: service,
      lastConnectionStore: LastConnectionStore.inMemory(),
      aiinConnectFn: () async => _signIn(),
      // The heuristic-missed multimodal id (gh-2466(2)): the endpoint
      // reports image input the name matcher cannot see.
      aiinModelsFetcher: (baseUrl, {required apiKey}) async => (
        const ['mistralai/mistral-large-4-0'],
        const <String, int>{},
        const <String, int>{},
        const {
          'mistralai/mistral-large-4-0': ['text', 'image'],
        },
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('AIIN model'), findsOneWidget);
    await tester.tap(find.text('mistralai/mistral-large-4-0'));
    expect(await done, isTrue);
    debugDefaultTargetPlatformOverride = null;
    await tester.pump(const Duration(seconds: 4)); // expire the snackbar

    expect(service.reconfigured, isNotNull);
    expect(
      service.reconfigured!.supportsImages,
      isTrue,
      reason:
          'the endpoint reported image input — the connect config must '
          'carry it, not the (text-only) name heuristic',
    );
  });

  testWidgets('a reported text-only id keeps the AIN connect config '
      'non-vision (gh-2466 review)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final registry = ProviderRegistry.inMemory();
    final service = _RecordingService();
    final context = await _pumpHost(tester);
    final done = runAiinConnectFlow(
      context: context,
      registry: registry,
      service: service,
      lastConnectionStore: LastConnectionStore.inMemory(),
      aiinConnectFn: () async => _signIn(),
      // A heuristic-MATCHING id reported text-only: the endpoint's word
      // wins over the name matcher, including false.
      aiinModelsFetcher: (baseUrl, {required apiKey}) async => (
        const ['gpt-4o-2024-11-20'],
        const <String, int>{},
        const <String, int>{},
        const {
          'gpt-4o-2024-11-20': ['text'],
        },
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('AIIN model'), findsOneWidget);
    await tester.tap(find.text('gpt-4o-2024-11-20'));
    expect(await done, isTrue);
    debugDefaultTargetPlatformOverride = null;
    await tester.pump(const Duration(seconds: 4)); // expire the snackbar

    expect(service.reconfigured, isNotNull);
    expect(
      service.reconfigured!.supportsImages,
      isFalse,
      reason:
          'the endpoint reported text-only — a heuristic true must not '
          'override it',
    );
  });
}

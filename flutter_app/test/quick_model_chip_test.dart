// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// Issue #167 — the mobile (narrow) header's quick model switch, in parity
/// with the wide shell's chip:
///
/// - the SAME unified picker page/config backs both headers (no forked
///   picker logic),
/// - the mobile chip opens it as a bottom sheet, picks a provider → model,
///   and reconfigures the active session through the shared apply path,
/// - the chip label follows model changes live (reconfigure, session
///   switch),
/// - long-press jumps to the Models settings page,
/// - very long model ids ellipsis-clamp on a 320pt-wide canvas.

import 'package:fa/apps/apps_store.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/app_launcher_screen.dart';
import 'package:fa/ui/screens/models_settings_page.dart';
import 'package:fa/ui/widgets/quick_model_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fa_ui/fa_ui.dart' show MediaSlotProviderPickerPage;

StreamFunction _singleTextResponse(String text) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final message = AssistantMessage(
      content: [TextContent(text: text)],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.now(),
    );
    stream.push(DoneEvent(reason: StopReason.stop, message: message));
    stream.end();
    return stream;
  };
}

AgentService _fakeService(ExecutionEnv env, {String modelId = 'test-model'}) {
  return AgentService(
    agent: Agent(
      model: Model(
        id: modelId,
        api: 'test-api',
        provider: 'test',
        baseUrl: 'https://example.com',
        contextWindow: 100000,
        maxTokens: 4096,
      ),
      systemPrompt: 'You are Fa.',
      streamFunction: _singleTextResponse('ok'),
      toolRegistry: ToolRegistry(const []),
    ),
    env: env,
    sessionsRoot: '/sessions',
    config: AgentConfig(
      providerKind: 'test',
      modelId: modelId,
      baseUrl: 'https://example.com',
      apiKey: '',
    ),
  );
}

class _Harness {
  _Harness(this.manager, this.registry, this.service);

  final FlutterSessionManager manager;
  final ProviderRegistry registry;
  final AgentService service;
}

/// Pumps the apps launcher home (the narrow layout) at [size] with one
/// live session and a registry carrying a saved custom provider.
Future<_Harness> _pumpSheet(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  String modelId = 'test-model',
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final env = MemoryExecutionEnv();
  final registry = ProviderRegistry.inMemory();
  await registry.add(
    name: 'Acme',
    baseUrl: 'https://acme.example/v1',
    modelId: 'acme-1',
  );
  final service = _fakeService(env, modelId: modelId);
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
    ..addSession('fake-session', service);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFahTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AppLauncherScreen(
        manager: manager,
        registry: registry,
        appsStore: AppsStore(
          env,
          readAsset: (path) async => throw StateError('no assets in test'),
          seedDemoIds: const [],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(manager, registry, service);
}

/// The real user flow into the session panel: drawer → row tap.
Future<void> _openSessionPanel(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('sessionChatDrawerButton')));
  await tester.pumpAndSettle();
  await tester.tap(
    find.byKey(const ValueKey('sessionChatDrawerEntry:fake-session')),
  );
  await tester.pumpAndSettle();
}

Finder _chip() => find.byKey(const ValueKey('sessionChatModelChip'));

void main() {
  testWidgets('parity: both headers open the SAME unified picker config '
      '(issue #167 AC2)', (tester) async {
    final env = MemoryExecutionEnv();
    final registry = ProviderRegistry.inMemory();
    final service = _fakeService(env);
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            captured = context;
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    );
    // The factory both the wide shell's `_openModelPicker` and the mobile
    // sheet's chip route through — the settings "Default chat model" flow
    // config, verbatim.
    final page = quickModelPickerPage(
      captured,
      service: service,
      registry: registry,
    );
    expect(page, isA<MediaSlotProviderPickerPage>());
    expect(page.slot, isNull); // the generic provider→model flow
    expect(page.connectedOnly, isTrue); // connected providers only
    expect(page.allowMainConnection, isFalse); // editing the main connection
    expect(
      page.title,
      AppLocalizations.of(captured).settingsDefaultChatModelTitle,
    );
    expect(page.mainBaseUrl, service.activeBaseUrl);
    expect(page.registry, same(registry));
  });

  testWidgets('chip tap opens the unified picker as a bottom sheet; picking '
      'switches the active session and updates the chip (AC1)', (tester) async {
    final harness = await _pumpSheet(tester);
    await _openSessionPanel(tester);

    // The chip renders the active model name.
    expect(
      find.descendant(of: _chip(), matching: find.text('test-model')),
      findsOneWidget,
    );

    await tester.tap(_chip());
    await tester.pumpAndSettle();

    // Bottom-sheet presentation with the SAME unified picker page.
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(MediaSlotProviderPickerPage), findsOneWidget);
    // No "Same as main" row (main-connection edit config).
    expect(find.text('Main connection'), findsNothing);

    // The saved custom provider is offered; picking it opens the model step.
    await tester.tap(find.text('Acme'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Model id'),
      'acme-1',
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // The sheet closed and the switch applied through the shared path —
    // mid-run semantics identical to desktop (same reconfigure call).
    expect(find.byType(MediaSlotProviderPickerPage), findsNothing);
    expect(harness.service.modelId, 'acme-1');
    expect(
      find.descendant(of: _chip(), matching: find.text('acme-1')),
      findsOneWidget,
    );
  });

  testWidgets('the chip label follows model changes and session switches '
      'live (AC1/E2)', (tester) async {
    final harness = await _pumpSheet(tester);
    final second = _fakeService(MemoryExecutionEnv(), modelId: 'other-model');
    harness.manager.addSession('second-session', second);
    await _openSessionPanel(tester);

    // A reconfigure (the picker's apply path, or a session restore) is
    // reflected without reopening anything.
    await harness.service.reconfigure(
      AgentConfig(
        providerKind: 'openai-completions',
        modelId: 'switched-model',
        baseUrl: 'https://example.com',
        apiKey: '',
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: _chip(), matching: find.text('switched-model')),
      findsOneWidget,
    );

    // Switching sessions swaps the chip to that session's model.
    await tester.tap(find.byKey(const ValueKey('sessionChatPanelSessions')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('sessionChatDrawerEntry:second-session')),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: _chip(), matching: find.text('other-model')),
      findsOneWidget,
    );
  });

  testWidgets('long-press jumps to the Models settings page', (tester) async {
    await _pumpSheet(tester);
    await _openSessionPanel(tester);
    await tester.longPress(_chip());
    await tester.pumpAndSettle();
    expect(find.byType(ModelsSettingsPage), findsOneWidget);
  });

  testWidgets('a very long model name ellipsis-clamps at 320pt width '
      '(AC3)', (tester) async {
    await _pumpSheet(
      tester,
      size: const Size(320, 568),
      modelId:
          'an-extremely-long-model-identifier-that-must-ellipsis-clamp-in-the-header',
    );
    await _openSessionPanel(tester);
    // No RenderFlex overflow, and the label clamps instead of pushing the
    // menu off the bar.
    expect(tester.takeException(), isNull);
    final label = tester.widget<Text>(
      find.descendant(of: _chip(), matching: find.byType(Text)),
    );
    expect(label.overflow, TextOverflow.ellipsis);
    expect(label.maxLines, 1);
  });
}

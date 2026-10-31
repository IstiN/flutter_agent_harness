// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// Issue #167 — the current shell's quick model switch:
///
/// - the SAME unified picker page/config backs the factory and call site,
/// - the chip picks a provider → model and reconfigures the active session,
/// - the chip label follows model changes live (reconfigure, session switch),
/// - very long model ids ellipsis-clamp in the shared chip.
library;

import 'package:fa/main.dart' show faHomeScreen;
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/widgets/quick_model_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fa_ui/fa_ui.dart' show MediaSlotProviderPickerPage;

void _noop() {}

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

/// Pumps the current shell's inline ChatScreen with one live session and a
/// registry carrying a saved custom provider.
Future<_Harness> _pumpChat(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final env = MemoryExecutionEnv();
  final registry = ProviderRegistry.inMemory();
  await registry.add(
    name: 'Acme',
    baseUrl: 'https://acme.example/v1',
    modelId: 'acme-1',
  );
  final service = _fakeService(env);
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
    ..addSession('fake-session', service);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFahTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => faHomeScreen(
          context: context,
          manager: manager,
          registry: registry,
          sessionNamesStore: SessionNamesStore.inMemory({
            'fake-session': 'First chat',
            'second-session': 'Second chat',
          }),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(manager, registry, service);
}

Finder _chip() => find.byKey(const ValueKey('wideModelChip'));

void main() {
  testWidgets('the factory opens the unified picker config (issue #167 AC2)', (
    tester,
  ) async {
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
    // The current shell's `_openModelPicker` uses the settings "Default chat
    // model" flow config, verbatim.
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

  testWidgets('chip tap opens the unified picker; picking switches the '
      'active session and updates the chip (AC1)', (tester) async {
    final harness = await _pumpChat(tester);

    // The chip renders the active model name.
    expect(
      find.descendant(of: _chip(), matching: find.text('test-model')),
      findsOneWidget,
    );

    await tester.tap(_chip());
    await tester.pumpAndSettle();

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

    // The picker closed and the switch applied through the shared path.
    expect(find.byType(MediaSlotProviderPickerPage), findsNothing);
    expect(harness.service.modelId, 'acme-1');
    expect(
      find.descendant(of: _chip(), matching: find.text('acme-1')),
      findsOneWidget,
    );
  });

  testWidgets('the chip label follows session switches live (E2)', (
    tester,
  ) async {
    final harness = await _pumpChat(tester);
    final second = _fakeService(MemoryExecutionEnv(), modelId: 'other-model');
    harness.manager.addSession('second-session', second);
    await tester.pumpAndSettle();

    // Switching sessions swaps the chip to that session's model.
    await tester.tap(find.text('Second chat'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: _chip(), matching: find.text('other-model')),
      findsOneWidget,
    );
  });

  testWidgets('a very long model name ellipsis-clamps in the shared chip '
      '(AC3)', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        home: const Scaffold(
          body: Center(
            child: QuickModelChip(
              modelId:
                  'an-extremely-long-model-identifier-that-must-ellipsis-clamp-in-the-header',
              maxWidth: 132,
              onTap: _noop,
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final label = tester.widget<Text>(
      find.descendant(
        of: find.byType(QuickModelChip),
        matching: find.byType(Text),
      ),
    );
    expect(label.overflow, TextOverflow.ellipsis);
    expect(label.maxLines, 1);
  });

  testWidgets('wiring parity: the current header chip opens the factory '
      'config (issue #167 AC2)', (tester) async {
    // The real call site, not just the factory: pump the actual shell and
    // tap its chip — the page must carry the quickModelPickerPage config.
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final env = MemoryExecutionEnv();
    final registry = ProviderRegistry.inMemory();
    final service = _fakeService(env);
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('fake-session', service);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => faHomeScreen(
            context: context,
            manager: manager,
            registry: registry,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final wideChip = find.byKey(const ValueKey('wideModelChip'));
    expect(wideChip, findsOneWidget);
    await tester.tap(wideChip);
    await tester.pumpAndSettle();

    final page = tester.widget<MediaSlotProviderPickerPage>(
      find.byType(MediaSlotProviderPickerPage),
    );
    expect(page.slot, isNull);
    expect(page.connectedOnly, isTrue);
    expect(page.allowMainConnection, isFalse);
    expect(page.mainBaseUrl, service.activeBaseUrl);
    expect(page.registry, same(registry));
  });
}

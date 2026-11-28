// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-2391 addendum 9 item 4: the wide shell's rail drops the Channels
/// destination in a host-only/relay-less product profile (the AIN profile
/// carries `channels: "host-only"`); Local/Activity/Apps stay. Stock keeps
/// the row (REG).
library;

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/main.dart' show faHomeScreen;
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/widgets/product_brand.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

AgentService _fakeService(ExecutionEnv env) {
  return AgentService(
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
          AssistantMessageEventStream()..end(),
      toolRegistry: ToolRegistry(const []),
    ),
    env: env,
    sessionsRoot: '/sessions',
    config: AgentConfig(
      providerKind: 'test',
      modelId: 'test-model',
      baseUrl: 'https://example.com',
      apiKey: '',
    ),
  );
}

Future<void> _pumpShell(
  WidgetTester tester, {
  required FaProductConfig productConfig,
}) async {
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
      home: ProductConfigScope(
        productConfig: productConfig,
        child: Builder(
          builder: (context) => faHomeScreen(
            context: context,
            manager: manager,
            registry: registry,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('host-only rail: no Channels row, Local/Activity/Apps stay', (
    tester,
  ) async {
    await _pumpShell(
      tester,
      productConfig: const FaProductConfig(
        productId: 'ain',
        displayName: 'AIN',
        channels: 'host-only',
        featureFlags: <String>{},
      ),
    );
    expect(find.byKey(const ValueKey('chatFilter-channels')), findsNothing);
    expect(find.byKey(const ValueKey('messengerPrimaryNav-activity')),
        findsWidgets);
    expect(find.byKey(const ValueKey('messengerPrimaryNav-apps')),
        findsWidgets);
  });

  testWidgets('stock rail keeps the Channels row (REG)', (tester) async {
    await _pumpShell(tester, productConfig: FaProductConfig.stock);
    expect(find.byKey(const ValueKey('chatFilter-channels')), findsWidgets);
  });
}

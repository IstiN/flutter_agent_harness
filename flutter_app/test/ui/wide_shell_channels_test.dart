// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The wide shell's Networks surface under the host-only channels policy
/// (gh-2391 addendum 5): a branded build with `channels: "host-only"` has
/// NO Networks entry anywhere — not on the rail, not in the narrow
/// profile sheet, and the chats sidebar never swaps to the networks
/// panel. Stock (no `channels` field) renders byte-identically (REG).
library;

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/widgets/product_brand.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:fa_ui/fa_ui.dart' show FaVisualDirection, buildFaTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

AgentService _service(ExecutionEnv env) {
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
      streamFunction: _singleTextResponse('ok'),
      toolRegistry: ToolRegistry(const []),
    ),
    env: env,
    sessionsRoot: '/sessions',
  );
}

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

Future<void> _pump(
  WidgetTester tester, {
  FaProductConfig? config,
  Size size = const Size(1280, 800),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final env = MemoryExecutionEnv();
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
    ..addSession('fake-session', _service(env));
  Widget home = WideLayoutShell(manager: manager);
  if (config != null) {
    home = ProductConfigScope(productConfig: config, child: home);
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFaTheme(
        direction: FaVisualDirection.glass,
        brightness: Brightness.dark,
      ),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
}

FaProductConfig _hostOnlyChannels() => FaProductConfig.fromJson({
  'productId': 'ain',
  'displayName': 'AIIN Agent',
  'apiEndpoint': 'https://api.aiin.example/v1',
  'featureFlags': <String>[],
  'channels': 'host-only',
  'hostConnection': {
    'baseUrl': 'https://api.aiin.example/v1',
    'sessionBridge': {'storage': 'localStorage', 'key': 'aiin_agent_session'},
    'defaultModel': 'aiin/aiin_flash',
  },
});

void main() {
  testWidgets('host-only channels: the Networks rail row is gone', (
    tester,
  ) async {
    await _pump(tester, config: _hostOnlyChannels());
    expect(
      find.byKey(const ValueKey('messengerPrimaryNav-network')),
      findsNothing,
      reason: 'a branded host-only build never shows Networks',
    );
    // The other sections stay.
    expect(
      find.byKey(const ValueKey('messengerPrimaryNav-local')),
      findsOneWidget,
    );
  });

  testWidgets('stock: the Networks rail row stays (REG)', (tester) async {
    await _pump(tester);
    expect(
      find.byKey(const ValueKey('messengerPrimaryNav-network')),
      findsOneWidget,
    );
  });
}

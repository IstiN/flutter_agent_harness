// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Golden coverage for the interactive dynamic-message surfaces (issue
/// #102): the inline transcript tile (booting + AC9 error states) and the
/// ✦ list sheet. States are driven through the service's `debugAdd` seam
/// (no JS runtime), so the snapshots are deterministic.
library;

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/dynamic_messages.dart';
import 'package:fa/apps/dynamic_messages_sheet.dart';
import 'package:fa/apps/dynamic_widget_tile.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa_ui/fa_ui.dart' show FaChatMessage;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

void main() {
  setUpAll(ensureGoldenFonts);

  final def = DynamicMessageDefinition(
    id: 'dm-1',
    title: 'Shopping checklist',
    jsSource: '// snapshot only',
    initialState: {'items': 3},
    heightHint: 320,
    createdAt: DateTime(2026, 9, 10, 12, 30),
  );

  /// An un-started engine shell: live badge shows, tree stays null so the
  /// body renders the boot spinner — no JS runtime needed.
  JsAppEngine engine() => JsAppEngine(
    app: JsAppInfo.fromManifest(
      {'id': def.id, 'name': def.title, 'version': '1.0.0'},
      bundled: false,
      fallbackId: def.id,
    ),
    env: MemoryExecutionEnv(),
    permissions: const AppPermissions(),
  );

  DynamicMessagesService service() => DynamicMessagesService(
    env: MemoryExecutionEnv(),
    sendText: (_) async {},
    sessionIdOf: () => 's1',
    sessionFileOf: () => 'sessions/s1.json',
    mediaGatewayOf: () => null,
    videoReaderOf: () => null,
    hostSecretsOf: () => const {},
    llmHandlerOf: () => null,
    asrTranscriberOf: () async => null,
  );

  testWidgets('dynamic message tile, live booting state', (tester) async {
    final dm = service()..debugAdd(def, engine: engine());
    await pumpGolden(
      tester,
      DynamicWidgetTile(
        service: dm,
        message: FaChatMessage(role: 'widget', content: '', data: def.id),
        onSaveAsApp: (_) async {},
      ),
      size: goldenSizeWide,
      settle: false,
    );
    await expectGolden(tester, 'dynamic_message_tile');
  });

  testWidgets('dynamic message tile, error state', (tester) async {
    final dm = service()
      ..debugAdd(
        def,
        engine: engine(),
        bootError: "SyntaxError: unexpected token '{' in expression",
      );
    await pumpGolden(
      tester,
      DynamicWidgetTile(
        service: dm,
        message: FaChatMessage(role: 'widget', content: '', data: def.id),
        onSaveAsApp: (_) async {},
      ),
      size: goldenSizeWide,
    );
    await expectGolden(tester, 'dynamic_message_tile_error');
  });

  testWidgets('dynamic messages list sheet', (tester) async {
    final agent = Agent(
      model: Model(
        id: 'test-model',
        api: 'test-api',
        provider: 'test',
        baseUrl: 'https://example.com',
        contextWindow: 100000,
        maxTokens: 4096,
      ),
      systemPrompt: 'Fa.',
      streamFunction: (model, context, {cancelToken}) {
        final stream = AssistantMessageEventStream();
        stream.push(
          DoneEvent(
            reason: StopReason.stop,
            message: AssistantMessage(
              content: [TextContent(text: 'ok')],
              api: model.api,
              provider: model.provider,
              model: model.id,
              usage: Usage.zero,
              stopReason: StopReason.stop,
              timestamp: DateTime.now(),
            ),
          ),
        );
        stream.end();
        return stream;
      },
      toolRegistry: ToolRegistry(const []),
    );
    final agentService = AgentService(
      agent: agent,
      env: MemoryExecutionEnv(),
      sessionsRoot: '/sessions',
    );
    agentService.dynamicMessages
      ..debugAdd(def, engine: engine())
      ..debugAdd(
        DynamicMessageDefinition(
          id: 'dm-2',
          title: 'BTC price',
          jsSource: '// snapshot only',
          createdAt: DateTime(2026, 9, 10, 9, 5),
          eventCount: 12,
        ),
      );
    await pumpGolden(
      tester,
      DynamicMessagesSheet(service: agentService, onSaveAsApp: (_) async {}),
      size: goldenSizeTall,
      wrap: (child) => Scaffold(
        appBar: AppBar(title: const Text('Fa')),
        body: const SizedBox.shrink(),
        bottomSheet: child,
      ),
    );
    await expectGolden(tester, 'dynamic_messages_sheet');
  });
}

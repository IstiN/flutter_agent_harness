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
import 'package:fa/apps/session_chat_sheet.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa_ui/fa_ui.dart' show FaChatMessage;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets('dynamic message mounted in the launcher chat transcript', (
    tester,
  ) async {
    // Issue #336: the launcher sheet is the iOS home chat surface; the
    // interactive tile renders INLINE in the transcript (not the plain
    // tool card). Deterministic booting state via the debugAdd engine
    // shell — no JS runtime.
    final env = MemoryExecutionEnv();
    final service = AgentService(
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
        streamFunction: (model, context, {cancelToken}) {
          final stream = AssistantMessageEventStream()..end();
          return stream;
        },
        toolRegistry: ToolRegistry(const []),
      ),
      watchExternalSessions: false,
      env: env,
      sessionsRoot: '/sessions',
      config: AgentConfig(
        providerKind: 'test',
        modelId: 'test-model',
        baseUrl: 'https://example.com',
        apiKey: '',
      ),
    );
    addTearDown(service.dispose);
    service.dynamicMessages.debugAdd(def, engine: engine());
    service.messages.addAll([
      FahChatMessage(
        role: 'user',
        content: 'а ты умеешь динамические сообщения делать?',
      ),
      FahChatMessage(
        role: 'tool',
        content:
            "Dynamic message 'Shopping checklist' presented to the user "
            '(widget dm-1)',
      ),
      FahChatMessage(role: 'widget', content: '', data: def.id),
      FahChatMessage(role: 'assistant', content: 'Готово!'),
    ]);
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('sess-a', service);
    final sheetKey = GlobalKey<SessionChatSheetState>();
    await pumpGolden(
      tester,
      SessionChatSheet(key: sheetKey, manager: manager, asr: _GoldenAsr()),
      size: goldenSizePhone,
      settle: false,
      wrap: (child) => Scaffold(body: child),
    );
    // The launcher panel starts collapsed: slide it open, past the panel
    // animation, without pumpAndSettle (the tile's boot spinner never
    // settles).
    sheetKey.currentState!.expand();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));
    await expectGolden(tester, 'dynamic_message_in_transcript');
  });

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

  testWidgets('dynamic message tile with the overflow menu open', (
    tester,
  ) async {
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
    // Issue #378 AC1: the ⋮ overflow carries the secondary actions.
    await tester.tap(find.byTooltip('More actions'));
    await tester.pump(const Duration(milliseconds: 400));
    await expectGolden(tester, 'dynamic_message_tile_menu');
  });

  testWidgets('ephemeral full-screen open (no graduation)', (tester) async {
    final dm = service()..debugAdd(def, engine: engine());
    await pumpGolden(
      tester,
      EphemeralDynamicAppView(service: dm, definition: def),
      size: goldenSizePhone,
      settle: false,
      wrap: (child) => child,
    );
    // Issue #378 AC2: the full-screen ephemeral view over the shared
    // canvas (boot spinner — deterministic, no JS runtime).
    await expectGolden(tester, 'dynamic_message_ephemeral_view');
  });

  // ── Issue #457 AC5: width breakpoints (360dp full-width vs 768dp
  // padded) in both themes, and the tall-clip fixture before/after
  // scrolling. ──

  /// A widget tree taller than any canvas: 900px-declared box (E1) of
  /// rows ending in one button control.
  final tallTree = {
    'type': 'sizedBox',
    'height': 900,
    'child': {
      'type': 'column',
      'mainAxisSize': 'min',
      'children': [
        {'type': 'text', 'data': 'top-row'},
        for (var i = 0; i < 20; i++) {'type': 'text', 'data': 'row-$i'},
        {'type': 'button', 'text': 'bottom-control'},
      ],
    },
  };

  testWidgets('tile at 360dp, light — full-width (AC5)', (tester) async {
    final dm = service()..debugAdd(def, engine: engine());
    await pumpGolden(
      tester,
      DynamicWidgetTile(
        service: dm,
        message: FaChatMessage(role: 'widget', content: '', data: def.id),
        onSaveAsApp: (_) async {},
      ),
      size: const Size(360, 800),
      theme: buildFahThemeLight(),
      settle: false,
    );
    await expectGolden(tester, 'dynamic_message_tile_mobile_360_light');
  });

  testWidgets('tile at 360dp, dark — full-width (AC5)', (tester) async {
    final dm = service()..debugAdd(def, engine: engine());
    await pumpGolden(
      tester,
      DynamicWidgetTile(
        service: dm,
        message: FaChatMessage(role: 'widget', content: '', data: def.id),
        onSaveAsApp: (_) async {},
      ),
      size: const Size(360, 800),
      settle: false,
    );
    await expectGolden(tester, 'dynamic_message_tile_mobile_360_dark');
  });

  testWidgets('tile at 768dp, light — padded (AC5)', (tester) async {
    final dm = service()..debugAdd(def, engine: engine());
    await pumpGolden(
      tester,
      DynamicWidgetTile(
        service: dm,
        message: FaChatMessage(role: 'widget', content: '', data: def.id),
        onSaveAsApp: (_) async {},
      ),
      size: const Size(768, 1024),
      theme: buildFahThemeLight(),
      settle: false,
    );
    await expectGolden(tester, 'dynamic_message_tile_tablet_768_light');
  });

  testWidgets('tile at 768dp, dark — padded (AC5)', (tester) async {
    final dm = service()..debugAdd(def, engine: engine());
    await pumpGolden(
      tester,
      DynamicWidgetTile(
        service: dm,
        message: FaChatMessage(role: 'widget', content: '', data: def.id),
        onSaveAsApp: (_) async {},
      ),
      size: const Size(768, 1024),
      settle: false,
    );
    await expectGolden(tester, 'dynamic_message_tile_tablet_768_dark');
  });

  testWidgets('tall clip fixture: viewport at the top (AC4 before)', (
    tester,
  ) async {
    final eng = engine();
    final dm = service()..debugAdd(def, engine: eng);
    await pumpGolden(
      tester,
      DynamicWidgetTile(
        service: dm,
        message: FaChatMessage(role: 'widget', content: '', data: def.id),
        onSaveAsApp: (_) async {},
      ),
      size: const Size(360, 800),
      settle: false,
    );
    eng.tree.value = tallTree;
    await tester.pump();
    await expectGolden(tester, 'dynamic_message_tall_fixture_top');
  });

  testWidgets('tall clip fixture: scrolled to the last control '
      '(AC4 after)', (tester) async {
    final eng = engine();
    final dm = service()..debugAdd(def, engine: eng);
    await pumpGolden(
      tester,
      DynamicWidgetTile(
        service: dm,
        message: FaChatMessage(role: 'widget', content: '', data: def.id),
        onSaveAsApp: (_) async {},
      ),
      size: const Size(360, 800),
      settle: false,
    );
    eng.tree.value = tallTree;
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('bottom-control'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    await expectGolden(tester, 'dynamic_message_tall_fixture_scrolled');
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

/// Fake [AsrApi] — goldens never touch the real method channel.
final class _GoldenAsr implements AsrApi {
  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> requestAccess() async => true;

  @override
  Future<void> startRecording() async {}

  @override
  Future<AsrRecording> stopRecording() async =>
      (path: '/tmp/golden.m4a', durationMs: 1000, sampleRate: 44100);

  @override
  Future<Uint8List> readRecording(String path) async =>
      Uint8List.fromList(const [1]);
}

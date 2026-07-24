// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fa/agent_service.dart';
import 'package:fa/flutter_session_manager.dart';
import 'package:fa/session_sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

// Fakes copied verbatim from test/session_sidebar_restore_test.dart.

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
      systemPrompt: 'You are fah.',
      streamFunction: _singleTextResponse('ok'),
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

/// Serves `rootBundle` from the asset tree `flutter test` builds into
/// `build/unit_test_assets/`.
///
/// The sidebar's `_loadApps` seeds the bundled demo apps through
/// `AppsStore` → `rootBundle.loadString` (not injectable — see
/// `SessionSidebar._loadApps`). Two framework quirks make this unreliable
/// without help:
///  1. the real `flutter/assets` channel answers only in the FIRST test of
///     a process (later sends hang forever), so every test registers this
///     mock handler — the framework resets handlers per test;
///  2. `rootBundle` is a process-global `CachingAssetBundle`: a test that
///     ends with asset loads in flight leaves PENDING cached futures whose
///     continuations belonged to the dead test zone — every later
///     `loadString` of those keys hangs on the poisoned cache entry.
///     `rootBundle.clear()` drops them so each test re-reads via the mock.
void _mockBundledAppAssets() {
  rootBundle.clear();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler('flutter/assets', (message) async {
        if (message == null) return null;
        final key = utf8.decode(message.buffer.asUint8List());
        final file = File('build/unit_test_assets/$key');
        if (!file.existsSync()) return null;
        return ByteData.sublistView(await file.readAsBytes());
      });
}

/// A manager with two live sessions (fixed ids — the tiles render the first
/// 8 chars) and one persisted session on disk from a "previous run".
Future<FlutterSessionManager> _populatedManager(ExecutionEnv env) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  await repo.create(
    JsonlSessionCreateOptions(
      id: 'c0ffee01-restored-chat',
      cwd: 'openai-completions',
      metadata: const {'agent': 'fa', 'model': 'old-model'},
    ),
  );
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
  manager.addSession('aaa00001-first-chat', _fakeService(env));
  manager.addSession('bbb00002-second-chat', _fakeService(env));
  return manager;
}

/// The sidebar at its real width ([kSessionSidebarWidth]) so the snapshots
/// match what the chat screen renders.
Widget _sidebar(FlutterSessionManager manager) {
  return SizedBox(
    width: kSessionSidebarWidth,
    child: SessionSidebar(manager: manager),
  );
}

/// Waits until the whole sidebar finished loading.
///
/// `_loadApps` (unawaited from `initState`) seeds the bundled demo apps via
/// `rootBundle` — real async I/O that `pumpAndSettle` does NOT wait for (no
/// frame is scheduled between the last write and the final `setState`), so
/// the apps section would race the snapshot. Alternating `runAsync` delays
/// (the real event loop drives the seeding) with `pump` (rebuilds with
/// whatever state landed) converges deterministically.
Future<void> _settleSidebar(WidgetTester tester) async {
  for (var i = 0; i < 200 && find.text('Calculator').evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
  // Sanity: every section rendered before the snapshot.
  expect(find.text('test-model'), findsWidgets);
  expect(find.textContaining('aaa00001'), findsOneWidget);
  expect(find.textContaining('bbb00002'), findsOneWidget);
  expect(find.textContaining('c0ffee01'), findsOneWidget);
  expect(find.text('Calculator'), findsOneWidget);
}

void main() {
  testWidgets('populated: model card, sessions, persisted, apps', (
    tester,
  ) async {
    _mockBundledAppAssets();
    final env = MemoryExecutionEnv();
    final manager = await _populatedManager(env);

    await pumpGolden(tester, _sidebar(manager));
    await _settleSidebar(tester);

    await expectGolden(tester, 'sidebar_populated');
  });

  testWidgets('empty: no sessions at all', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');

    await pumpGolden(tester, _sidebar(manager));

    await expectGolden(tester, 'sidebar_empty');
  });

  testWidgets('populated sidebar in Russian', (tester) async {
    _mockBundledAppAssets();
    final env = MemoryExecutionEnv();
    final manager = await _populatedManager(env);

    await pumpGolden(tester, _sidebar(manager), locale: const Locale('ru'));
    await _settleSidebar(tester);

    await expectGolden(tester, 'sidebar_populated_ru');
  });

  testWidgets('delete session confirmation dialog', (tester) async {
    _mockBundledAppAssets();
    final env = MemoryExecutionEnv();
    final manager = await _populatedManager(env);

    await pumpGolden(tester, _sidebar(manager));
    await _settleSidebar(tester);

    // The trailing delete button of the first (active) session tile.
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();

    await expectGolden(tester, 'sidebar_delete_dialog');
  });
}

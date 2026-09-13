// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Goldens for the session search field pinned at the top of the session
/// lists (issue #200): the macOS wide sidebar and the mobile drawer.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fa/apps/session_chat_sheet.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/widgets/session_search_field.dart';
import 'package:fa/ui/widgets/sidebar_sessions_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'golden_test_helper.dart';

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
      streamFunction: (model, context, {cancelToken}) {
        final stream = AssistantMessageEventStream();
        final message = AssistantMessage(
          content: [TextContent(text: 'ok')],
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
}

/// Widget tests never touch the real ASR method channel.
final class _FakeAsrApi implements AsrApi {
  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> requestAccess() async => true;

  @override
  Future<void> startRecording() async {}

  @override
  Future<AsrRecording> stopRecording() async =>
      (path: '/tmp/fah-mic-test.m4a', durationMs: 5000, sampleRate: 44100);

  @override
  Future<Uint8List> readRecording(String path) async =>
      Uint8List.fromList(const [1, 2, 3]);
}

/// Writes a disk session backdated to the fixed instant [at].
///
/// Fresh sessions render a live clock time in their tile subtitle, which
/// would flake the snapshot at every minute tick — a fixed date (> 7 days
/// in the past, forever) renders a stable month-day label instead.
Future<SessionMetadata> makeSession(
  JsonlSessionRepo repo,
  MemoryExecutionEnv env,
  String userText,
  String cwd,
  DateTime at,
) async {
  final session = await repo.create(
    JsonlSessionCreateOptions(
      cwd: cwd,
      metadata: const {'agent': 'fa', 'model': 'test-model'},
    ),
  );
  await session.appendMessage(UserMessage.text(userText));
  final meta = await session.getMetadata();
  final content = (await env.readTextFile(meta.path)).getOrThrow();
  final lines = content.split('\n');
  final header = jsonDecode(lines.first) as Map<String, dynamic>;
  header['timestamp'] = at.toIso8601String();
  lines[0] = jsonEncode(header);
  (await env.writeFile(meta.path, lines.join('\n'))).getOrThrow();
  env.setMtime(meta.path, at.millisecondsSinceEpoch);
  return (await repo.list()).firstWhere((m) => m.id == meta.id);
}

void main() {
  setUpAll(() async {
    await ensureGoldenFonts();
    await initializeDateFormatting('en');
  });

  /// Desktop sidebar with a realistic mixed list: named sessions and
  /// project folders on fixed past dates.
  Future<void> pumpSidebar(WidgetTester tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');

    final goal = await makeSession(
      repo,
      env,
      'Refactor the exporter',
      '/work/goal_builder',
      DateTime.utc(2026, DateTime.august, 20, 10),
    );
    final review = await makeSession(
      repo,
      env,
      'Review agent diff',
      '/work/goal_builder',
      DateTime.utc(2026, DateTime.august, 19, 10),
    );
    final chores = await makeSession(
      repo,
      env,
      'Groceries and invoices',
      'test',
      DateTime.utc(2026, DateTime.august, 18, 10),
    );
    final deploy = await makeSession(
      repo,
      env,
      'Ship the release',
      '/srv/deploy',
      DateTime.utc(2026, DateTime.august, 17, 10),
    );

    await pumpGolden(
      tester,
      SidebarSessionsList(
        manager: manager,
        persistedSessions: [goal, review, chores, deploy],
        sessionInfoNames: {
          goal.id: 'goal_builder',
          review.id: 'agent review',
          chores.id: 'Chores',
          deploy.id: 'deploy watch',
        },
      ),
      size: goldenSizeDesktop,
      wrap: (child) => Scaffold(body: child),
    );
  }

  /// Types [query] into the only search field, waits out the debounce and
  /// drops the caret so snapshots never depend on the cursor-blink phase.
  Future<void> typeAndBlur(WidgetTester tester, String query) async {
    await tester.enterText(find.byType(SessionSearchField), query);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
  }

  testWidgets('wide sidebar: search row pinned above the session list', (
    tester,
  ) async {
    await pumpSidebar(tester);
    await expectGolden(tester, 'session_search_sidebar_empty');
  });

  testWidgets('wide sidebar: a query filters to matching sessions', (
    tester,
  ) async {
    await pumpSidebar(tester);
    // 'goal' matches the session NAME and the project folder; unrelated
    // rows hide.
    await typeAndBlur(tester, 'goal');
    await expectGolden(tester, 'session_search_sidebar_results');
  });

  testWidgets('wide sidebar: no matches shows the empty state', (tester) async {
    await pumpSidebar(tester);
    await typeAndBlur(tester, 'zzz');
    await expectGolden(tester, 'session_search_sidebar_no_results');
  });

  testWidgets('mobile drawer: the field filters the drawer list', (
    tester,
  ) async {
    // Live sessions with FIXED creation dates — the default would stamp
    // a wall clock time into every tile subtitle and flake the snapshot.
    final env = MemoryExecutionEnv();
    final services = {'sess-a': _fakeService(env), 'sess-b': _fakeService(env)};
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession(
        'sess-a',
        services['sess-a']!,
        createdAt: DateTime.utc(2026, DateTime.august, 20, 10),
        lastUpdatedAt: DateTime.utc(2026, DateTime.august, 20, 10),
      )
      ..addSession(
        'sess-b',
        services['sess-b']!,
        createdAt: DateTime.utc(2026, DateTime.august, 19, 10),
        lastUpdatedAt: DateTime.utc(2026, DateTime.august, 19, 10),
      );
    await pumpGolden(
      tester,
      SessionChatSheet(manager: manager, asr: _FakeAsrApi()),
      size: goldenSizePhone,
      wrap: (child) => Scaffold(body: child),
    );
    await tester.tap(find.byKey(const ValueKey('sessionChatDrawerButton')));
    await tester.pumpAndSettle();

    await typeAndBlur(tester, 'sess-a');
    expect(
      find.byKey(const ValueKey('sessionChatDrawerEntry:sess-a')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('sessionChatDrawerEntry:sess-b')),
      findsNothing,
    );
    await expectGolden(tester, 'session_search_drawer');
  });
}

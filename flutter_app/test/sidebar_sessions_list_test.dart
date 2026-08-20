// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/widgets/sidebar_sessions_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

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
      systemPrompt: 'You are Fa.',
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

void main() {
  setUpAll(() async {
    await initializeDateFormatting('en');
  });

  late MemoryExecutionEnv env;
  late FlutterSessionManager manager;
  late JsonlSessionRepo repo;

  setUp(() {
    env = MemoryExecutionEnv();
    manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
    repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  });

  Future<SessionMetadata> persistSession({String? userText}) async {
    final session = await repo.create(
      JsonlSessionCreateOptions(
        cwd: 'test',
        metadata: const {'agent': 'fa', 'model': 'test-model'},
      ),
    );
    if (userText != null) {
      await session.appendMessage(UserMessage.text(userText));
    }
    return session.getMetadata();
  }

  /// Rewrites the session file header so the session looks created yesterday.
  Future<SessionMetadata> ageSession(SessionMetadata metadata) async {
    final content = (await env.readTextFile(metadata.path)).getOrThrow();
    final lines = content.split('\n');
    final header = jsonDecode(lines.first) as Map<String, dynamic>;
    header['timestamp'] = DateTime.now()
        .subtract(const Duration(days: 1))
        .toIso8601String();
    lines[0] = jsonEncode(header);
    (await env.writeFile(metadata.path, lines.join('\n'))).getOrThrow();
    return (await repo.list()).firstWhere((m) => m.id == metadata.id);
  }

  Widget harness({
    SessionNamesStore? names,
    List<SessionMetadata> persisted = const [],
    ValueChanged<SessionMetadata>? onOpenPersisted,
  }) {
    return MaterialApp(
      theme: buildFahTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SidebarSessionsList(
          manager: manager,
          sessionNamesStore: names,
          persistedSessions: persisted,
          onOpenPersisted: onOpenPersisted,
        ),
      ),
    );
  }

  testWidgets('lists persisted disk sessions alongside the live ones', (
    tester,
  ) async {
    manager.addSession('live-1', _fakeService(env));
    final old = await ageSession(await persistSession(userText: 'hi'));

    await tester.pumpWidget(
      harness(
        names: SessionNamesStore.inMemory({
          'live-1': 'Live chat',
          old.id: 'Old chat',
        }),
        persisted: [old],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Live chat'), findsOneWidget);
    expect(find.text('Old chat'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    // Group header + the old session's subtitle both read "Yesterday".
    expect(find.text('Yesterday'), findsWidgets);
  });

  testWidgets('tapping a persisted-only session opens it from disk', (
    tester,
  ) async {
    manager.addSession('live-1', _fakeService(env));
    final old = await ageSession(await persistSession(userText: 'hi'));
    SessionMetadata? opened;

    await tester.pumpWidget(
      harness(
        names: SessionNamesStore.inMemory({old.id: 'Old chat'}),
        persisted: [old],
        onOpenPersisted: (m) => opened = m,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Old chat'));
    await tester.pumpAndSettle();
    expect(opened?.id, old.id);
    // The live session was not switched away.
    expect(manager.activeId, 'live-1');
  });

  testWidgets('a persisted session that is already live is not duplicated', (
    tester,
  ) async {
    final liveMeta = await persistSession(userText: 'live session');
    manager.addSession(liveMeta.id, _fakeService(env));

    await tester.pumpWidget(
      harness(
        names: SessionNamesStore.inMemory({liveMeta.id: 'Shared chat'}),
        persisted: [liveMeta],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Shared chat'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
  });

  testWidgets('the tile menu offers rename and delete', (tester) async {
    manager.addSession('live-1', _fakeService(env));
    final names = SessionNamesStore.inMemory({'live-1': 'Live chat'});

    await tester.pumpWidget(harness(names: names));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_horiz).first);
    await tester.pumpAndSettle();

    expect(find.text('Rename session'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
  });

  testWidgets('rename from the tile menu writes the custom title', (
    tester,
  ) async {
    manager.addSession('live-1', _fakeService(env));
    final names = SessionNamesStore.inMemory();

    await tester.pumpWidget(harness(names: names));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_horiz).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename session'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'My chat');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(names.titleFor('live-1'), 'My chat');
    expect(find.text('My chat'), findsOneWidget);
  });

  testWidgets('delete from the tile menu removes a persisted session', (
    tester,
  ) async {
    manager.addSession('live-1', _fakeService(env));
    final old = await ageSession(await persistSession(userText: 'hi'));

    await tester.pumpWidget(
      harness(
        names: SessionNamesStore.inMemory({old.id: 'Old chat'}),
        persisted: [old],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_horiz).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    // Confirmation dialog names the session.
    expect(find.text('Delete session?'), findsOneWidget);
    expect(find.text('Old chat'), findsWidgets);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(await repo.list(), isEmpty);
  });

  testWidgets('deleting the active live session mints a fresh one', (
    tester,
  ) async {
    final meta = await persistSession(userText: 'live session');
    manager.addSession(meta.id, _fakeService(env));

    await tester.pumpWidget(harness(persisted: [meta]));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_horiz).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    // File gone, and the shell is not stranded: a fresh session is active.
    expect(await repo.list(), isEmpty);
    expect(manager.active, isNotNull);
    expect(manager.active!.id, isNot(meta.id));
  });
}

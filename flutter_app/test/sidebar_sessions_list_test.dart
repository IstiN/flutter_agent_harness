// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/project_mount_env.dart';
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

  Future<SessionMetadata> persistSession({
    String? userText,
    String cwd = 'test',
  }) async {
    final session = await repo.create(
      JsonlSessionCreateOptions(
        cwd: cwd,
        metadata: const {'agent': 'fa', 'model': 'test-model'},
      ),
    );
    if (userText != null) {
      await session.appendMessage(UserMessage.text(userText));
    }
    return session.getMetadata();
  }

  /// Rewrites the session file header so the session looks created yesterday,
  /// and backdates its mtime so it sorts into the "Yesterday" group.
  Future<SessionMetadata> ageSession(SessionMetadata metadata) async {
    final content = (await env.readTextFile(metadata.path)).getOrThrow();
    final lines = content.split('\n');
    final header = jsonDecode(lines.first) as Map<String, dynamic>;
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    header['timestamp'] = yesterday.toIso8601String();
    lines[0] = jsonEncode(header);
    (await env.writeFile(metadata.path, lines.join('\n'))).getOrThrow();
    env.setMtime(metadata.path, yesterday.millisecondsSinceEpoch);
    return (await repo.list()).firstWhere((m) => m.id == metadata.id);
  }

  Widget harness({
    SessionNamesStore? names,
    List<SessionMetadata> persisted = const [],
    Map<String, String> sessionInfoNames = const {},
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
          sessionInfoNames: sessionInfoNames,
          onOpenPersisted: onOpenPersisted,
        ),
      ),
    );
  }

  test('readSessionNames returns CLI-written session_info names', () async {
    final meta = await persistSession(userText: 'hi');
    final session = await repo.open(meta);
    await session.appendSessionName('CLI title');
    final names = await manager.readSessionNames([
      await session.getMetadata(),
    ]);
    expect(names, {meta.id: 'CLI title'});
  });

  test('readSessionNames skips nameless sessions', () async {
    final meta = await persistSession(userText: 'hi');
    expect(await manager.readSessionNames([meta]), isEmpty);
  });

  testWidgets('shows the session_info name; the app-local rename wins', (
    tester,
  ) async {
    final named = await ageSession(await persistSession(userText: 'hi'));

    await tester.pumpWidget(
      harness(
        names: SessionNamesStore.inMemory(),
        persisted: [named],
        sessionInfoNames: {named.id: 'CLI title'},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('CLI title'), findsOneWidget);

    // An app-local rename stays an override over the JSONL name.
    await tester.pumpWidget(
      harness(
        names: SessionNamesStore.inMemory({named.id: 'App override'}),
        persisted: [named],
        sessionInfoNames: {named.id: 'CLI title'},
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('App override'), findsOneWidget);
  });

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
    // The list groups by the session's project folder: the live session
    // (sandbox cwd, no basename) lands in "Personal", the disk session in
    // its origin folder's group.
    expect(find.text('Personal'), findsOneWidget);
  });

  testWidgets('a live session keeps its own folder label from disk metadata', (
    tester,
  ) async {
    // The session was created in /work/original; the live env's cwd ('/')
    // has no useful basename, so without the metadata lookup the tile would
    // lose its folder label the moment the session opens.
    final session = await repo.create(
      JsonlSessionCreateOptions(
        cwd: '/work/original',
        metadata: const {'agent': 'fa', 'model': 'test-model'},
      ),
    );
    await session.appendMessage(UserMessage.text('hi'));
    final meta = await session.getMetadata();
    manager.addSession(meta.id, _fakeService(env));

    await tester.pumpWidget(harness(persisted: [meta]));
    await tester.pumpAndSettle();

    expect(find.text('original'), findsOneWidget);
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
    expect(find.text('Today'), findsNothing);
  });

  testWidgets('sessions group by their origin folder, not by date', (
    tester,
  ) async {
    // Two projects, one session each, plus a sandbox session: the groups
    // are the folder basenames (in activity order), the tiles stay under
    // their project's header. Created oldest-first so the activity order
    // (and with it the group order) is deterministic.
    final aiM = await persistSession(
      userText: 'ai.m work',
      cwd: '/Users/x/git/ai.m',
    );
    final flutterAgent = await persistSession(
      userText: 'fa work',
      cwd: '/Users/x/git/flutter_agent',
    );
    final personal = await persistSession(userText: 'sandbox', cwd: '/');

    await tester.pumpWidget(harness(persisted: [flutterAgent, aiM, personal]));
    await tester.pumpAndSettle();

    expect(find.text('flutter_agent'), findsOneWidget);
    expect(find.text('ai.m'), findsOneWidget);
    expect(find.text('Personal'), findsOneWidget);
    // Date headers are gone.
    expect(find.text('Today'), findsNothing);
    expect(find.text('Yesterday'), findsNothing);
    // Headers follow their first entry's activity: flutter_agent (created
    // last, freshest) precedes ai.m.
    expect(
      tester.getTopLeft(find.text('flutter_agent')).dy,
      lessThan(tester.getTopLeft(find.text('ai.m')).dy),
    );
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

  testWidgets('tile shows the session folder (basename of cwd)', (
    tester,
  ) async {
    manager.addSession('live-1', _fakeService(env));
    final names = SessionNamesStore.inMemory({'live-1': 'Live chat'});

    await tester.pumpWidget(harness(names: names));
    await tester.pumpAndSettle();

    // The fake service's env (MemoryExecutionEnv()) reports cwd '/' — that
    // looks like an unscoped sandbox root, so the tile should NOT show a
    // folder line at all (no useful basename).
    expect(find.byIcon(Icons.folder_outlined), findsNothing);

    // Sanity: the title still renders.
    expect(find.text('Live chat'), findsOneWidget);
  });

  testWidgets('a session scoped into a real folder shows the folder basename', (
    tester,
  ) async {
    // Build a dedicated env rooted at the project path so basename(mount)
    // is meaningful.
    final scopedEnv = MemoryExecutionEnv(
      cwd: '/Users/test/Documents/my-project',
    );
    final scopedManager = FlutterSessionManager(
      env: scopedEnv,
      sessionsRoot: '/sessions',
    );
    scopedManager.addSession('live-1', _fakeService(scopedEnv));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SidebarSessionsList(
            manager: scopedManager,
            sessionNamesStore: SessionNamesStore.inMemory(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The folder basename is the GROUP header now (the per-tile cwd label
    // is gone — it duplicated the header).
    expect(find.text('my-project'), findsOneWidget);
  });

  testWidgets('a mounted project folder shows the host folder basename', (
    tester,
  ) async {
    final baseEnv = MemoryExecutionEnv();
    await baseEnv.createDir('/host/repo');
    final mountEnv = ProjectMountEnv(baseEnv)..mountedRoot = '/host/repo';
    final scopedManager = FlutterSessionManager(
      env: mountEnv,
      sessionsRoot: '/sessions',
    );
    scopedManager.addSession('live-1', _fakeService(mountEnv));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SidebarSessionsList(
            manager: scopedManager,
            sessionNamesStore: SessionNamesStore.inMemory(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The folder basename is the GROUP header now (the per-tile cwd label
    // is gone — it duplicated the header).
    expect(find.text('repo'), findsOneWidget);
  });

  testWidgets('a wrapped mounted env still shows the host folder basename', (
    tester,
  ) async {
    final baseEnv = MemoryExecutionEnv();
    await baseEnv.createDir('/host/repo');
    final mountEnv = ProjectMountEnv(baseEnv)..mountedRoot = '/host/repo';
    // The real app wraps the mount env in SecretsExecutionEnv; the sidebar
    // must unwrap it to find the host path.
    final wrappedEnv = SecretsExecutionEnv(mountEnv, const {});
    final scopedManager = FlutterSessionManager(
      env: wrappedEnv,
      sessionsRoot: '/sessions',
    );
    scopedManager.addSession('live-1', _fakeService(wrappedEnv));

    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SidebarSessionsList(
            manager: scopedManager,
            sessionNamesStore: SessionNamesStore.inMemory(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The folder basename is the GROUP header now (the per-tile cwd label
    // is gone — it duplicated the header).
    expect(find.text('repo'), findsOneWidget);
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

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
import 'package:fa/ui/widgets/session_search_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    ValueChanged<String>? onOpenLiveSession,
    String? pendingSessionId,
    String? selectedSessionId,
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
          onOpenLiveSession: onOpenLiveSession,
          pendingSessionId: pendingSessionId,
          selectedSessionId: selectedSessionId,
        ),
      ),
    );
  }

  test('readSessionNames returns CLI-written session_info names', () async {
    final meta = await persistSession(userText: 'hi');
    final session = await repo.open(meta);
    await session.appendSessionName('CLI title');
    final names = await manager.readSessionNames([await session.getMetadata()]);
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

  testWidgets('tapping a live row routes through onOpenLiveSession', (
    tester,
  ) async {
    // Hosted surfaces must re-dispatch live-row taps through the relay —
    // the local slot only holds the boot attach, so manager.switchTo on
    // such a row is a silent no-op and the transcript never re-attaches.
    final liveMeta = await persistSession(userText: 'live session');
    manager.addSession(liveMeta.id, _fakeService(env));
    final other = await persistSession(userText: 'other');
    manager.addSession(other.id, _fakeService(env));
    String? openedLive;

    await tester.pumpWidget(
      harness(
        names: SessionNamesStore.inMemory({liveMeta.id: 'Live chat'}),
        onOpenLiveSession: (id) => openedLive = id,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Live chat'));
    await tester.pumpAndSettle();
    expect(openedLive, liveMeta.id);
  });

  testWidgets('without onOpenLiveSession a live tap falls back to switchTo', (
    tester,
  ) async {
    final liveMeta = await persistSession(userText: 'live session');
    manager.addSession(liveMeta.id, _fakeService(env));

    await tester.pumpWidget(
      harness(names: SessionNamesStore.inMemory({liveMeta.id: 'Live chat'})),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Live chat'));
    await tester.pumpAndSettle();
    // The local fallback still switches the manager to the tapped row.
    expect(manager.activeId, liveMeta.id);
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

    await tester.enterText(
      // Scope to the dialog: the sidebar itself now hosts the search
      // field (issue #200), so an unscoped TextField finder is ambiguous.
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'My chat',
    );
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

  /// Regression for the user-reported bug: clicking an OLDER session in the
  /// sidebar must NOT teleport it to the top of the list (the old pending
  /// jump-to-top parked a "1:08 PM" row above a fresher "8:42 PM" row). The
  /// click moves only the selection highlight; the order is recency-sorted
  /// and stays put.
  testWidgets('clicking an older session highlights it in place, no reorder', (
    tester,
  ) async {
    manager.addSession('live-1', _fakeService(env));
    final older = await ageSession(await persistSession(userText: 'older'));
    await tester.pumpWidget(
      harness(
        persisted: [older],
        sessionInfoNames: {'live-1': 'Live chat', older.id: 'Older chat'},
        selectedSessionId: 'live-1',
      ),
    );
    await tester.pumpAndSettle();

    double topOf(String title) => tester.getTopLeft(find.text(title)).dy;
    // Recency order: the live (fresher) session first.
    expect(topOf('Live chat'), lessThan(topOf('Older chat')));

    FontWeight weightOf(String title) =>
        tester.widget<Text>(find.text(title)).style!.fontWeight!;
    expect(weightOf('Live chat'), FontWeight.w600); // selected in place
    expect(weightOf('Older chat'), FontWeight.w400);

    // The click is in flight (pending) and selection moved to the older
    // session — exactly what the shell passes down mid-switch.
    await tester.pumpWidget(
      harness(
        persisted: [older],
        sessionInfoNames: {'live-1': 'Live chat', older.id: 'Older chat'},
        pendingSessionId: older.id,
        selectedSessionId: older.id,
      ),
    );
    await tester.pumpAndSettle();

    // THE regression: the clicked row must keep its position — highlight
    // moves to it IN PLACE, the fresher row stays on top.
    expect(topOf('Live chat'), lessThan(topOf('Older chat')));
    expect(weightOf('Older chat'), FontWeight.w600); // now selected
    expect(weightOf('Live chat'), FontWeight.w400); // deselected

    // And after the pending settles (broadcast landed): still in place.
    await tester.pumpWidget(
      harness(
        persisted: [older],
        sessionInfoNames: {'live-1': 'Live chat', older.id: 'Older chat'},
        selectedSessionId: older.id,
      ),
    );
    await tester.pumpAndSettle();
    expect(topOf('Live chat'), lessThan(topOf('Older chat')));
    expect(weightOf('Older chat'), FontWeight.w600);

    // The tap routes to onOpenPersisted with the clicked session.
    var opened;
    await tester.pumpWidget(
      harness(
        persisted: [older],
        sessionInfoNames: {'live-1': 'Live chat', older.id: 'Older chat'},
        selectedSessionId: older.id,
        onOpenPersisted: (m) => opened = m,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Older chat'));
    await tester.pumpAndSettle();
    expect(opened, isNotNull);
    expect(opened.id, older.id);
  });

  group('session search (issue #200)', () {
    EditableText editableOf(WidgetTester tester) => tester.widget<EditableText>(
      find.descendant(
        of: find.byType(SessionSearchField),
        matching: find.byType(EditableText),
      ),
    );

    Future<void> typeQuery(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(SessionSearchField), text);
      // The filter is debounced (~150 ms) — one idle pump changes nothing.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    }

    // A subagent child: the header metadata both hosts' child session
    // factories write (`agent: subagent, parent: <mainSessionId>`) —
    // the SAME helper the tree group uses.
    Future<SessionMetadata> persistChild({
      required String parentId,
      String cwd = 'test',
    }) async {
      final session = await repo.create(
        JsonlSessionCreateOptions(
          cwd: cwd,
          metadata: {'agent': 'subagent', 'parent': parentId},
        ),
      );
      return session.getMetadata();
    }

    bool parentDimmed(WidgetTester tester, String title) => tester
        .widgetList<Opacity>(
          find.ancestor(of: find.text(title), matching: find.byType(Opacity)),
        )
        .any((o) => o.opacity == 0.45);

    testWidgets('filters as-you-type: non-matches hide, clear restores '
        '(AC1, IT-sidebar)', (tester) async {
      final goal = await persistSession(
        userText: 'goal work',
        cwd: '/work/goal_builder',
      );
      final other = await persistSession(userText: 'other work');

      await tester.pumpWidget(
        harness(
          persisted: [goal, other],
          sessionInfoNames: {goal.id: 'goal_builder', other.id: 'Chores'},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Chores'), findsOneWidget);

      await typeQuery(tester, 'goal');
      // Both the tile title AND its folder group header read
      // 'goal_builder'; the non-matching row hides.
      expect(find.text('goal_builder'), findsNWidgets(2));
      expect(find.text('Chores'), findsNothing);

      // The ✕ affordance restores the full list instantly.
      await tester.tap(find.byIcon(Icons.cancel));
      await tester.pumpAndSettle();
      expect(find.text('goal_builder'), findsNWidgets(2));
      expect(find.text('Chores'), findsOneWidget);
    });

    testWidgets('matches id, cwd basename and folds Cyrillic case '
        '(AC1, E5)', (tester) async {
      final ru = await persistSession(userText: 'review');
      final project = await persistSession(
        userText: 'project',
        cwd: '/work/goal_builder',
      );
      await tester.pumpWidget(
        harness(
          persisted: [ru, project],
          sessionInfoNames: {ru.id: 'Ревью', project.id: 'x'},
        ),
      );
      await tester.pumpAndSettle();

      // Unicode-aware lowercase: the query's case folds like the title's.
      await typeQuery(tester, 'ревью');
      expect(find.text('Ревью'), findsOneWidget);
      expect(find.text('x'), findsNothing);

      await typeQuery(tester, 'goal_builder');
      expect(find.text('Ревью'), findsNothing);
      // The matching row keeps its project folder group header (the
      // finder is scoped to the list: the search FIELD itself holds the
      // query text).
      expect(
        find.descendant(
          of: find.byType(ListView),
          matching: find.text('goal_builder'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('name matches rank first (AC1)', (tester) async {
      final byName = await persistSession(userText: 'named');
      final byCwd = await persistSession(
        userText: 'cwd match',
        cwd: '/work/alpha',
      );
      // byCwd was created later, so it would be first unfiltered.
      await tester.pumpWidget(
        harness(
          persisted: [byCwd, byName],
          sessionInfoNames: {byCwd.id: 'gamma work', byName.id: 'Alpha'},
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('gamma work')).dy,
        lessThan(tester.getTopLeft(find.text('Alpha')).dy),
      );

      await typeQuery(tester, 'alpha');
      // The title hit jumps above the cwd hit.
      expect(
        tester.getTopLeft(find.text('Alpha')).dy,
        lessThan(tester.getTopLeft(find.text('gamma work')).dy),
      );
    });

    testWidgets('the filter is debounced: one keystroke frame changes '
        'nothing yet (E3)', (tester) async {
      final goal = await persistSession(
        userText: 'goal work',
        cwd: '/work/goal_builder',
      );
      final other = await persistSession(userText: 'other work');
      await tester.pumpWidget(
        harness(
          persisted: [goal, other],
          sessionInfoNames: {goal.id: 'goal_builder', other.id: 'Chores'},
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(SessionSearchField), 'goal');
      await tester.pump();
      // Debounce has not fired: the full list is still there.
      expect(find.text('Chores'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Chores'), findsNothing);
    });

    testWidgets('no matches shows the empty state with a clear affordance; '
        'the active marker survives the detour (E1, E2)', (tester) async {
      final goal = await persistSession(
        userText: 'goal work',
        cwd: '/work/goal_builder',
      );
      await tester.pumpWidget(
        harness(
          persisted: [goal],
          sessionInfoNames: {goal.id: 'goal_builder'},
          selectedSessionId: goal.id,
        ),
      );
      await tester.pumpAndSettle();

      await typeQuery(tester, 'zzz');
      expect(find.text('No sessions match "zzz"'), findsOneWidget);
      expect(find.text('Clear'), findsOneWidget);

      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      // The active row comes back with its selected styling (E2: nothing
      // about the session state changed while it was filtered out).
      expect(find.text('No sessions match "zzz"'), findsNothing);
      expect(
        tester
            .widget<SessionTile>(
              find.widgetWithText(SessionTile, 'goal_builder').first,
            )
            .isActive,
        isTrue,
      );
    });

    testWidgets('Cmd+F focuses the field, Esc clears and unfocuses '
        '(AC3)', (tester) async {
      final goal = await persistSession(
        userText: 'goal work',
        cwd: '/work/goal_builder',
      );
      await tester.pumpWidget(
        harness(persisted: [goal], sessionInfoNames: {goal.id: 'goal_builder'}),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.metaLeft,
        platform: 'macos',
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF, platform: 'macos');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF, platform: 'macos');
      await tester.sendKeyUpEvent(
        LogicalKeyboardKey.metaLeft,
        platform: 'macos',
      );
      await tester.pump();
      expect(editableOf(tester).focusNode.hasFocus, isTrue);

      await typeQuery(tester, 'goal');
      expect(find.text('Chores'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('goal_builder'), findsNWidgets(2));
      expect(editableOf(tester).focusNode.hasFocus, isFalse);
    });

    testWidgets('a matching child surfaces under its dimmed parent; '
        'non-matching siblings hide (AC2, IT-tree-filter)', (tester) async {
      final main = await persistSession(userText: 'main');
      final child = await persistChild(parentId: main.id);
      final sibling = await persistChild(parentId: main.id);

      await tester.pumpWidget(
        harness(
          names: SessionNamesStore.inMemory({
            main.id: 'Main chat',
            child.id: 'goal_builder',
            sibling.id: 'scout',
          }),
          persisted: [main, child, sibling],
        ),
      );
      await tester.pumpAndSettle();

      await typeQuery(tester, 'goal_builder');
      // The matching child is in (scoped to the list: the field itself
      // holds the query text); the non-matching sibling stays hidden.
      expect(
        find.descendant(
          of: find.byType(ListView),
          matching: find.text('goal_builder'),
        ),
        findsOneWidget,
      );
      expect(find.text('scout'), findsNothing);
      // The parent did NOT match — it renders only as dimmed context,
      // force-expanded under the query.
      expect(find.text('Main chat'), findsOneWidget);
      expect(parentDimmed(tester, 'Main chat'), isTrue);
    });

    testWidgets('a matching parent keeps its collapse state; no dimming '
        '(AC2)', (tester) async {
      final main = await persistSession(userText: 'main');
      final child = await persistChild(parentId: main.id);

      await tester.pumpWidget(
        harness(
          names: SessionNamesStore.inMemory({
            main.id: 'goal_builder',
            child.id: 'child session',
          }),
          persisted: [main, child],
        ),
      );
      await tester.pumpAndSettle();

      await typeQuery(tester, 'goal_builder');
      // The parent matched on its own: a normal (non-dimmed) row, the
      // non-matching child stays collapsed away — nothing is forced.
      expect(
        find.descendant(
          of: find.byType(ListView),
          matching: find.text('goal_builder'),
        ),
        findsOneWidget,
      );
      expect(find.text('child session'), findsNothing);
      expect(parentDimmed(tester, 'goal_builder'), isFalse);
    });
  });
  group('session tree (issue #198)', () {
    // A subagent child: the header metadata both hosts' child session
    // factories write (`agent: subagent, parent: <mainSessionId>`).
    Future<SessionMetadata> persistChild({
      required String parentId,
      String cwd = 'test',
    }) async {
      final session = await repo.create(
        JsonlSessionCreateOptions(
          cwd: cwd,
          metadata: {'agent': 'subagent', 'parent': parentId},
        ),
      );
      return session.getMetadata();
    }

    testWidgets('subagent sessions collapse under a count badge by '
        'default', (tester) async {
      final main = await persistSession(userText: 'main');
      final childA = await persistChild(parentId: main.id);
      final childB = await persistChild(parentId: main.id);

      await tester.pumpWidget(
        harness(
          names: SessionNamesStore.inMemory({
            main.id: 'Main chat',
            childA.id: 'goal_builder',
            childB.id: 'scout',
          }),
          persisted: [main, childA, childB],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Main chat'), findsOneWidget);
      expect(find.text('2 agents'), findsOneWidget);
      // Collapsed: the children stay hidden until the badge is tapped.
      expect(find.text('goal_builder'), findsNothing);
      expect(find.text('scout'), findsNothing);
    });

    testWidgets('the badge expands the child list and collapses it back', (
      tester,
    ) async {
      final main = await persistSession(userText: 'main');
      final child = await persistChild(parentId: main.id);

      await tester.pumpWidget(
        harness(
          names: SessionNamesStore.inMemory({
            main.id: 'Main chat',
            child.id: 'goal_builder',
          }),
          persisted: [main, child],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('1 agent'));
      await tester.pumpAndSettle();
      expect(find.text('goal_builder'), findsOneWidget);
      // Children indent under their parent.
      expect(
        tester.getTopLeft(find.text('goal_builder')).dx,
        greaterThan(tester.getTopLeft(find.text('Main chat')).dx),
      );

      await tester.tap(find.text('1 agent'));
      await tester.pumpAndSettle();
      expect(find.text('goal_builder'), findsNothing);
    });

    testWidgets('an active child auto-expands its parent group', (
      tester,
    ) async {
      final main = await persistSession(userText: 'main');
      final child = await persistChild(parentId: main.id);

      await tester.pumpWidget(
        harness(
          names: SessionNamesStore.inMemory({
            main.id: 'Main chat',
            child.id: 'goal_builder',
          }),
          persisted: [main, child],
          selectedSessionId: child.id,
        ),
      );
      await tester.pumpAndSettle();

      // No tap needed: the group forces open so the active row shows
      // (E2) — and no badge double-renders over it.
      expect(find.text('goal_builder'), findsOneWidget);
      expect(find.text('1 agent'), findsOneWidget);
    });

    testWidgets('unnamed children show as subagent <short-id>', (tester) async {
      final main = await persistSession(userText: 'main');
      final child = await persistChild(parentId: main.id);

      await tester.pumpWidget(
        harness(
          names: SessionNamesStore.inMemory({main.id: 'Main chat'}),
          persisted: [main, child],
          selectedSessionId: child.id,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('subagent ${child.id.substring(0, 8)}'), findsOneWidget);
    });

    testWidgets('an orphaned subagent renders top-level, marked', (
      tester,
    ) async {
      // E1: the parent was deleted (or lives in another cwd) — the child
      // stays visible, marked, and never crashes or cascades.
      final orphan = await persistChild(parentId: 'deleted-parent');

      await tester.pumpWidget(harness(persisted: [orphan]));
      await tester.pumpAndSettle();

      expect(
        find.text('subagent ${orphan.id.substring(0, 8)}'),
        findsOneWidget,
      );
      // Top-level: no count badge anywhere.
      expect(find.text('1 agent'), findsNothing);
    });

    testWidgets('pre-feature sessions (no header metadata) stay mains and '
        'the tree nests inside folder groups', (tester) async {
      final plainSession = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work/proj'),
      );
      final plain = await plainSession.getMetadata();
      final main = await persistSession(userText: 'main');
      final child = await persistChild(parentId: main.id);

      await tester.pumpWidget(
        harness(
          names: SessionNamesStore.inMemory({
            plain.id: 'Plain chat',
            main.id: 'Main chat',
            child.id: 'goal_builder',
          }),
          persisted: [plain, main, child],
          selectedSessionId: child.id,
        ),
      );
      await tester.pumpAndSettle();

      // The metadata-less session heads its own (badge-less) row inside
      // the same folder group as the family.
      expect(find.text('Plain chat'), findsOneWidget);
      expect(find.text('1 agent'), findsOneWidget);
      expect(find.text('goal_builder'), findsOneWidget);
    });

    testWidgets('child tiles carry the same 3-dot actions', (tester) async {
      final main = await persistSession(userText: 'main');
      final child = await persistChild(parentId: main.id);
      final names = SessionNamesStore.inMemory({
        main.id: 'Main chat',
        child.id: 'goal_builder',
      });

      await tester.pumpWidget(harness(names: names, persisted: [main, child]));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1 agent'));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_horiz).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rename session'));
      await tester.pumpAndSettle();
      // The dialog's field is the topmost TextField (the search field
      // coexists underneath).
      await tester.enterText(find.byType(TextField).last, 'Renamed child');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(names.titleFor(child.id), 'Renamed child');
      expect(find.text('Renamed child'), findsOneWidget);
    });
  });
}

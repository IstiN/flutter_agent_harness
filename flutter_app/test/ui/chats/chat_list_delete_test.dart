@TestOn('vm')
library;

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/ui/chats/chat_list_entry.dart';
import 'package:fa/ui/chats/chat_list_panel.dart';
import 'package:fa/ui/chats/network_inbox_adapter.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:fa_ui/fa_ui.dart'
    show FaVisualDirection, buildFaTheme, debugFaGlassAlwaysFake;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

AgentService _service(ExecutionEnv env) => AgentService(
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
      stream.end();
      return stream;
    },
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

Future<void> _drainAsync(WidgetTester tester) async {
  for (var i = 0; i < 50; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

final class _Fixture {
  _Fixture(this.names)
    : env = MemoryExecutionEnv(),
      network = FixtureNetworkInboxAdapter(
        items: const [
          NetworkInboxItem(
            kind: ChatListEntryKind.networkChannel,
            networkId: 'remote',
            id: 'network-stays',
            title: 'Network stays',
          ),
        ],
      ) {
    repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    manager = FlutterSessionManager(
      env: env,
      sessionsRoot: '/sessions',
      includeSharedSessionRoots: false,
    )..addSession('active', _service(env));
  }

  final Map<String, String> names;
  final MemoryExecutionEnv env;
  final FixtureNetworkInboxAdapter network;
  late final JsonlSessionRepo repo;
  late FlutterSessionManager manager;

  Future<SessionMetadata> persist(
    String id,
    String cwd, {
    Map<String, Object?> metadata = const {},
  }) async {
    final session = await repo.create(
      JsonlSessionCreateOptions(id: id, cwd: cwd, metadata: metadata),
    );
    await session.appendMessage(UserMessage.text('$id preview'));
    return session.getMetadata();
  }

  Widget app() => MaterialApp(
    theme: buildFaTheme(
      direction: FaVisualDirection.glass,
      brightness: Brightness.dark,
    ),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: WideLayoutShell(
      manager: manager,
      sessionNamesStore: SessionNamesStore.inMemory(names),
      networkInboxAdapter: network,
    ),
  );
}

Future<void> _pumpApp(WidgetTester tester, _Fixture fixture) async {
  await tester.pumpWidget(fixture.app());
  await _drainAsync(tester);
}

Future<void> _openFolder(WidgetTester tester, String path) async {
  await tester.tap(find.byKey(ValueKey('chatFolder-folder::$path')));
  await tester.pumpAndSettle();
}

Future<void> _deleteFromMenu(WidgetTester tester, String id) async {
  final entryId = ChatEntryId.local(id);
  final row = find.byKey(ValueKey('localSession-$id'));
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(mouse.removePointer);
  await mouse.addPointer(location: Offset.zero);
  await mouse.moveTo(tester.getCenter(row));
  await tester.pump();
  await tester.tap(find.byKey(ValueKey('chatMenu-$entryId')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Delete'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
  await _drainAsync(tester);
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('ru');
  });
  setUp(() => debugFaGlassAlwaysFake = true);
  tearDown(() => debugFaGlassAlwaysFake = false);

  testWidgets('successful menu delete removes drill-down row, search result, '
      'empty folder, and rebuilt data', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    final fixture = _Fixture(const {'deleted': 'Delete me'});
    await fixture.persist('deleted', '/work/project');
    await _pumpApp(tester, fixture);

    const folder = ValueKey('chatFolder-folder::/work/project');
    expect(find.byKey(folder), findsOneWidget);
    expect(find.text('Network stays'), findsOneWidget);
    await _openFolder(tester, '/work/project');
    expect(find.text('Delete me'), findsOneWidget);

    await _deleteFromMenu(tester, 'deleted');

    expect(
      (await fixture.repo.list()).map((item) => item.id),
      isNot(contains('deleted')),
    );
    expect(find.text('Delete me'), findsNothing);
    expect(find.byKey(const ValueKey('chatSidebarLocalBack')), findsOneWidget);
    final controller = tester
        .widget<ChatListPanel>(find.byType(ChatListPanel))
        .controller;
    controller.setSearch('Delete me');
    await tester.pump();
    expect(controller.visibleEntries.map((entry) => entry.id.value), isEmpty);
    controller.setSearch('');
    await tester.tap(find.byKey(const ValueKey('chatSidebarLocalBack')));
    await tester.pumpAndSettle();
    expect(find.byKey(folder), findsNothing);
    expect(find.text('Network stays'), findsOneWidget);

    fixture.manager = FlutterSessionManager(
      env: fixture.env,
      sessionsRoot: '/sessions',
      includeSharedSessionRoots: false,
    )..addSession('active', _service(fixture.env));
    await tester.pumpWidget(const SizedBox());
    await _pumpApp(tester, fixture);
    expect(find.byKey(folder), findsNothing);
    expect(find.text('Delete me'), findsNothing);
  });

  testWidgets(
    'folder and orphaned subagent stay when another session remains',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.reset);
      final fixture = _Fixture(const {
        'parent': 'Parent',
        'child': 'Child',
        'other': 'Other',
      });
      await fixture.persist('parent', '/work/project');
      await fixture.persist(
        'child',
        '/work/project',
        metadata: const {'agent': 'subagent', 'parent': 'parent'},
      );
      await fixture.persist('other', '/elsewhere/project');
      await _pumpApp(tester, fixture);
      await _openFolder(tester, '/work/project');

      await _deleteFromMenu(tester, 'parent');

      expect(find.text('Parent'), findsNothing);
      // The orphaned subagent is not a folder session (Telegram rows list
      // the folder's own sessions) — it stays in the projection and keeps
      // the folder destination alive.
      expect(find.text('Child'), findsNothing);
      expect(
        tester
            .widget<ChatListPanel>(find.byType(ChatListPanel))
            .controller
            .visibleEntries
            .map((entry) => entry.id.value),
        containsAll(<String>['child', 'other', 'network-stays']),
      );
      await tester.tap(find.byKey(const ValueKey('chatSidebarLocalBack')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('chatFolder-folder::/work/project')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('chatFolder-folder::/elsewhere/project')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'active delete selects a survivor and leaves a usable back path',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.reset);
      final fixture = _Fixture(const {'first': 'First', 'second': 'Second'});
      await fixture.persist('first', '/one');
      await fixture.persist('second', '/two');
      fixture.manager
        ..addSession('first', _service(fixture.env))
        ..addSession('second', _service(fixture.env));
      await _pumpApp(tester, fixture);
      await _openFolder(tester, '/two');

      await _deleteFromMenu(tester, 'second');

      expect(fixture.manager.activeId, 'first');
      expect(fixture.manager.active, isNotNull);
      expect(find.text('Second'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('chatSidebarLocalBack')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('chatFolder-folder::/two')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('chatFolder-folder::/one')),
        findsOneWidget,
      );
      await _openFolder(tester, '/one');
      final selected = tester
          .widget<ChatListPanel>(find.byType(ChatListPanel))
          .selectedEntryId;
      expect(selected, ChatEntryId.local('first'));
    },
  );

  testWidgets('failed backend delete keeps the row and reports failure', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
    final fixture = _Fixture(const {'deleted': 'Do not hide'});
    final metadata = await fixture.persist('deleted', '/work/project');
    await FileSessionPresenceStore(
      env: fixture.env,
      root: '/sessions',
    ).register(metadata.id, pid: 9999);
    await _pumpApp(tester, fixture);
    await _openFolder(tester, '/work/project');

    await _deleteFromMenu(tester, 'deleted');

    expect(find.textContaining('Could not delete session'), findsOneWidget);
    expect(find.text('Do not hide'), findsOneWidget);
    expect(
      (await fixture.repo.list()).map((item) => item.id),
      contains('deleted'),
    );
    await tester.tap(find.byKey(const ValueKey('chatSidebarLocalBack')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('chatFolder-folder::/work/project')),
      findsOneWidget,
    );
  });
}

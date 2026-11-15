// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Goldens for the session 3-dot actions menu (issue #863 review round 2):
/// on hosted surfaces (extension panel / relay shell) the Delete entry is
/// gated with the honest "not deletable here" tile instead of offering a
/// permanent dead-end; local listings keep the live Delete entry.
library;

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/widgets/sidebar_sessions_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

/// A hosted relay service: [liveSessionId] non-null flips the manager onto
/// hosted semantics — the sidebar's delete entry gates on it.
final class _HostedFakeService extends AgentService {
  _HostedFakeService({required super.env, required this.rows})
    : super(
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
        sessionsRoot: '/sessions',
        config: AgentConfig(
          providerKind: 'test',
          modelId: 'test-model',
          baseUrl: 'https://example.com',
          apiKey: '',
        ),
      );

  final List<SessionMetadata> rows;

  @override
  String? get liveSessionId => 'sw-live-1';

  @override
  Future<List<SessionMetadata>> listSessions() async => rows;
}

SessionMetadata _row(String id, String cwd) => SessionMetadata(
  id: id,
  createdAt: DateTime.utc(2026, DateTime.august, 20, 10),
  cwd: cwd,
  path: '/sessions/$id.jsonl',
);

void main() {
  setUpAll(ensureGoldenFonts);

  Future<void> pumpAndOpenMenu(
    WidgetTester tester, {
    required FlutterSessionManager manager,
    required List<SessionMetadata> rows,
  }) async {
    await pumpGolden(
      tester,
      SidebarSessionsList(
        manager: manager,
        persistedSessions: rows,
        sessionInfoNames: {
          for (final row in rows)
            row.id: row.id.startsWith('sw')
                ? 'goal_builder (host app)'
                : 'goal_builder',
        },
      ),
      size: goldenSizeTall,
      wrap: (child) => Scaffold(body: child),
    );
    await tester.tap(find.byIcon(Icons.more_horiz).first);
    await tester.pumpAndSettle();
  }

  testWidgets('local listing: the actions menu offers a live Delete entry', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');

    await pumpAndOpenMenu(
      tester,
      manager: manager,
      rows: [
        _row('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1', '/work/goal_builder'),
      ],
    );

    await expectGolden(tester, 'session_menu_delete_local');
  });

  testWidgets('hosted listing: delete is gated with the honest dead-end '
      'tile', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
    final hostedRow = SessionMetadata(
      id: 'sw-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1',
      createdAt: DateTime.utc(2026, DateTime.august, 20, 10),
      cwd: '/work/goal_builder',
      path: '/session-sw-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1.jsonl',
      metadata: const {'archived': true},
    );
    manager.addSession(
      'sw-live-1',
      _HostedFakeService(env: env, rows: [hostedRow]),
    );

    await pumpAndOpenMenu(tester, manager: manager, rows: [hostedRow]);

    await expectGolden(tester, 'session_menu_delete_hosted_gated');
  });
}

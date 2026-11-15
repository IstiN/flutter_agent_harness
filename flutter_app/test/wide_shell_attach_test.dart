// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/screens/attached_session_screen.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

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

/// AC5 of #2138: a live-lease open in the WIDE shell attaches — the
/// attached view opens (transcript follow + composer → owner mailbox),
/// a banner names the owner, and the session file gains zero bytes.
void main() {
  // 14:32 wall-clock: the seeded sidecar mtime is always live.
  final DateTime now = DateTime(2026, 9, 15, 14, 32);

  testWidgets(
    'a live-lease open attaches instead of a second writer; the composer '
    'mails the owner through the fabric',
    (tester) async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final store = FileSessionLeaseStore(env: env, now: () => now);
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final session = await repo.create(
        JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendSessionName('steered');
      final meta = await session.getMetadata();
      final bytesBefore = (await env.readTextFile(meta.path)).valueOrNull;

      // A live CLI lease on the session (heartbeat fresh, host cli).
      final sidecar = store.sidecarPath(meta.path);
      await env.writeFile(
        sidecar,
        const JsonEncoder.withIndent('  ').convert({
          'host': 'cli',
          'sessionId': meta.id,
          'pid': 4242,
          'bootId': 'owner-boot',
          'heartbeatAt': now.toUtc().toIso8601String(),
          'acquiredAt': now.toUtc().toIso8601String(),
        }),
      );
      env.setMtime(sidecar, now.millisecondsSinceEpoch);

      final manager =
          FlutterSessionManager(
              env: env,
              sessionsRoot: '/sessions',
              leaseStore: store,
            )
            ..addSession('active-session', _fakeService(env))
            ..switchTo('active-session');

      await tester.pumpWidget(
        MaterialApp(home: WideLayoutShell(manager: manager)),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      // The persisted (live-leased) row is in the sidebar — open it.
      await tester.scrollUntilVisible(
        find.text('steered').last,
        120,
        scrollable: find
            .descendant(
              of: find.byType(WideLayoutShell),
              matching: find.byType(Scrollable),
            )
            .last,
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text('steered').last);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));

      // The attached view opened (not a snack, not a drive-open).
      expect(find.byType(AttachedSessionScreen), findsOneWidget);

      // The banner names the owner (host + pid).
      expect(find.textContaining('fa CLI'), findsWidgets);
      expect(find.textContaining('4242'), findsWidgets);

      // The composer hands the message to the owner's mailbox — the
      // fabric inbox colocated with the session (root/slug from the
      // session path), attributed as the app viewer.
      await tester.enterText(find.byType(TextField).last, 'steer: run tests');
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump(const Duration(seconds: 1));

      final fabric = FileMessagingRepository(
        env: env,
        root: '/sessions/--work--/messages',
      );
      final mail = await fabric.peek('${meta.id}/main');
      expect(mail, hasLength(1));
      expect(mail.single.fromId, 'Fa.app user');
      expect(mail.single.kind, AgentMessageKind.user);
      expect(mail.single.text, 'steer: run tests');

      // Zero bytes to the session file: the app never became a writer.
      expect((await env.readTextFile(meta.path)).valueOrNull, bytesBefore);

      // Detach (pop) — the controller cancels its subscription and the
      // shell disposes the transport, ending the transcript poller.
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pump(const Duration(seconds: 3));
    },
  );
}

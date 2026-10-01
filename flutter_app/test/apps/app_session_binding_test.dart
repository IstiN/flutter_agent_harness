// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/agent_service.dart';
import 'package:fa/apps/js_app_navigation.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/services/flutter_session_manager.dart';
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

void main() {
  testWidgets('first app message creates + binds a session, next reuses it', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
    final original = _fakeService(env);
    manager.addSession('original-session', original);

    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await tester.pumpAndSettle();

    const message = FaAppMessage(text: 'make it purple', appId: 'notes');

    await forwardAppMessageToAgent(manager, message);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();

    // A binding file appeared and a NEW session became active.
    final binding = await env.readTextFile('apps/notes/session.json');
    expect(binding.valueOrNull, isNotNull);
    final boundId = manager.activeId;
    expect(boundId, isNot('original-session'));
    expect(binding.valueOrNull, contains(boundId));

    // Second message goes to the SAME bound session, not a new one.
    final sessionCount = manager.sessions.length;
    await forwardAppMessageToAgent(manager, message);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    expect(manager.sessions.length, sessionCount);
    expect(manager.activeId, boundId);

    // Shut down services so their idle watchdogs don't outlive the test.
    for (final session in manager.sessions) {
      session.service.dispose();
    }
  });

  testWidgets('a malformed binding never blocks the app from opening', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
    final original = _fakeService(env);
    manager.addSession('original-session', original);

    // A binding whose sessionId JSON value is NOT a string map (a torn or
    // agent-written file) used to throw out of resolveAppBoundSession and
    // silently dead the launcher tile (fitness-trainer on TestFlight).
    await env.writeFile('apps/fitness-trainer/session.json', '[1,2]');
    final resolved = await resolveAppBoundSession(manager, 'fitness-trainer');
    expect(resolved, isNull);

    // Valid-but-unknown session id also resolves to null (stale binding).
    await env.writeFile(
      'apps/fitness-trainer/session.json',
      '{"sessionId":"deleted-session"}',
    );
    expect(await resolveAppBoundSession(manager, 'fitness-trainer'), isNull);

    for (final session in manager.sessions) {
      session.service.dispose();
    }
  });

  testWidgets('a corrupt binding rebinds EXACTLY once — never per message '
      '(issue #864)', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
    manager.addSession('original-session', _fakeService(env));

    // Torn binding: the first message heals it with one rebind…
    await env.writeFile('apps/notes/session.json', '[1,2]');
    await forwardAppMessageToAgent(
      manager,
      const FaAppMessage(text: 'a', appId: 'notes'),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    final boundAfterHeal = manager.activeId;
    expect(boundAfterHeal, isNot('original-session'));

    // …and the next message reuses the healed binding: the session count
    // must never grow again (the old code could re-mint per message while
    // the binding stayed broken).
    final sessionsAfterHeal = manager.sessions.length;
    await forwardAppMessageToAgent(
      manager,
      const FaAppMessage(text: 'b', appId: 'notes'),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    expect(manager.sessions.length, sessionsAfterHeal);
    expect(manager.activeId, boundAfterHeal);

    for (final session in manager.sessions) {
      session.service.dispose();
    }
  });

  testWidgets('concurrent app messages mint ONE bound session '
      '(issue #864 E3)', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
    manager.addSession('original-session', _fakeService(env));

    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await tester.pumpAndSettle();

    // Two messages racing on first contact: the per-app single-flight
    // must collapse them into one mint.
    final results = await tester.runAsync(
      () => Future.wait([
        forwardAppMessageToAgent(
          manager,
          const FaAppMessage(text: 'a', appId: 'notes'),
        ),
        forwardAppMessageToAgent(
          manager,
          const FaAppMessage(text: 'b', appId: 'notes'),
        ),
      ]),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();

    expect(results, hasLength(2));
    expect(results![0], same(results[1])); // same bound service, one mint
    expect(manager.sessions.length, 2); // original + the one bound session
    final binding = await env.readTextFile('apps/notes/session.json');
    expect(binding.valueOrNull, contains(manager.activeId));

    for (final session in manager.sessions) {
      session.service.dispose();
    }
  });

  testWidgets('a real binding whose session cannot be opened never mints '
      '(issue #864)', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
    manager.addSession('original-session', _fakeService(env));

    // The sessions root is a FILE: every disk-open leg fails outright.
    // The binding below is REAL (it names a persisted session), so this
    // is NOT first contact — the resolver must refuse to mint and keep
    // the binding verbatim for a later repair.
    await env.writeFile('/sessions', 'not a directory');
    await env.writeFile(
      'apps/notes/session.json',
      '{"sessionId":"persisted-session"}',
    );

    final resolved = await tester.runAsync(
      () => resolveAppBoundSession(manager, 'notes'),
    );
    expect(resolved, isNull);
    expect(manager.sessions.length, 1); // no replacement minted

    final binding = await env.readTextFile('apps/notes/session.json');
    expect(binding.valueOrNull, contains('persisted-session'));
  });

  testWidgets('an unreadable binding is not treated as first contact '
      '(issue #864)', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
    manager.addSession('original-session', _fakeService(env));

    // The binding path is a DIRECTORY: the read fails with isDirectory —
    // a real read error, not absence. Minting would overwrite a binding
    // the app could not even read, so the resolver must refuse.
    await env.writeFile('apps/notes/session.json/x', 'forces a directory');
    final bindingBefore = await env.listDir('apps/notes');

    final resolved = await tester.runAsync(
      () => resolveAppBoundSession(manager, 'notes'),
    );
    expect(resolved, isNull);
    expect(manager.sessions.length, 1); // no mint over the unreadable file
    expect(
      (await env.listDir('apps/notes')).valueOrNull!.map((e) => e.name),
      (bindingBefore.valueOrNull ?? const []).map((e) => e.name),
    );
  });
}

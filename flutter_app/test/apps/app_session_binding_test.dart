// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';

import 'package:fa/services/agent_service.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/fa_work_bar.dart';
import 'package:fa/apps/js_app_navigation.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/app_log.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
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

/// A hung stream honoring aborts (the session_chat_sheet_test.dart
/// pattern): the provider stream stays open until aborted, so
/// `isStreaming` stays true.
StreamFunction _hungResponse() {
  fn(Model model, dynamic context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final partial = AssistantMessage(
      content: const [],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime(2026),
    );
    stream.push(StartEvent(partial: partial));
    cancelToken?.onCancel.then((_) {
      stream.push(
        ErrorEvent(
          reason: StopReason.aborted,
          error: partial.copyWith(
            stopReason: StopReason.aborted,
            errorMessage: 'Operation aborted',
          ),
        ),
      );
      stream.end();
    });
    return stream; // stays open until aborted
  }

  return fn;
}

AgentService _fakeService(ExecutionEnv env, [StreamFunction? streamFunction]) {
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
      streamFunction: streamFunction ?? _singleTextResponse('ok'),
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

  // The REAL FAB surface (js_app_view.dart:625): FAB tap → _FaMessageSheet
  // → _sendFaMessage → forwardAppMessageToAgent, wired exactly as
  // pushJsApp wires a production open (resolve-on-open for the view
  // chrome, forwardAppMessageToAgent behind onSendToAgent). The engine
  // start fails deterministically (manifest without widget.js — same
  // trick as js_app_chrome_test), so no native JS bridge is touched.
  group('FAB tap surface — one Fa, one session (issue #1175)', () {
    Future<void> pumpAppView(
      WidgetTester tester, {
      required MemoryExecutionEnv env,
      required FlutterSessionManager manager,
      required String appId,
    }) async {
      await env.writeFile('apps/$appId/manifest.json', '{}');
      final permissions = await AppPermissionsStore.load(env);
      final chrome = await resolveAppBoundSession(manager, appId);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFahTheme(),
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: JsAppView(
            app: JsAppInfo.fromManifest(
              {'id': appId, 'name': appId},
              bundled: false,
              fallbackId: appId,
            ),
            env: env,
            permissionsStore: permissions,
            agentService: chrome ?? manager.active?.service,
            onSendToAgent: (message) =>
                forwardAppMessageToAgent(manager, message),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    // The send path's screenshot capture times out (5 s real) in the test
    // environment before the forwarder runs — wait it out, then let the
    // scripted run finish (same pattern as fa_reply_sheet_test.dart).
    Future<void> sendViaFab(WidgetTester tester, String text) async {
      await tester.runAsync(() async {
        await tester.tap(find.byType(FloatingActionButton));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.enterText(find.byType(TextField).last, text);
        await tester.pump();
        await tester.tap(find.byType(FilledButton));
        for (var i = 0; i < 70; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await tester.pump();
        }
      });
      await tester.pump(const Duration(milliseconds: 250));
    }

    Future<void> dismissReplyIfShowing(WidgetTester tester) async {
      final close = find.byIcon(Icons.close);
      if (close.evaluate().isNotEmpty) {
        await tester.tap(close.first);
        await tester.pumpAndSettle();
      }
    }

    AgentService sessionService(FlutterSessionManager manager, String id) =>
        manager.sessions.firstWhere((session) => session.id == id).service;

    Future<String> bindingText(MemoryExecutionEnv env, String appId) async =>
        (await env.readTextFile('apps/$appId/session.json')).valueOrNull!;

    // Dispose registry: AgentService.dispose is NOT idempotent (it
    // disposes ValueNotifiers, which throw on a second call), and each
    // test disposes twice by design — body-end (cancels run timers
    // before flutter_test's pending-timer invariant) and the addTearDown
    // net (covers an expect failure mid-body). The set makes both layers
    // safe together.
    final disposed = <AgentService>{};
    void disposeAll(FlutterSessionManager manager) {
      for (final session in manager.sessions) {
        if (disposed.add(session.service)) {
          session.service.dispose();
        }
      }
    }

    testWidgets('FAB send with an app-bound session continues it — no mint, '
        'no binding rewrite (issue #1175 AC1)', (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
      );
      manager.addSession('original-session', _fakeService(env));
      addTearDown(
        () => disposeAll(manager),
      ); // failure-path net (dispose is idempotent)
      // Establish the bound session through the normal first contact.
      await forwardAppMessageToAgent(
        manager,
        const FaAppMessage(text: 'seed', appId: 'notes'),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      final boundId = manager.activeId!;
      final boundBefore = await bindingText(env, 'notes');
      final originalService = sessionService(manager, 'original-session');

      await pumpAppView(tester, env: env, manager: manager, appId: 'notes');
      await sendViaFab(tester, 'hello again');

      expect(manager.sessions.length, 2); // no mint on the tap
      expect(manager.activeId, boundId); // still the bound session
      expect(await bindingText(env, 'notes'), boundBefore); // binding untouched
      expect(
        sessionService(
          manager,
          boundId,
        ).messages.any((m) => m.content.contains('hello again')),
        isTrue,
      );
      expect(
        originalService.messages.any((m) => m.content.contains('hello again')),
        isFalse,
      );
      disposeAll(manager); // cancels run timers before the timer invariant
    });

    testWidgets('no binding: the first FAB send mints ONCE, the next reuses '
        'it (issue #1175 AC1 sticky mint)', (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
      );
      manager.addSession('original-session', _fakeService(env));
      addTearDown(
        () => disposeAll(manager),
      ); // failure-path net (dispose is idempotent)

      await pumpAppView(tester, env: env, manager: manager, appId: 'notes');
      await sendViaFab(tester, 'first');

      final boundId = manager.activeId!;
      expect(boundId, isNot('original-session'));
      expect(manager.sessions.length, 2); // exactly one mint
      final bound = await bindingText(env, 'notes');
      expect(bound, contains(boundId));

      await dismissReplyIfShowing(tester);
      await sendViaFab(tester, 'second');

      expect(manager.sessions.length, 2); // sticky: no second mint
      expect(manager.activeId, boundId);
      expect(await bindingText(env, 'notes'), bound); // binding not rewritten
      expect(
        sessionService(
          manager,
          boundId,
        ).messages.any((m) => m.content.contains('second')),
        isTrue,
      );
      disposeAll(manager); // cancels run timers before the timer invariant
    });

    testWidgets('a corrupt binding heals EXACTLY once through the FAB — the '
        'recovery is logged (issue #1175 AC2 + AC6)', (tester) async {
      AppLog.reset();
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
      );
      manager.addSession('original-session', _fakeService(env));
      addTearDown(
        () => disposeAll(manager),
      ); // failure-path net (dispose is idempotent)
      await env.writeFile('apps/notes/session.json', '[1,2]');

      await pumpAppView(tester, env: env, manager: manager, appId: 'notes');
      await sendViaFab(tester, 'heal me');

      final boundId = manager.activeId!;
      expect(boundId, isNot('original-session'));
      expect(manager.sessions.length, 2); // one recovery mint
      final healed = await bindingText(env, 'notes');
      expect(healed, contains(boundId)); // binding valid afterwards
      expect(AppLog.dump(), contains('binding unusable for notes'));

      await dismissReplyIfShowing(tester);
      await sendViaFab(tester, 'reuse');

      expect(manager.sessions.length, 2); // never per message
      expect(manager.activeId, boundId);
      expect(await bindingText(env, 'notes'), healed);
      disposeAll(manager); // cancels run timers before the timer invariant
    });

    testWidgets('a binding to a deleted session re-mints ONCE and rewrites '
        'the binding (issue #1175 E4)', (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
      );
      manager.addSession('original-session', _fakeService(env));
      addTearDown(
        () => disposeAll(manager),
      ); // failure-path net (dispose is idempotent)
      // The session the binding names is gone (user deleted it); the
      // binding file outlives it — exactly E4's disk state.
      await env.writeFile(
        'apps/notes/session.json',
        '{"sessionId":"deleted-session"}',
      );

      await pumpAppView(tester, env: env, manager: manager, appId: 'notes');
      await sendViaFab(tester, 'still here');

      final boundId = manager.activeId!;
      expect(boundId, isNot('original-session'));
      expect(boundId, isNot('deleted-session'));
      expect(manager.sessions.length, 2); // one re-mint
      final rebound = await bindingText(env, 'notes');
      expect(rebound, contains(boundId)); // binding rewritten to the new id

      await dismissReplyIfShowing(tester);
      await sendViaFab(tester, 'reuse');

      expect(manager.sessions.length, 2); // sticky afterwards
      expect(manager.activeId, boundId);
      expect(await bindingText(env, 'notes'), rebound);
      disposeAll(manager); // cancels run timers before the timer invariant
    });

    testWidgets('two apps keep their own bound sessions — no cross-binding '
        '(issue #1175 E5)', (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
      );
      manager.addSession('original-session', _fakeService(env));
      addTearDown(
        () => disposeAll(manager),
      ); // failure-path net (dispose is idempotent)
      await forwardAppMessageToAgent(
        manager,
        const FaAppMessage(text: 'seed', appId: 'notes'),
      );
      await forwardAppMessageToAgent(
        manager,
        const FaAppMessage(text: 'seed', appId: 'todo'),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      final notesId =
          (jsonDecode(await bindingText(env, 'notes'))
                  as Map<String, dynamic>)['sessionId']
              as String;
      final todoId =
          (jsonDecode(await bindingText(env, 'todo'))
                  as Map<String, dynamic>)['sessionId']
              as String;
      expect(notesId, isNot(todoId));
      expect(manager.sessions.length, 3); // original + two app sessions

      await pumpAppView(tester, env: env, manager: manager, appId: 'notes');
      await sendViaFab(tester, 'for notes');
      // Re-open as the launcher would: todo replaces notes on the stack.
      await pumpAppView(tester, env: env, manager: manager, appId: 'todo');
      await sendViaFab(tester, 'for todo');

      expect(manager.sessions.length, 3); // no mint on either continue
      expect(
        sessionService(
          manager,
          notesId,
        ).messages.any((m) => m.content.contains('for notes')),
        isTrue,
      );
      expect(
        sessionService(
          manager,
          notesId,
        ).messages.any((m) => m.content.contains('for todo')),
        isFalse,
      );
      expect(
        sessionService(
          manager,
          todoId,
        ).messages.any((m) => m.content.contains('for todo')),
        isTrue,
      );
      expect(await bindingText(env, 'notes'), contains(notesId));
      expect(await bindingText(env, 'todo'), contains(todoId));
      disposeAll(manager); // cancels run timers before the timer invariant
    });

    testWidgets('a real binding whose session cannot be opened never mints '
        'through the FAB — the message runs on the active session and the '
        'binding is preserved (issue #1175)', (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
      );
      manager.addSession('original-session', _fakeService(env));
      addTearDown(
        () => disposeAll(manager),
      ); // failure-path net (dispose is idempotent)
      // The sessions root is a FILE: the disk-open leg fails outright, so
      // the binding below is REAL but unopenable — NOT first contact. The
      // pre-rework resolver's catch-all routed exactly this state into a
      // replacement mint (plus a binding rewrite) on every message.
      await env.writeFile('/sessions', 'not a directory');
      await env.writeFile(
        'apps/notes/session.json',
        '{"sessionId":"persisted-session"}',
      );
      final originalService = sessionService(manager, 'original-session');

      await pumpAppView(tester, env: env, manager: manager, appId: 'notes');
      await sendViaFab(tester, 'talk to me');

      expect(manager.sessions.length, 1); // never a replacement mint
      expect(manager.activeId, 'original-session'); // ran on the active one
      expect(
        await bindingText(env, 'notes'),
        contains('persisted-session'),
      ); // binding preserved for a later repair
      expect(
        originalService.messages.any((m) => m.content.contains('talk to me')),
        isTrue,
      );
      disposeAll(manager); // cancels run timers before the timer invariant
    });

    testWidgets('a busy bound session: FAB send continues it — never mints '
        'to escape the busy one (issue #1175 E1)', (tester) async {
      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
      );
      manager.addSession('original-session', _fakeService(env));
      // The bound session's run HANGS mid-stream; the next FAB send must
      // steer into THAT run — never mint a fresh session to escape it.
      final busyService = _fakeService(env, _hungResponse());
      manager.addSession('busy-bound', busyService);
      addTearDown(() async {
        busyService.abort();
        disposeAll(manager);
      });
      await env.writeFile(
        'apps/notes/session.json',
        '{"sessionId":"busy-bound"}',
      );

      await pumpAppView(tester, env: env, manager: manager, appId: 'notes');
      await tester.runAsync(() async {
        unawaited(busyService.sendText('long task'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      expect(busyService.isStreaming, isTrue);

      await sendViaFab(tester, 'while you run');

      expect(manager.sessions.length, 2); // no escape mint
      expect(manager.activeId, 'busy-bound');
      // The steered element carries the full forward buffer (viewport +
      // theme lines appended) — its prefix is the user's text, and it
      // landing here at all proves the FAB message reached the BUSY
      // session instead of minting an escape hatch.
      expect(busyService.pendingSteerTexts.single, startsWith('while you run'));
      expect(find.byType(FaWorkBar), findsOneWidget); // the run stays shown
      busyService.abort(); // end the hung run…
      disposeAll(manager); // …and cancel timers before the invariant
    });
  });
}

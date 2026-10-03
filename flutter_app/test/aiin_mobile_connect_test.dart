// gh-1044: the iOS AIIN add-provider flow never completes — the
// `fah/web_auth_session` sheet was opened without the CodeMie contract.
//
// Coverage (the ticket's AC7/AC9/AC4/AC3/AC6 recipe): VM tests drive
// `runAiinMobileConnect` with an iOS platform override and a mocked
// `fah/web_auth_session` channel — the code's own step seam.
//
// - AC9: the session is invoked with `callbackScheme: 'http'`, the
//   redirect host is `localhost`, and the callback URL the channel
//   RETURNS is consumed — the flow settles without any loopback hit.
// - AC4: a sheet that settles without a callback surfaces a visible
//   error — never the paste sheet, never a silent exit (SSO is the only
//   path; the owner ruling).
// - AC3: a second Add tap while an attempt runs joins it — one
//   authenticate call, one loopback listener (the F3 leak).
// - AC6: while an add-provider flow is latched, restore-shaped
//   reconfigures are refused — the active connection is never hijacked
//   mid-flow (F4); the flow's own switch bypasses the latch.
library;

import 'dart:async';
import 'dart:convert' show jsonEncode;

import 'package:fa/services/aiin_connect_flow.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

/// Mock AIIN backend serving the OAuth exchange + key registration (the
/// same contract the aiin_connect_flow_steps suite runs against).
MockClient _mockBackend() => MockClient((request) async {
      final path = request.url.path;
      if (path == '/api/oauth-proxy/exchange') {
        return _json(const {
          'access_token': '[REDACTED:Sensitive Value]',
          'refresh_token': '[REDACTED:Sensitive Value]',
          'token_type': 'Bearer',
          'expires_in': 3600,
        });
      }
      if (path == '/v1/keys') {
        return _json({
          'id': 'key-1',
          'prefix': 'sk-aiin-abc12345',
          'key': 'sk-aiin-${'a' * 32}',
        }, 201);
      }
      return http.Response('not found', 404);
    });

Future<BuildContext> _pumpHost(WidgetTester tester) async {
  BuildContext? flowContext;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            flowContext = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return flowContext!;
}

/// The mocked `fah/web_auth_session` channel. [onAuthenticate] decides
/// the session's fate: completing [session] with a callback URL string is
/// the native interception path, with `null` the sheet-settles-without-
/// callback cancel; leaving it pending holds the sheet open (settle it
/// later through [pending]). `cancel` completes the pending session with
/// null (the real sheet's canceledLogin path).
({
  List<Map<Object?, Object?>> argsSeen,
  Completer<Object?>? Function() pending,
}) mockAuthSessionChannel(
  void Function(String url, Map<Object?, Object?> args,
          Completer<Object?> session)
      onAuthenticate,
) {
  final argsSeen = <Map<Object?, Object?>>[];
  Completer<Object?>? session;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('fah/web_auth_session'), (
    call,
  ) async {
    if (call.method == 'authenticate') {
      final args = call.arguments as Map<Object?, Object?>;
      argsSeen.add(args);
      session = Completer<Object?>();
      onAuthenticate(args['url'] as String, args, session!);
      return session!.future;
    }
    if (call.method == 'cancel') {
      if (session != null && !session!.isCompleted) session!.complete(null);
      return null;
    }
    return null;
  });
  return (
    argsSeen: argsSeen,
    pending: () => session,
  );
}

void main() {
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    // No KeychainStore channel in the test VM: report "no secure store"
    // so the flow falls back to the session keys store.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('fah/keychain'), (
      call,
    ) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('fah/web_auth_session'),
            null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('fah/keychain'), null);
    debugDefaultTargetPlatformOverride = null;
    // The single-flight guard is module state; a test that abandoned a
    // flow must not poison the next one.
    resetAiinConnectFlightForTests();
  });

  testWidgets('AC9: the sheet is invoked with the CodeMie contract and the '
      'returned callback URL completes the flow without a loopback hit',
      (tester) async {
    final harness = mockAuthSessionChannel((url, args, session) {
      // The native interception: the sheet completes with the callback
      // URL — code + our state. NO server socket is ever touched; if the
      // flow still required a loopback hit, it would hang here.
      final login = Uri.parse(url);
      final redirect = Uri.parse(login.queryParameters['client_redirect_uri']!);
      session.complete(
        redirect
            .replace(
              queryParameters: {
                'code': 'c-1044',
                'state': login.queryParameters['state']!,
              },
            )
            .toString(),
      );
    });
    final registry = ProviderRegistry.inMemory();
    final context = await _pumpHost(tester);

    var modelsFetched = false;
    Object? flowError;
    await tester.runAsync(() async {
      unawaited(
        runAiinMobileConnect(
          context: context,
          registry: registry,
          service: null,
          lastConnectionStore: LastConnectionStore.inMemory(),
          aiinHttpClient: _mockBackend(),
          aiinModelsFetcher: (baseUrl, {required apiKey}) async {
            modelsFetched = true;
            return ['moonshotai/kimi-k2'];
          },
        ).then(
          (_) {},
          onError: (Object e, StackTrace s) {
            flowError = e;
          },
        ),
      );
      for (var i = 0; i < 100 && harness.argsSeen.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });

    // The CodeMie contract on the wire: the callback scheme is passed and
    // the redirect URI advertises the localhost host.
    expect(harness.argsSeen, hasLength(1));
    expect(harness.argsSeen.single['callbackScheme'], 'http');
    final login = Uri.parse(harness.argsSeen.single['url'] as String);
    expect(login.host, 'auth.aiin.by');
    final redirect = Uri.parse(login.queryParameters['client_redirect_uri']!);
    expect(redirect.host, 'localhost');

    // The intercepted URL settled the flow — the exchange ran off the
    // mocked backend and the model picker opened with the fetched list.
    // The flow's tail settles behind the loopback server's REAL socket
    // teardown (`runAiinConnectCliFlow`'s `finally { await server.close() }`)
    // — a real-I/O event the fake-async pumps never process, so spin the
    // real event loop until the tail's models fetch lands, then build the
    // pushed page.
    await tester.runAsync(() async {
      for (var i = 0; i < 200 && !modelsFetched; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    });
    // The route builds on the second frame (the entrance transition
    // anchors to the fake clock once the pumps advance), so pump with
    // durations until the picker page is up.
    for (var i = 0;
        i < 30 && find.text('AIIN model').evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    expect(modelsFetched, isTrue,
        reason: 'the intercepted callback must settle the exchange');
    expect(flowError, isNull, reason: 'flow error: $flowError');
    expect(find.text('AIIN model'), findsOneWidget);
    // Not yet picked — the provider row lands only after the pick.
    expect(registry.providers, isEmpty);
    await tester.pump(const Duration(seconds: 5)); // expire status snacks
    // Restore before postTest: flutter_test's foundation-var check runs
    // when the BODY completes — before the package-level tearDown.
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('AC4: a sheet that settles without a callback surfaces a '
      'visible error — never the paste sheet', (tester) async {
    // The sheet closed without returning a callback URL (a swipe, or an
    // interception that never fired): a user cancel.
    mockAuthSessionChannel((url, args, session) => session.complete(null));
    final registry = ProviderRegistry.inMemory();
    final context = await _pumpHost(tester);

    Future<bool>? done;
    await tester.runAsync(() async {
      done = runAiinMobileConnect(
        context: context,
        registry: registry,
        service: null,
        lastConnectionStore: LastConnectionStore.inMemory(),
      );
      // Let the loopback bind + the sheet settle.
      for (var i = 0; i < 100 && done == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await done;
    });
    await tester.pump(); // one frame for the error snack

    // SSO is the only path: a visible, actionable failure — and NO
    // key-paste sheet (the owner ruling).
    expect(find.textContaining('AIIN sign-in did not complete'), findsOneWidget);
    expect(find.text('AIIN API key'), findsNothing);
    expect(registry.providers, isEmpty);
    await tester.pump(const Duration(seconds: 8)); // expire the snacks
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('AC3: a second Add tap while a flow runs joins it — one '
      'authenticate call, one live listener', (tester) async {
    // The sheet stays OPEN until the test settles it (the swipe below):
    // tap 2 must arrive while tap 1's flow is still in flight.
    final harness = mockAuthSessionChannel((url, args, session) {});
    final registry = ProviderRegistry.inMemory();
    final context = await _pumpHost(tester);

    final results = <String, bool>{};
    Future<bool> tap() => runAiinConnectFlow(
          context: context,
          registry: registry,
          service: null,
          lastConnectionStore: LastConnectionStore.inMemory(),
          aiinModelsFetcher: (baseUrl, {required apiKey}) async => const [],
        );

    await tester.runAsync(() async {
      unawaited(
        tap().then(
          (value) => results['first'] = value,
          onError: (Object _) => results['first'] = false,
        ),
      );
      for (var i = 0; i < 100 && harness.argsSeen.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    expect(harness.argsSeen, hasLength(1));

    // The retry while the first attempt is still live: joins it.
    final second = tap();
    expect(harness.argsSeen, hasLength(1),
        reason: 'the retry must reuse the running attempt');

    // The user swipes the sheet away — the only in-flight flow settles.
    // Both waits ride REAL async: the joined flow's tail settles behind
    // the loopback server's real socket teardown, which the fake-async
    // zone never processes.
    await tester.runAsync(() async {
      final session = harness.pending();
      if (session != null && !session.isCompleted) session.complete(null);
      results['second'] = await second;
      for (var i = 0; i < 100 && !results.containsKey('first'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    expect(results['second'], isFalse);
    expect(results['first'], isFalse);
    expect(harness.argsSeen, hasLength(1));
    await tester.pump(); // one frame for the error snack
    expect(find.textContaining('AIIN sign-in did not complete'), findsOneWidget);
    await tester.pump(const Duration(seconds: 8)); // expire the snacks
    debugDefaultTargetPlatformOverride = null;
  });

  test('AC6: while an add flow is latched, restore-shaped reconfigures are '
      'refused and the flow\'s own switch bypasses the latch', () async {
    final codemieConfig = AgentConfig(
      providerKind: 'openai-completions',
      modelId: 'codemie-model',
      baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
      apiKey: '[REDACTED:Sensitive Value]',
    );
    final aiinConfig = AgentConfig(
      providerKind: 'aiin',
      modelId: 'moonshotai/kimi-k2',
      baseUrl: aiinDefaultChatBaseUrl,
      apiKey: '[REDACTED:Sensitive Value]',
    );
    final service = AgentService(
      agent: Agent(
        model: codemieConfig.toModel(),
        systemPrompt: 'You are Fa.',
        streamFunction: _singleTextResponse(),
        toolRegistry: ToolRegistry(const []),
      ),
      env: MemoryExecutionEnv(),
      sessionsRoot: '/sessions',
      config: codemieConfig,
    );
    expect(service.activeBaseUrl, codemieConfig.baseUrl);

    service.beginProviderAddFlow();
    try {
      // A restore-shaped reconfigure mid-flow: refused, connection
      // untouched (the F4 hijack must be impossible).
      await service.reconfigure(
        codemieConfig.withModelId('restored-model'),
      );
      expect(service.agentModelId, 'codemie-model');
      expect(service.activeBaseUrl, codemieConfig.baseUrl);

      // The flow's own switch goes through.
      await service.reconfigure(aiinConfig, fromProviderAddFlow: true);
      expect(service.agentModelId, 'moonshotai/kimi-k2');
      expect(service.activeBaseUrl, aiinDefaultChatBaseUrl);
    } finally {
      service.endProviderAddFlow();
    }

    // After the flow ends, normal reconfigures work again.
    await service.reconfigure(codemieConfig.withModelId('restored-model'));
    expect(service.agentModelId, 'restored-model');
  });
}

StreamFunction _singleTextResponse() {
  return (model, context, {cancelToken}) {
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
  };
}

// CodeMie SSO per-surface steps (issue #476): the extracted hops of
// codemie_sso_flow.dart — desktop hint, iOS auth session, extension cookie
// branch, model-pick contract, and the shared credential assembly — each
// unit-tested with injected fakes; no real network.
import 'dart:async';
import 'dart:convert';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/codemie_sso_flow.dart';
import 'package:fa/services/codemie_sso_flow_steps.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

const _testModel = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test',
  baseUrl: 'https://example.com',
  contextWindow: 100000,
  maxTokens: 4096,
);

AssistantMessageEventStream _noopStream(
  Model model,
  Context context, {
  CancelToken? cancelToken,
}) => AssistantMessageEventStream();

/// A service recording [reconfigure] calls (nothing else is exercised).
final class _RecordingService extends AgentService {
  _RecordingService(ExecutionEnv env)
    : super(
        agent: Agent(
          model: _testModel,
          systemPrompt: 'You are Fa.',
          streamFunction: _noopStream,
          toolRegistry: ToolRegistry(const []),
        ),
        env: env,
        sessionsRoot: '/sessions',
      );

  AgentConfig? reconfigured;

  @override
  Future<void> reconfigure(AgentConfig config) async {
    reconfigured = config;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('codeMieHostFromUrl', () {
    test('bare https org URL → host (default port hidden)', () {
      expect(
        codeMieHostFromUrl('https://codemie.lab.epam.com'),
        'codemie.lab.epam.com',
      );
    });

    test('non-default port kept with the host', () {
      expect(
        codeMieHostFromUrl('https://codemie.local:8443'),
        'codemie.local:8443',
      );
    });

    test('http default port 80 hidden', () {
      expect(codeMieHostFromUrl('http://codemie.local'), 'codemie.local');
    });

    test('garbage URL falls back to the generic name', () {
      expect(codeMieHostFromUrl('not a url'), 'codemie');
    });
  });

  group('nonEmptyCodeMieId — an empty pick means cancel', () {
    test('null and empty collapse to null', () {
      expect(nonEmptyCodeMieId(null), isNull);
      expect(nonEmptyCodeMieId(''), isNull);
    });

    test('a real id survives', () {
      expect(nonEmptyCodeMieId('m1'), 'm1');
    });
  });

  group('resolveCodeMieModelId — the reauth model contract', () {
    Future<String?> resolve({
      List<String> models = const ['m1', 'm2'],
      String? current,
      required String? Function(
        List<String>, {
        String? preselected,
        bool allowCancel,
      })
      fake,
    }) => resolveCodeMieModelId(
      models: models,
      current: current,
      pick: (models, {preselected, allowCancel = false}) async =>
          fake(models, preselected: preselected, allowCancel: allowCancel),
    );

    test(
      'fresh login passes no preselection and no cancel affordance',
      () async {
        List<String>? seenModels;
        String? seenPreselected;
        bool? seenAllowCancel;
        final picked = await resolve(
          fake: (models, {preselected, allowCancel = false}) {
            seenModels = models;
            seenPreselected = preselected;
            seenAllowCancel = allowCancel;
            return 'm1';
          },
        );
        expect(seenModels, ['m1', 'm2']);
        expect(seenPreselected, isNull);
        expect(seenAllowCancel, isFalse);
        expect(picked, 'm1');
      },
    );

    test('fresh login: empty pick aborts the flow', () async {
      expect(
        await resolve(fake: (_, {preselected, allowCancel = false}) => ''),
        isNull,
      );
      expect(
        await resolve(fake: (_, {preselected, allowCancel = false}) => null),
        isNull,
      );
    });

    test(
      're-login: the keep-or-switch picker is cancellable and preselected',
      () async {
        String? seenPreselected;
        bool? seenAllowCancel;
        final switched = await resolve(
          current: 'cur',
          fake: (models, {preselected, allowCancel = false}) {
            seenPreselected = preselected;
            seenAllowCancel = allowCancel;
            return 'new';
          },
        );
        expect(seenPreselected, 'cur');
        expect(seenAllowCancel, isTrue);
        expect(switched, 'new');
      },
    );

    test(
      're-login: dismissing or emptying the picker keeps the current model',
      () async {
        expect(
          await resolve(
            current: 'cur',
            fake: (_, {preselected, allowCancel = false}) => null,
          ),
          'cur',
        );
        expect(
          await resolve(
            current: 'cur',
            fake: (_, {preselected, allowCancel = false}) => '',
          ),
          'cur',
        );
      },
    );
  });

  group('decodeCodeMieSsoCredentials — the credential-assembly golden', () {
    test('full cookie jar + resolved API base + expiry', () {
      final token = base64Encode(
        utf8.encode(
          jsonEncode({
            'cookies': {'codemie_access_token': 'aaa.bbb.ccc'},
          }),
        ),
      );
      final credentials = decodeCodeMieSsoCredentials(
        token,
        'https://codemie.lab.epam.com',
      );

      expect(credentials.cookies, {'codemie_access_token': 'aaa.bbb.ccc'});
      // The CodeMie API expects the COMPLETE cookie jar, not a bearer JWT.
      expect(credentials.authToken, 'codemie_access_token=aaa.bbb.ccc');
      expect(
        credentials.apiUrl,
        'https://codemie.lab.epam.com/code-assistant-api',
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      expect(credentials.expiresAt, greaterThan(now));
      expect(
        credentials.expiresAt,
        lessThan(now + const Duration(hours: 25).inMilliseconds),
      );
    });

    test('malformed token throws (never a silent empty session)', () {
      expect(
        () => decodeCodeMieSsoCredentials(
          '!!!not-base64!!!',
          'https://codemie.lab.epam.com',
        ),
        throwsFormatException,
      );
    });
  });

  group('saveCodemieConnection — provider + key + connect assembly', () {
    test(
      'fresh connect: adds a provider named after the org host, remembers the cookie',
      () async {
        final env = MemoryExecutionEnv();
        final registry = await ProviderRegistry.load(env);
        final store = LastConnectionStore.inMemory();
        final service = _RecordingService(env);

        await saveCodemieConnection(
          registry: registry,
          service: service,
          lastConnectionStore: store,
          orgUrl: 'https://codemie.lab.epam.com',
          baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
          modelId: 'gpt-x',
          key: 'codemie_access_token=tok-1',
        );

        final provider = registry.providers.single;
        expect(provider.name, 'codemie.lab.epam.com');
        expect(
          provider.baseUrl,
          'https://codemie.lab.epam.com/code-assistant-api/v1',
        );
        expect(provider.modelId, 'gpt-x');
        expect(registry.keyFor(provider.id), 'codemie_access_token=tok-1');

        expect(service.reconfigured, isNotNull);
        expect(service.reconfigured!.providerKind, 'openai-completions');
        expect(service.reconfigured!.modelId, 'gpt-x');
        expect(service.reconfigured!.apiKey, 'codemie_access_token=tok-1');

        expect(store.connection, isNotNull);
        expect(store.connection!.modelId, 'gpt-x');
      },
    );

    test(
      're-login keeps the existing provider id and name, updates model + key',
      () async {
        final env = MemoryExecutionEnv();
        final registry = await ProviderRegistry.load(env);
        final existing = await registry.add(
          name: 'Custom name',
          baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
          modelId: 'old-model',
        );
        registry.rememberKey(existing.id, 'stale');

        await saveCodemieConnection(
          registry: registry,
          service: null,
          lastConnectionStore: LastConnectionStore.inMemory(),
          orgUrl: 'https://codemie.lab.epam.com',
          baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
          modelId: 'gpt-x',
          key: 'codemie_access_token=tok-2',
          existing: existing,
        );

        expect(registry.providers, hasLength(1));
        expect(registry.providers.single.id, existing.id);
        expect(registry.providers.single.name, 'Custom name');
        expect(registry.providers.single.modelId, 'gpt-x');
        expect(registry.keyFor(existing.id), 'codemie_access_token=tok-2');
      },
    );

    test(
      'keyless extension contract: the remembered key stays EMPTY',
      () async {
        final env = MemoryExecutionEnv();
        final registry = await ProviderRegistry.load(env);
        final service = _RecordingService(env);

        await saveCodemieConnection(
          registry: registry,
          service: service,
          lastConnectionStore: LastConnectionStore.inMemory(),
          orgUrl: 'https://codemie.lab.epam.com',
          baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
          modelId: 'm1',
          key: '',
        );

        final provider = registry.providers.single;
        // An EMPTY remembered key means "no key needed": the entry is
        // forgotten from the session-key store and the requiresKey marker
        // flips off (the #327 keyless contract) — cookie-jar auth, not a
        // missing bearer key.
        expect(registry.keyFor(provider.id), isNull);
        expect(provider.requiresKey, isFalse);
        expect(service.reconfigured!.apiKey, '');
      },
    );

    test(
      'first-run onboarding (null service) still persists the last connection',
      () async {
        final env = MemoryExecutionEnv();
        final registry = await ProviderRegistry.load(env);
        final store = LastConnectionStore.inMemory();

        await saveCodemieConnection(
          registry: registry,
          service: null,
          lastConnectionStore: store,
          orgUrl: 'https://codemie.local:8443',
          baseUrl: 'https://codemie.local:8443/code-assistant-api/v1',
          modelId: 'm1',
          key: 'c=1',
        );

        expect(registry.providers.single.name, 'codemie.local:8443');
        expect(
          store.connection!.baseUrl,
          'https://codemie.local:8443/code-assistant-api/v1',
        );
      },
    );

    test(
      'the session cookie never lands in logs or the persisted record',
      () async {
        final env = MemoryExecutionEnv();
        final registry = await ProviderRegistry.load(env);
        final store = LastConnectionStore.inMemory();
        final logs = <String>[];
        final originalDebugPrint = debugPrint;
        debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
        addTearDown(() => debugPrint = originalDebugPrint);

        await saveCodemieConnection(
          registry: registry,
          service: _RecordingService(env),
          lastConnectionStore: store,
          orgUrl: 'https://codemie.lab.epam.com',
          baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
          modelId: 'gpt-x',
          key: 'codemie_access_token=SECRET-VALUE',
        );

        expect(logs.join('\n'), isNot(contains('SECRET-VALUE')));
        // LastConnection drops the API key by design — the persisted record
        // must not carry the secret either.
        expect(
          jsonEncode(store.connection!.toJson()),
          isNot(contains('SECRET-VALUE')),
        );
      },
    );
  });

  group('lenient fetches — network errors degrade to empty, never crash', () {
    test('projects: unusable api base → empty list without network', () async {
      expect(await fetchCodeMieProjectsLenient('', ''), isEmpty);
    });

    test('models: unusable api base → empty list without network', () async {
      expect(await fetchCodeMieModelsLenient('', ''), isEmpty);
    });
  });

  group('systemAuthSessionCodeMieSso — the fah/web_auth_session channel', () {
    const channel = MethodChannel('fah/web_auth_session');

    void mockChannel(Future<Object?> Function(MethodCall) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
    }

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      'user dismisses the sheet → no credentials, session was available',
      () async {
        mockChannel((call) async => null); // authenticate → cancelled
        final session = await systemAuthSessionCodeMieSso(
          'https://codemie.lab.epam.com',
        );
        expect(session.sessionUnavailable, isFalse);
        expect(session.credentials, isNull);
      },
    );

    test(
      'channel error (session could not start) → sessionUnavailable fallback flag',
      () async {
        mockChannel((call) async {
          if (call.method == 'authenticate') {
            throw PlatformException(code: 'unavailable');
          }
          return null;
        });
        final session = await systemAuthSessionCodeMieSso(
          'https://codemie.lab.epam.com',
        );
        expect(session.sessionUnavailable, isTrue);
        expect(session.credentials, isNull);
      },
    );
  });

  group('showCodeMieBrowserHint — the desktop snackbar is cosmetic', () {
    testWidgets('shows the opening-browser hint inside a Scaffold', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => showCodeMieBrowserHint(context),
                );
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Opening browser for CodeMie sign-in…'), findsOneWidget);
    });

    testWidgets('a Scaffold-less context must not crash the flow', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => showCodeMieBrowserHint(context),
              );
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('extensionCookieCodeMieSignin — the keyless web branch', () {
    Future<void> pumpBranch(
      WidgetTester tester, {
      required ProviderRegistry registry,
      AgentService? service,
      LastConnectionStore? store,
      required Future<List<String>?> Function({
        required String orgUrl,
        required bool Function() cancelled,
      })
      poll,
      CodeMieModelPick? pick,
      void Function(bool ok)? onDone,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  extensionCookieCodeMieSignin(
                    context: context,
                    registry: registry,
                    service: service,
                    lastConnectionStore:
                        store ?? LastConnectionStore.inMemory(),
                    orgUrl: 'https://codemie.lab.epam.com',
                    pollSession: poll,
                    pickModel: pick,
                  ).then((ok) => onDone?.call(ok));
                });
                return const SizedBox();
              },
            ),
          ),
        ),
      );
    }

    testWidgets('poll lands → confirmed pick → keyless save + connect', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final registry = await ProviderRegistry.load(env);
      final service = _RecordingService(env);
      var completed = false;
      bool? cancelledDuringPoll;

      await pumpBranch(
        tester,
        registry: registry,
        service: service,
        poll: ({required orgUrl, required cancelled}) async {
          cancelledDuringPoll = cancelled();
          return const ['m1', 'm2'];
        },
        pick: (models, {preselected, allowCancel = false}) async {
          expect(models, ['m1', 'm2']);
          // The extension branch always REQUIRES a confirmed pick.
          expect(allowCancel, isFalse);
          expect(preselected, isNull);
          return 'm1';
        },
        onDone: (ok) => completed = ok,
      );
      await tester.pumpAndSettle();

      expect(cancelledDuringPoll, isFalse);
      expect(completed, isTrue);
      final provider = registry.providers.single;
      expect(provider.modelId, 'm1');
      // The bearer key never exists on this surface: no remembered key and
      // the requiresKey marker flipped off (the #327 keyless contract).
      expect(registry.keyFor(provider.id), isNull);
      expect(provider.requiresKey, isFalse);
      expect(service.reconfigured!.apiKey, '');
    });

    testWidgets(
      'the wait dialog Cancel flips the flag the poll sees; no session → snackbar',
      (tester) async {
        final env = MemoryExecutionEnv();
        final registry = await ProviderRegistry.load(env);
        var completed = false;
        final pollGate = Completer<void>();

        await pumpBranch(
          tester,
          registry: registry,
          poll: ({required orgUrl, required cancelled}) async {
            await pollGate.future;
            return null; // the wait window closed with no live session
          },
          onDone: (ok) => completed = ok,
        );
        await tester.pump();
        expect(find.text('CodeMie cookie sign-in'), findsOneWidget);

        await tester.tap(find.text('Cancel'));
        pollGate.complete();
        await tester.pumpAndSettle();

        expect(completed, isFalse);
        // No provider may exist after a failed sign-in.
        expect(registry.providers, isEmpty);
      },
    );

    testWidgets('empty pick aborts without saving anything', (tester) async {
      final env = MemoryExecutionEnv();
      final registry = await ProviderRegistry.load(env);
      var completed = false;

      await pumpBranch(
        tester,
        registry: registry,
        poll: ({required orgUrl, required cancelled}) async => const ['m1'],
        pick: (models, {preselected, allowCancel = false}) async => '',
        onDone: (ok) => completed = ok,
      );
      await tester.pumpAndSettle();

      expect(completed, isFalse);
      expect(registry.providers, isEmpty);
    });
  });
  CodeMieSsoCredentials _credentials() => CodeMieSsoCredentials(
    cookies: {'codemie_access_token': 'aaa.bbb.ccc'},
    apiUrl: 'https://codemie.lab.epam.com/code-assistant-api',
    expiresAt: DateTime.now()
        .add(const Duration(hours: 20))
        .millisecondsSinceEpoch,
  );

  group('runCodemieSsoFlow — the sequencer over injected hops', () {
    // Pumps the harness (awaited) and wires the flow outcome into [done].
    Future<void> pumpFlow({
      required WidgetTester tester,
      required Completer<bool> done,
      required ProviderRegistry registry,
      AgentService? service,
      LastConnectionStore? store,
      Future<CodeMieSsoCredentials?> Function(BuildContext, String)?
      authenticate,
      List<String> projects = const [],
      List<String> models = const ['m1'],
    }) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  unawaited(
                    runCodemieSsoFlow(
                      context: context,
                      registry: registry,
                      service: service,
                      lastConnectionStore:
                          store ?? LastConnectionStore.inMemory(),
                      orgUrl: 'https://codemie.lab.epam.com',
                      authenticate: authenticate,
                      fetchProjects: (_, __) async => projects,
                      fetchModels: (_, __) async => models,
                    ).then(done.complete),
                  );
                });
                return const SizedBox();
              },
            ),
          ),
        ),
      );
    }

    testWidgets('happy path: SSO → skip empty projects → pick → save', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final registry = await ProviderRegistry.load(env);
      final service = _RecordingService(env);
      final store = LastConnectionStore.inMemory();
      final done = Completer<bool>();

      await pumpFlow(
        tester: tester,
        done: done,
        registry: registry,
        service: service,
        store: store,
        authenticate: (_, __) async => _credentials(),
      );
      await tester.pumpAndSettle();

      // The model picker is up (fresh login, no preselection).
      await tester.enterText(find.byType(TextField), 'gpt-x');
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();

      expect(await done.future, isTrue);
      expect(registry.providers.single.modelId, 'gpt-x');
      expect(service.reconfigured!.modelId, 'gpt-x');
      expect(store.connection!.modelId, 'gpt-x');
    });

    testWidgets('cancel at step 1 aborts without saving', (tester) async {
      final env = MemoryExecutionEnv();
      final registry = await ProviderRegistry.load(env);
      final done = Completer<bool>();

      await pumpFlow(
        tester: tester,
        done: done,
        registry: registry,
        authenticate: (_, __) async => null,
      );
      await tester.pumpAndSettle();

      expect(await done.future, isFalse);
      expect(registry.providers, isEmpty);
    });

    testWidgets('an empty model pick aborts after a successful SSO', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      final registry = await ProviderRegistry.load(env);
      final done = Completer<bool>();

      await pumpFlow(
        tester: tester,
        done: done,
        registry: registry,
        authenticate: (_, __) async => _credentials(),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();

      expect(await done.future, isFalse);
      expect(registry.providers, isEmpty);
    });
  });
}

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
import 'package:fa_ui/fa_ui.dart' show FaChatMessage;
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

  /// Test seam for issue #586: fires the service's listeners — the
  /// incoming-LLM-message event the transcript rebuilds on.
  void fireLlmMessageEvent() => notifyListeners();

  @override
  Future<void> reconfigure(AgentConfig config) async {
    reconfigured = config;
  }
}

/// Issue #586 harness: stands in for the transcript's owning surface. The
/// SSO flow starts from a Builder INSIDE the transcript subtree (the
/// auth-expired card's Authorize tap); an incoming LLM message event
/// rebuilds the list and UNMOUNTS that subtree — the flow's context dies
/// mid-flight, exactly the churn the owner reports ("last message
/// jumping") while the re-auth is in progress.
class _TranscriptHost extends StatefulWidget {
  const _TranscriptHost({
    required this.done,
    required this.registry,
    required this.service,
    required this.store,
    required this.authenticate,
    required this.fetchProjects,
    required this.models,
  });

  final Completer<bool> done;
  final ProviderRegistry registry;
  final _RecordingService service;

  final LastConnectionStore store;
  final Future<CodeMieSsoCredentials?> Function(BuildContext, String)
  authenticate;
  final Future<List<String>> Function(String, String) fetchProjects;
  final List<String> models;

  @override
  State<_TranscriptHost> createState() => _TranscriptHostState();
}

class _TranscriptHostState extends State<_TranscriptHost> {
  var _transcriptMounted = true;

  void _onLlmMessageEvent() {
    if (!mounted) return;
    // The rebuild replaces the transcript subtree — the context the flow
    // started from is disposed.
    setState(() => _transcriptMounted = false);
  }

  @override
  void initState() {
    super.initState();
    // The incoming-LLM-message event rebuilds (and here replaces) the
    // transcript subtree.
    widget.service.addListener(_onLlmMessageEvent);
  }

  @override
  void dispose() {
    widget.service.removeListener(_onLlmMessageEvent);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _transcriptMounted
          ? Builder(
              builder: (context) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  unawaited(
                    runCodemieSsoFlow(
                      context: context,
                      registry: widget.registry,
                      service: widget.service,
                      lastConnectionStore: widget.store,
                      orgUrl: 'https://codemie.lab.epam.com',
                      authenticate: widget.authenticate,
                      fetchProjects: (_, __) => widget.fetchProjects('', ''),
                      fetchModels: (_, __) async => widget.models,
                    ).then(widget.done.complete),
                  );
                });
                return const SizedBox();
              },
            )
          : const SizedBox(),
    );
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

    test(
      'issue #623: a successful connect resolves the auth-expired cards '
      'in the transcript',
      () async {
        final env = MemoryExecutionEnv();
        final registry = await ProviderRegistry.load(env);
        final service = _RecordingService(env);
        // The transcript state the card's Authorize tap runs from: a user
        // turn, the failed run's auth-expired card, TWO of them across a
        // double expiry (a single-card test can hide a multi-card miss),
        // and a live assistant reply after the newest card.
        service.messages.addAll([
          FaChatMessage(role: 'user', content: 'summarize the doc'),
          FaChatMessage(
            role: 'tool',
            toolName: 'error',
            isError: true,
            content: 'older expiry — [[auth-expired:codemie]]',
          ),
          FaChatMessage(role: 'assistant', content: 'partial answer'),
          FaChatMessage(
            role: 'tool',
            toolName: 'error',
            isError: true,
            content: 'CodeMie session expired — the endpoint answered the '
                'API call with the SSO login page. [[auth-expired:codemie]]',
          ),
        ]);

        await saveCodemieConnection(
          registry: registry,
          service: service,
          lastConnectionStore: LastConnectionStore.inMemory(),
          orgUrl: 'https://codemie.lab.epam.com',
          baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
          modelId: 'gpt-x',
          key: 'codemie_access_token=tok-1',
        );

        // No auth-expired card survives the successful sign-in.
        expect(
          service.messages.where(
            (m) => authExpiredProvider(m.content) != null,
          ),
          isEmpty,
        );
        // ONE system note replaces the cards…
        final notes = service.messages
            .where(
              (m) =>
                  m.role == 'system' &&
                  m.content.contains('Authorization successful'),
            )
            .toList();
        expect(notes, hasLength(1));
        // …sitting where the NEWEST card was (right after the live reply,
        // which shifts up once the older card is dropped).
        expect(service.messages.indexOf(notes.single), 2);
        // The surrounding transcript keeps its shape.
        expect(service.messages[0].role, 'user');
        expect(service.messages[1].role, 'assistant');
      },
    );

    test(
      'issue #623: a connect with no auth-expired cards in the transcript '
      'appends nothing',
      () async {
        final env = MemoryExecutionEnv();
        final registry = await ProviderRegistry.load(env);
        final service = _RecordingService(env);
        service.messages.addAll([
          FaChatMessage(role: 'user', content: 'hello'),
          FaChatMessage(role: 'assistant', content: 'hi!'),
        ]);

        await saveCodemieConnection(
          registry: registry,
          service: service,
          lastConnectionStore: LastConnectionStore.inMemory(),
          orgUrl: 'https://codemie.lab.epam.com',
          baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
          modelId: 'gpt-x',
          key: 'codemie_access_token=tok-1',
        );

        // Settings re-logins and first connects must not spam a note.
        expect(service.messages, hasLength(2));
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

  /// Issue #586: the re-auth runs AFTER the access cookie expired — the
  /// minted token the flow carries is already (or about-to-be) stale.
  CodeMieSsoCredentials _expiredCredentials() => CodeMieSsoCredentials(
    cookies: {'codemie_access_token': 'expired.jwt.token'},
    apiUrl: 'https://codemie.lab.epam.com/code-assistant-api',
    expiresAt: DateTime.now()
        .subtract(const Duration(hours: 1))
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

  group('runCodemieSsoFlow — issue #586: the prompt outlives transcript churn', () {
    testWidgets(
      'an LLM-delta rebuild mid-flow keeps the authorize prompt up until the user acts',
      (tester) async {
        final env = MemoryExecutionEnv();
        final registry = await ProviderRegistry.load(env);
        final service = _RecordingService(env);
        final store = LastConnectionStore.inMemory();
        final done = Completer<bool>();
        // Holds the flow inside the post-SSO network hop until the churn
        // has fired — the window where the sheet's context dies.
        final projectsGate = Completer<List<String>>();

        await tester.pumpWidget(
          MaterialApp(
            home: _TranscriptHost(
              done: done,
              registry: registry,
              service: service,
              store: store,
              authenticate: (_, __) async => _expiredCredentials(),
              fetchProjects: (_, __) => projectsGate.future,
              models: const ['m1'],
            ),
          ),
        );
        await tester.pump(); // flow started; authenticate resolved; in _projectStep

        // The LLM replies mid-flow: the transcript rebuilds and the
        // subtree owning the flow's context is disposed.
        service.fireLlmMessageEvent();
        await tester.pump();

        projectsGate.complete(const []);
        await tester.pumpAndSettle();

        // The authorize prompt (the model picker — the step that demands
        // the user's action) must be up, and STAY up while the transcript
        // keeps rebuilding underneath it.
        expect(find.text('Connect'), findsOneWidget);
        await tester.pump();
        await tester.pump();
        expect(find.text('Connect'), findsOneWidget);

        // The user acts: the pick lands, the flow completes, the provider
        // is saved and the service reconfigured.
        await tester.enterText(find.byType(TextField), 'gpt-x');
        await tester.tap(find.text('Connect'));
        await tester.pumpAndSettle();

        expect(await done.future, isTrue);
        expect(registry.providers.single.modelId, 'gpt-x');
        expect(service.reconfigured!.modelId, 'gpt-x');
        expect(store.connection!.modelId, 'gpt-x');
      },
    );
  });
}

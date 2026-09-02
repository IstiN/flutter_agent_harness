import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Serves the Copilot token exchange and the copilot-shaped /models
/// payload (`{data: [{id, capabilities.limits}]}`) so connect flows never
/// touch the network.
final http_testing.MockClient _copilotModelsMockClient =
    http_testing.MockClient((request) async {
      if (request.url.host == 'api.github.com') {
        return http.Response(
          '{"token":"tid=fake;proxy-ep=proxy.individual.githubcopilot.com",'
          '"expires_at":9999999999,"refresh_in":1500}',
          200,
        );
      }
      if (request.url.path.endsWith('/models')) {
        return http.Response(
          '{"data":[{"id":"gpt-4.1","model_picker_enabled":true,'
          '"capabilities":{"supports":{"tool_calls":true},"limits":'
          '{"max_context_window_tokens":128000,"max_output_tokens":16384}}}]}',
          200,
        );
      }
      return http.Response('not found', 404);
    });

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli cliFor(
    StreamFunction streamFunction, {
    Model model = testModel,
    ExecutionEnv? envOverride,
    bool Function(String name)? envVarIsSet,
    String? Function(String name)? envVarValue,
    Future<List<String>> Function(String baseUrl, {required String apiKey})?
    modelsFetcher,
    http.Client? modelsHttpClient,
    void Function(String providerKind, String apiKey)? onProviderChanged,
    SecureKeyCache? secureKeys,
    CustomProviderRegistry? customProviders,
    void Function(String name, String value)? onSecretStored,
    String? providerKind,
    Future<OpenRouterOAuthKey> Function({
      required String code,
      required String codeVerifier,
      String? label,
    })?
    openRouterOAuthExchangeFn,
    Future<ChatGptOAuthCredentials> Function({
      required String code,
      required String redirectUri,
      required String verifier,
    })?
    chatGptOAuthExchangeFn,
    Future<String> Function({
      String? clientId,
      void Function(String)? onStatus,
    })?
    copilotDeviceFlowFn,
    Future<String> Function(String githubToken)? copilotUserFn,
    Future<CodeMieSsoCredentials?> Function(
      String codeMieUrl,
      void Function(String) onStatus,
    )?
    codeMieSsoAuthenticateFn,
    Future<String?> Function(
      String apiBase,
      String token,
      Future<String?> Function(
        String title,
        List<(String, String, String)> options,
      )
      pickOption,
      Future<String?> Function(String question, {bool secret}) askLine,
    )?
    codeMieGuidedSetupFn,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: model,
        apiKey: 'test-key',
        env: envOverride ?? env,
        sessionRoot: '/sessions',
        envVarIsSet: envVarIsSet,
        envVarValue: envVarValue,
        modelsFetcher: modelsFetcher,
        modelsHttpClient: modelsHttpClient,
        onProviderChanged: onProviderChanged,
        secureKeys: secureKeys,
        customProviders: customProviders,
        chatGptOAuthExchangeFn: chatGptOAuthExchangeFn,
        onSecretStored: onSecretStored,
        copilotDeviceFlowFn: copilotDeviceFlowFn,
        copilotUserFn: copilotUserFn,
        providerKind: providerKind ?? 'openai-completions',
        openRouterOAuthExchangeFn: openRouterOAuthExchangeFn,
        codeMieSsoAuthenticateFn: codeMieSsoAuthenticateFn,
        codeMieGuidedSetupFn: codeMieGuidedSetupFn,
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  group('Copilot connect', () {
    test('/provider copilot device flow: auth, default name, individual plan, '
        'entry + key saved, switch', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = FakeSecureKeyStore();
      final cache = SecureKeyCache(store);
      await cache.probe();
      final registry = CustomProviderRegistry([]);
      final changes = <(String, String)>[];
      final statuses = <String>[];
      final cli = cliFor(
        modelsHttpClient: _copilotModelsMockClient,
        fake.call,
        envVarValue: (_) => null,
        secureKeys: cache,
        customProviders: registry,
        onProviderChanged: (kind, key) => changes.add((kind, key)),
        copilotDeviceFlowFn: ({clientId, onStatus}) async {
          statuses.add('called');
          onStatus?.call('open the page, enter ABCD-1234');
          expect(clientId, isNull); // no FA_COPILOT_CLIENT_ID override here
          return 'gh-token-1';
        },
        copilotUserFn: (githubToken) async {
          expect(githubToken, 'gh-token-1');
          return 'octocat';
        },
      );
      final run = cli.run();

      io.sendLine('/provider copilot');
      await waitForIt(() => io.out.toString().contains('Copilot sign-in'));
      io.sendLine('1'); // the device flow
      await waitForIt(
        () => io.out.toString().contains('provider name [copilot-octocat]'),
      );
      io.sendLine(''); // keep the default copilot-octocat
      await waitForIt(() => io.out.toString().contains('Copilot plan'));
      io.sendLine('1'); // individual
      await waitForIt(() => io.out.toString().contains('Copilot model'));
      io.sendLine('1');
      await waitForIt(
        () => io.out.toString().contains('switched provider to copilot'),
      );
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      expect(output, contains('copilot-octocat'));
      final entry = registry.find('copilot-octocat')!;
      expect(entry.apiType, 'copilot');
      expect(entry.baseUrl, 'https://api.githubcopilot.com');
      expect(entry.modelId, 'gpt-4.1');
      expect(entry.keyName, 'FA_KEY_COPILOT_COPILOT_OCTOCAT');
      expect(store.map['FA_KEY_COPILOT_COPILOT_OCTOCAT'], 'gh-token-1');
      expect(changes.single.$1, 'copilot');
      expect(changes.single.$2, 'gh-token-1');
      expect(cli.agent.state.model.provider, 'copilot');
      expect(cli.providerKind, 'copilot');
      expect(statuses, isNotEmpty);
      // The token never reaches the transcript.
      expect(output, isNot(contains('gh-token-1')));
    });

    test('/provider copilot paste-token variant stores and switches', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = FakeSecureKeyStore();
      final cache = SecureKeyCache(store);
      await cache.probe();
      final registry = CustomProviderRegistry([]);
      final cli = cliFor(
        modelsHttpClient: _copilotModelsMockClient,
        fake.call,
        envVarValue: (_) => null,
        secureKeys: cache,
        customProviders: registry,
        copilotUserFn: (_) async => 'hubot',
      );
      final run = cli.run();

      io.sendLine('/provider copilot');
      await waitForIt(() => io.out.toString().contains('Copilot sign-in'));
      io.sendLine('2'); // paste an existing token
      await waitForIt(() => io.out.toString().contains('GitHub token:'));
      io.sendLine('gh-paste-1');
      await waitForIt(
        () => io.out.toString().contains('provider name [copilot-hubot]'),
      );
      io.sendLine('');
      await waitForIt(() => io.out.toString().contains('Copilot plan'));
      io.sendLine('2'); // business
      await waitForIt(() => io.out.toString().contains('Copilot model'));
      io.sendLine('1');
      await waitForIt(
        () => io.out.toString().contains('switched provider to copilot'),
      );
      io.sendLine('/exit');
      await run;

      final entry = registry.find('copilot-hubot')!;
      expect(entry.baseUrl, 'https://api.business.githubcopilot.com');
      expect(store.map[entry.keyName!], 'gh-paste-1');
      expect(io.out.toString(), isNot(contains('gh-paste-1')));
    });

    test('entry-name clash retries; a re-auth default name updates only '
        'that entry', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = FakeSecureKeyStore()
        ..map['FA_KEY_COPILOT_COPILOT_A'] = 'tok-old-a'
        ..map['FA_KEY_COPILOT_COPILOT_B'] = 'tok-b';
      final cache = SecureKeyCache(store);
      await cache.preload(const [
        'FA_KEY_COPILOT_COPILOT_A',
        'FA_KEY_COPILOT_COPILOT_B',
      ]);
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'copilot-a',
          apiType: 'copilot',
          baseUrl: 'https://api.githubcopilot.com',
          modelId: 'gpt-4.1',
          keyName: 'FA_KEY_COPILOT_COPILOT_A',
        ),
        CustomProviderEntry(
          name: 'copilot-b',
          apiType: 'copilot',
          baseUrl: 'https://api.business.githubcopilot.com',
          modelId: 'gpt-4.1',
          keyName: 'FA_KEY_COPILOT_COPILOT_B',
        ),
        CustomProviderEntry(
          name: 'corp',
          apiType: 'openai',
          baseUrl: 'https://api.corp.example/v1',
          modelId: 'm1',
          keyName: 'CORP_KEY',
        ),
      ]);
      final cli = cliFor(
        modelsHttpClient: _copilotModelsMockClient,
        fake.call,
        envVarValue: (_) => null,
        secureKeys: cache,
        customProviders: registry,
        copilotDeviceFlowFn: ({clientId, onStatus}) async => 'gh-new-a',
        copilotUserFn: (_) async => 'a',
      );
      final run = cli.run();

      io.sendLine('/provider copilot');
      await waitForIt(() => io.out.toString().contains('Copilot account'));
      io.sendLine('3'); // add another account (2 entries listed first)
      await waitForIt(() => io.out.toString().contains('Copilot sign-in'));
      io.sendLine('1'); // device flow
      await waitForIt(
        () => io.out.toString().contains('provider name [copilot-a]'),
      );
      io.sendLine('corp'); // clash with a different endpoint
      await waitForIt(() => io.out.toString().contains('already used by'));
      io.sendLine('kimi'); // a built-in catalog name
      await waitForIt(() => io.out.toString().contains('built-in provider'));
      io.sendLine(''); // default copilot-a — the same account again
      await waitForIt(() => io.out.toString().contains('Copilot plan'));
      io.sendLine('1'); // individual
      await waitForIt(() => io.out.toString().contains('Copilot model'));
      io.sendLine('1');
      await waitForIt(
        () => io.out.toString().contains('switched provider to copilot'),
      );
      io.sendLine('/exit');
      await run;

      // Only copilot-a's slot was renewed; copilot-b is untouched.
      expect(store.map['FA_KEY_COPILOT_COPILOT_A'], 'gh-new-a');
      expect(store.map['FA_KEY_COPILOT_COPILOT_B'], 'tok-b');
      expect(registry.find('copilot-a')!.keyName, 'FA_KEY_COPILOT_COPILOT_A');
      expect(
        registry.find('copilot-b')!.baseUrl,
        'https://api.business.githubcopilot.com',
      );
      expect(registry.find('corp'), isNotNull);
    });

    test(
      'a rejected device flow surfaces endpointDisabled and aborts',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final cli = cliFor(
          modelsHttpClient: _copilotModelsMockClient,
          fake.call,
          envVarValue: (_) => null,
          copilotDeviceFlowFn: ({clientId, onStatus}) async {
            throw const CopilotDeviceFlowError(
              CopilotDeviceFlowErrorKind.endpointDisabled,
              'GitHub rejected the device flow (HTTP 404) for client id '
              'Iv1.test — paste an existing GitHub token instead',
            );
          },
        );
        final run = cli.run();

        io.sendLine('/provider copilot');
        await waitForIt(() => io.out.toString().contains('Copilot sign-in'));
        io.sendLine('1');
        await waitForIt(
          () => io.out.toString().contains('Copilot device flow failed'),
        );
        io.sendLine('/exit');
        await run;

        expect(io.out.toString(), contains('Iv1.test'));
        expect(io.out.toString(), isNot(contains('switched provider')));
      },
    );

    test('paste flow rejects a fine-grained PAT and re-asks', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = FakeSecureKeyStore();
      final cache = SecureKeyCache(store);
      await cache.probe();
      final registry = CustomProviderRegistry([]);
      final cli = cliFor(
        modelsHttpClient: _copilotModelsMockClient,
        fake.call,
        envVarValue: (_) => null,
        secureKeys: cache,
        customProviders: registry,
        copilotUserFn: (_) async => 'hubot',
      );
      final run = cli.run();

      io.sendLine('/provider copilot');
      await waitForIt(() => io.out.toString().contains('Copilot sign-in'));
      io.sendLine('2'); // paste an existing token
      await waitForIt(() => io.out.toString().contains('GitHub token:'));
      io.sendLine('github_pat_FINEGRAINED_TOKEN');
      await waitForIt(
        () => io.out.toString().contains('fine-grained'),
      );
      // Re-asked (the flow continues), not aborted.
      await waitForIt(() => io.out.toString().contains('GitHub token:'));
      io.sendLine('ghp_classic');
      await waitForIt(
        () => io.out.toString().contains('provider name [copilot-hubot]'),
      );
      io.sendLine('');
      await waitForIt(() => io.out.toString().contains('Copilot plan'));
      io.sendLine('1'); // individual
      await waitForIt(() => io.out.toString().contains('Copilot model'));
      io.sendLine('1');
      await waitForIt(
        () => io.out.toString().contains('switched provider to copilot'),
      );
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      expect(output, contains('fine-grained'));
      expect(output, contains('device flow'));
      expect(store.map['FA_KEY_COPILOT_COPILOT_HUBOT'], 'ghp_classic');
      // The typed token never reaches the transcript.
      expect(output, isNot(contains('github_pat_FINEGRAINED_TOKEN')));
    });

    test('a dead token exchange is reported before manual model entry',
        () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final deadExchange = http_testing.MockClient((request) async {
        if (request.url.host == 'api.github.com') {
          return http.Response(
            '{"documentation_url":"https://docs.github.com/rest",'
            '"message":"Not Found","status":"404"}',
            404,
          );
        }
        return http.Response('{"data":[]}', 200);
      });
      final registry = CustomProviderRegistry([]);
      final cli = cliFor(
        modelsHttpClient: deadExchange,
        fake.call,
        envVarValue: (_) => null,
        customProviders: registry,
        copilotUserFn: (_) async => 'hubot',
      );
      final run = cli.run();

      io.sendLine('/provider copilot');
      await waitForIt(() => io.out.toString().contains('Copilot sign-in'));
      io.sendLine('2'); // paste an existing token
      await waitForIt(() => io.out.toString().contains('GitHub token:'));
      io.sendLine('ghp_no_copilot_plan');
      await waitForIt(
        () => io.out.toString().contains('provider name [copilot-hubot]'),
      );
      io.sendLine('');
      await waitForIt(() => io.out.toString().contains('Copilot plan'));
      io.sendLine('1'); // individual
      // The exchange failure is surfaced, not swallowed into an empty
      // model list.
      await waitForIt(() => io.out.toString().contains('token exchange'));
      await waitForIt(() => io.out.toString().contains('model id: '));
      io.sendLine('gpt-4.1');
      await waitForIt(
        () => io.out.toString().contains('switched provider to copilot'),
      );
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      expect(output, contains('token exchange'));
      expect(output, contains('404'));
      expect(registry.find('copilot-hubot')!.modelId, 'gpt-4.1');
    });

    test('picking an existing account switches to it', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = FakeSecureKeyStore()
        ..map['FA_KEY_COPILOT_COPILOT_B'] = 'tok-b';
      final cache = SecureKeyCache(store);
      await cache.preload(const ['FA_KEY_COPILOT_COPILOT_B']);
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'copilot-b',
          apiType: 'copilot',
          baseUrl: 'https://api.business.githubcopilot.com',
          modelId: 'gpt-4.1',
          keyName: 'FA_KEY_COPILOT_COPILOT_B',
        ),
      ]);
      final cli = cliFor(
        modelsHttpClient: _copilotModelsMockClient,
        fake.call,
        envVarValue: (_) => null,
        secureKeys: cache,
        customProviders: registry,
      );
      final run = cli.run();

      io.sendLine('/provider copilot');
      await waitForIt(() => io.out.toString().contains('Copilot account'));
      io.sendLine('1'); // copilot-b
      await waitForIt(
        () => io.out.toString().contains('switched provider to copilot'),
      );
      io.sendLine('/exit');
      await run;

      expect(
        cli.agent.state.model.baseUrl,
        'https://api.business.githubcopilot.com',
      );
    });

    test('a custom plan base URL lands in the entry', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final registry = CustomProviderRegistry([]);
      final cli = cliFor(
        modelsHttpClient: _copilotModelsMockClient,
        fake.call,
        envVarValue: (_) => null,
        customProviders: registry,
        copilotDeviceFlowFn: ({clientId, onStatus}) async => 'gh-token-2',
        copilotUserFn: (_) async => 'octocat',
      );
      final run = cli.run();

      io.sendLine('/provider copilot');
      await waitForIt(() => io.out.toString().contains('Copilot sign-in'));
      io.sendLine('1');
      await waitForIt(
        () => io.out.toString().contains('provider name [copilot-octocat]'),
      );
      io.sendLine('');
      await waitForIt(() => io.out.toString().contains('Copilot plan'));
      io.sendLine('4'); // custom base URL
      await waitForIt(() => io.out.toString().contains('base URL:'));
      io.sendLine('https://copilot.corp.example/v1');
      await waitForIt(() => io.out.toString().contains('Copilot model'));
      io.sendLine('1');
      await waitForIt(
        () => io.out.toString().contains('switched provider to copilot'),
      );
      io.sendLine('/exit');
      await run;

      expect(
        registry.find('copilot-octocat')!.baseUrl,
        'https://copilot.corp.example/v1',
      );
    });

    test('/provider copilot rejects invalid usage', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/provider copilot extra');
      await waitForIt(
        () => io.out.toString().contains('usage: /provider copilot'),
      );
      io.sendLine('/exit');
      await run;
    });
  });

  group('endpoint-reported context window in roles mode', () {
    // Roles mode used to skip the /models limits detection entirely, so a
    // chain entry riding the catalog default (copilot = 1M) never learned
    // the real window — e.g. kimi-k2.7-code is 256000 on the endpoint.
    AgentCli rolesCli(
      List<ModelRef> defaultChain, {
      required FakeStreamFunction fake,
    }) {
      final resolver = ModelRolesResolver(
        config: ModelRolesConfig(
          roles: {'default': defaultChain},
          retry: const ModelRolesRetryPolicy(retriesPerEntry: 0),
        ),
        secrets: const {'COPILOT_GITHUB_TOKEN': 'test-key'},
        streamFactory: (kind, apiKey) => (model, context, {cancelToken}) {
          final stream = AssistantMessageEventStream();
          stream.push(StartEvent(partial: testAssistant()));
          stream.push(
            DoneEvent(
              reason: StopReason.stop,
              message: testAssistant(
                content: [TextContent(text: 'ok')],
              ),
            ),
          );
          stream.end();
          return stream;
        },
      );
      return AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          modelRolesResolver: resolver,
          modelsHttpClient: _copilotModelsMockClient,
        ),
        io: io,
        streamFunction: fake.call,
      );
    }

    test('a chain entry on catalog defaults learns the real window', () async {
      // Copilot catalog default is 1M; the endpoint reports 128000 for
      // gpt-4.1 (see _copilotModelsMockClient).
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = rolesCli(
        [ModelRef(provider: 'copilot', modelId: 'gpt-4.1')],
        fake: fake,
      );
      final run = cli.run();

      await waitForIt(
        () => io.out.toString().contains('model context window: 128000'),
        reason: 'endpoint window applied in roles mode',
      );
      io.sendLine('/exit');
      await run;

      expect(cli.agent.state.model.contextWindow, 128000);
      expect(io.out.toString(), contains('(from endpoint)'));
    });

    test('an explicitly pinned roles window wins over the endpoint',
        () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = rolesCli(
        [
          ModelRef(
            provider: 'copilot',
            modelId: 'gpt-4.1',
            contextWindow: 123456,
            maxTokens: 8192,
          ),
        ],
        fake: fake,
      );
      final run = cli.run();

      await waitForIt(() => io.out.toString().contains('[Model]'));
      // Give the background model-cache refresh time to (not) apply.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      io.sendLine('/exit');
      await run;

      expect(cli.agent.state.model.contextWindow, 123456);
      expect(io.out.toString(), isNot(contains('(from endpoint)')));
    });
  });
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// The ChatGPT OAuth group, split out of `agent_cli_provider_test.dart` to
/// keep that file under the repo's 2800-line size gate. Same per-file
/// `cliFor` convention as every sibling CLI test.
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
    String? Function(String name)? envVarValue,
    Future<List<String>> Function(String baseUrl, {required String apiKey})?
    modelsFetcher,
    SecureKeyCache? secureKeys,
    CustomProviderRegistry? customProviders,
    String? providerKind,
    Future<ChatGptOAuthCredentials> Function({
      required String code,
      required String redirectUri,
      required String verifier,
    })?
    chatGptOAuthExchangeFn,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: model,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        envVarValue: envVarValue,
        modelsFetcher: modelsFetcher,
        secureKeys: secureKeys,
        customProviders: customProviders,
        providerKind: providerKind ?? 'openai-completions',
        chatGptOAuthExchangeFn: chatGptOAuthExchangeFn,
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  group('ChatGPT OAuth', () {
    test(
      '/provider chatgpt oauth headless exchanges, stores credentials and switches',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final store = FakeSecureKeyStore();
        final cache = SecureKeyCache(store);
        await cache.probe();
        final registry = CustomProviderRegistry([]);
        final cli = cliFor(
          fake.call,
          envVarValue: (_) => null,
          secureKeys: cache,
          customProviders: registry,
          // A new account answers the guided model pick; an empty list
          // keeps the bundled default (no picker).
          modelsFetcher: (baseUrl, {required apiKey}) async => const [],
          chatGptOAuthExchangeFn:
              ({
                required String code,
                required String redirectUri,
                required String verifier,
              }) async {
                expect(code, 'auth-code-xyz');
                expect(redirectUri, 'http://127.0.0.1:1455/auth/callback');
                expect(verifier, isNotEmpty);
                return const ChatGptOAuthCredentials(
                  accessToken: 'at-123',
                  refreshToken: 'rt-123',
                  idToken: 'it-123',
                  accountId: 'acc-123',
                );
              },
        );
        final run = cli.run();

        io.sendLine('/provider chatgpt oauth headless');
        await waitForIt(
          () => io.out.toString().contains('ChatGPT OAuth (headless)'),
        );
        await waitForIt(() => io.out.toString().contains('redirect URL:'));

        // The printed authorize URL carries the state parameter the
        // callback must echo back.
        final authUrlLine = io.out
            .toString()
            .split('\n')
            .firstWhere((line) => line.contains('auth.openai.com'));
        final state = Uri.parse(authUrlLine.trim()).queryParameters['state'];
        expect(state, isNotNull);

        io.sendLine(
          'http://127.0.0.1:1455/auth/callback?code=auth-code-xyz&state=$state',
        );
        // The connect flow asks for the provider name like every other
        // add flow; a typed name lands the account in the registry.
        await waitForIt(
          () => io.out.toString().contains('provider name [chatgpt.com]'),
        );
        io.sendLine('my-chatgpt');
        await waitForIt(
          () => io.out.toString().contains('switched provider to chatgpt'),
        );
        io.sendLine('/exit');
        await run;

        final output = io.out.toString();
        expect(output, contains('ChatGPT authorized'));
        // The blob lives in the entry's OWN name-scoped slot (CodeMie's
        // per-entry key pattern), not the shared legacy env-name slot.
        final stored = store.map['FA_KEY_CHATGPT_COM_MY_CHATGPT'];
        expect(stored, isNotNull);
        expect(stored, contains('"access_token":"at-123"'));
        expect(stored, contains('"refresh_token":"rt-123"'));
        expect(stored, contains('"chatgpt_account_id":"acc-123"'));
        expect(store.map['CHATGPT_OAUTH_CREDENTIALS'], isNull);
        // The account shows in /provider as a saved entry.
        final entry = registry.find('my-chatgpt');
        expect(entry, isNotNull);
        expect(entry!.apiType, 'chatgpt');
        expect(entry.keyName, 'FA_KEY_CHATGPT_COM_MY_CHATGPT');
        expect(entry.modelId, chatGptCodexDefaultModel);
        expect(cli.agent.state.model.provider, 'chatgpt');
        expect(cli.providerKind, 'chatgpt-codex');
        // Tokens live ONLY in the secure store: the persisted registry
        // (config.yaml shape) and the transcript never carry them.
        final persistedConfig = jsonEncode(
          registry.entries.map((entry) => entry.toYaml()).toList(),
        );
        for (final secret in ['at-123', 'rt-123', 'it-123']) {
          expect(persistedConfig, isNot(contains(secret)));
          expect(output, isNot(contains(secret)));
        }
      },
    );

    test('/provider chatgpt oauth headless rejects a bad-state URL', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/provider chatgpt oauth headless');
      await waitForIt(() => io.out.toString().contains('redirect URL:'));
      io.sendLine('http://127.0.0.1:1455/auth/callback?code=x&state=wrong');
      await waitForIt(() => io.out.toString().contains('invalid redirect URL'));
      io.sendLine('/exit');
      await run;
    });

    test('two ChatGPT accounts keep separate credential slots', () async {
      final fake = FakeStreamFunction([textTurn('ok'), textTurn('ok')]);
      final store = FakeSecureKeyStore();
      final cache = SecureKeyCache(store);
      await cache.probe();
      final registry = CustomProviderRegistry([]);
      var round = 0;
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        secureKeys: cache,
        customProviders: registry,
        // No live model answer — a new account keeps the bundled default.
        modelsFetcher: (baseUrl, {required apiKey}) async => const [],
        chatGptOAuthExchangeFn:
            ({
              required String code,
              required String redirectUri,
              required String verifier,
            }) async {
              round++;
              return ChatGptOAuthCredentials(
                accessToken: 'at-$round',
                refreshToken: 'rt-$round',
                idToken: 'it-$round',
              );
            },
      );
      final run = cli.run();

      // Round gates: the SECOND round must not answer prompts echoed by
      // the first round's transcript, so each round waits for a FRESH
      // authorize URL before pasting its redirect.
      var authUrls = 0;
      Future<void> oauth(String code, String name) async {
        final before = authUrls;
        io.sendLine('/provider chatgpt oauth headless');
        await waitForIt(() {
          authUrls = 'auth.openai.com'.allMatches(io.out.toString()).length;
          return authUrls > before;
        });
        final authUrlLine = io.out
            .toString()
            .split('\n')
            .lastWhere((line) => line.contains('auth.openai.com'));
        final state = Uri.parse(authUrlLine.trim()).queryParameters['state']!;
        io.sendLine(
          'http://127.0.0.1:1455/auth/callback?code=$code&state=$state',
        );
        // One 'provider name [' echo per round: wait for THIS round's
        // (split length = occurrences + 1).
        await waitForIt(
          () => io.out.toString().split('provider name [').length > before + 1,
          reason: 'name prompt for $name',
        );
        io.sendLine(name);
        await waitForIt(
          () =>
              io.out.toString().split('switched provider to chatgpt').length >
              before + 1,
          reason: 'switch for $name',
        );
      }

      await oauth('code-1', 'work');
      await oauth('code-2', 'personal');
      io.sendLine('/exit');
      await run;

      // Each account landed in its own name-scoped slot — the second
      // grant did not overwrite the first account's blob.
      expect(registry.find('work')!.keyName, 'FA_KEY_CHATGPT_COM_WORK');
      expect(registry.find('personal')!.keyName, 'FA_KEY_CHATGPT_COM_PERSONAL');
      expect(
        store.map['FA_KEY_CHATGPT_COM_WORK'],
        contains('"access_token":"at-1"'),
      );
      expect(
        store.map['FA_KEY_CHATGPT_COM_PERSONAL'],
        contains('"access_token":"at-2"'),
      );
    });

    test('/provider chatgpt oauth offers the saved accounts first', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final blob = const ChatGptOAuthCredentials(
        accessToken: 'at-b',
        refreshToken: 'rt-b',
        idToken: 'it-b',
      ).encode();
      final store = FakeSecureKeyStore()
        ..map['FA_KEY_CHATGPT_COM_CHATGPT_B'] = blob;
      final cache = SecureKeyCache(store);
      await cache.preload(const ['FA_KEY_CHATGPT_COM_CHATGPT_B']);
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'chatgpt-b',
          apiType: 'chatgpt',
          baseUrl: 'https://chatgpt.com/backend-api/codex',
          modelId: 'gpt-5.6-sol',
          keyName: 'FA_KEY_CHATGPT_COM_CHATGPT_B',
        ),
      ]);
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        secureKeys: cache,
        customProviders: registry,
      );
      final run = cli.run();

      io.sendLine('/provider chatgpt oauth');
      await waitForIt(() => io.out.toString().contains('ChatGPT account'));
      io.sendLine('1'); // chatgpt-b
      await waitForIt(
        () => io.out.toString().contains('switched provider to chatgpt'),
      );
      io.sendLine('/exit');
      await run;

      // Picking the saved account switched to it WITHOUT running OAuth.
      expect(
        cli.agent.state.model.baseUrl,
        'https://chatgpt.com/backend-api/codex',
      );
      expect(cli.agent.state.model.id, 'gpt-5.6-sol');
      expect(io.out.toString(), isNot(contains('auth.openai.com')));
    });

    test('re-auth to the SAME entry keeps its model', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = FakeSecureKeyStore();
      final cache = SecureKeyCache(store);
      await cache.probe();
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'work',
          apiType: 'chatgpt',
          baseUrl: 'https://chatgpt.com/backend-api/codex',
          modelId: 'my-pick',
          keyName: 'FA_KEY_CHATGPT_COM_WORK',
        ),
      ]);
      var fetched = 0;
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        secureKeys: cache,
        customProviders: registry,
        modelsFetcher: (baseUrl, {required apiKey}) async {
          fetched++;
          return ['gpt-5.6-sol'];
        },
        chatGptOAuthExchangeFn:
            ({
              required String code,
              required String redirectUri,
              required String verifier,
            }) async => const ChatGptOAuthCredentials(
              accessToken: 'at-2',
              refreshToken: 'rt-2',
              idToken: 'it-2',
            ),
      );
      final run = cli.run();

      io.sendLine('/provider chatgpt oauth headless');
      await waitForIt(() => io.out.toString().contains('redirect URL:'));
      final authUrlLine = io.out
          .toString()
          .split('\n')
          .lastWhere((line) => line.contains('auth.openai.com'));
      final state = Uri.parse(authUrlLine.trim()).queryParameters['state']!;
      io.sendLine(
        'http://127.0.0.1:1455/auth/callback?code=code-9&state=$state',
      );
      await waitForIt(() => io.out.toString().contains('provider name [work]'));
      io.sendLine(''); // Enter keeps the existing entry — same account.
      await waitForIt(
        () => io.out.toString().contains('switched provider to chatgpt'),
      );
      io.sendLine('/exit');
      await run;

      // Same account: the model pick never ran and the entry kept its
      // last-used model; the fresh blob renewed its own slot.
      expect(fetched, 0);
      expect(io.out.toString(), isNot(contains('ChatGPT model')));
      expect(registry.entries, hasLength(1));
      expect(registry.find('work')!.modelId, 'my-pick');
      expect(store.map['FA_KEY_CHATGPT_COM_WORK'], contains('"at-2"'));
    });

    test('a NEW account picks its model from the live list', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final store = FakeSecureKeyStore();
      final cache = SecureKeyCache(store);
      await cache.probe();
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'work',
          apiType: 'chatgpt',
          baseUrl: 'https://chatgpt.com/backend-api/codex',
          modelId: 'my-pick',
          keyName: 'FA_KEY_CHATGPT_COM_WORK',
        ),
      ]);
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        secureKeys: cache,
        customProviders: registry,
        modelsFetcher: (baseUrl, {required apiKey}) async => [
          'gpt-5.6-sol',
          'gpt-5.6-mini',
        ],
        chatGptOAuthExchangeFn:
            ({
              required String code,
              required String redirectUri,
              required String verifier,
            }) async => const ChatGptOAuthCredentials(
              accessToken: 'at-3',
              refreshToken: 'rt-3',
              idToken: 'it-3',
            ),
      );
      final run = cli.run();

      io.sendLine('/provider chatgpt oauth headless');
      await waitForIt(() => io.out.toString().contains('redirect URL:'));
      final authUrlLine = io.out
          .toString()
          .split('\n')
          .lastWhere((line) => line.contains('auth.openai.com'));
      final state = Uri.parse(authUrlLine.trim()).queryParameters['state']!;
      io.sendLine(
        'http://127.0.0.1:1455/auth/callback?code=code-3&state=$state',
      );
      await waitForIt(() => io.out.toString().contains('provider name [work]'));
      io.sendLine('personal'); // A different name = a second account.
      await waitForIt(() => io.out.toString().contains('ChatGPT model'));
      io.sendLine('2'); // gpt-5.6-mini
      await waitForIt(
        () => io.out.toString().contains('switched provider to chatgpt'),
      );
      io.sendLine('/exit');
      await run;

      // The pick landed on the NEW entry only; the sibling kept its own
      // model and blob.
      expect(registry.find('personal')!.modelId, 'gpt-5.6-mini');
      expect(registry.find('work')!.modelId, 'my-pick');
      expect(
        store.map['FA_KEY_CHATGPT_COM_WORK'],
        isNull,
        reason: 'the second account never touched the first slot',
      );
      expect(store.map['FA_KEY_CHATGPT_COM_PERSONAL'], contains('"at-3"'));
    });

    test(
      'a NEW account with no model answer keeps the bundled default',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final store = FakeSecureKeyStore();
        final cache = SecureKeyCache(store);
        await cache.probe();
        final registry = CustomProviderRegistry([]);
        final cli = cliFor(
          fake.call,
          envVarValue: (_) => null,
          secureKeys: cache,
          customProviders: registry,
          modelsFetcher: (baseUrl, {required apiKey}) async => const [],
          chatGptOAuthExchangeFn:
              ({
                required String code,
                required String redirectUri,
                required String verifier,
              }) async => const ChatGptOAuthCredentials(
                accessToken: 'at-4',
                refreshToken: 'rt-4',
                idToken: 'it-4',
              ),
        );
        final run = cli.run();

        io.sendLine('/provider chatgpt oauth headless');
        await waitForIt(() => io.out.toString().contains('redirect URL:'));
        final authUrlLine = io.out
            .toString()
            .split('\n')
            .lastWhere((line) => line.contains('auth.openai.com'));
        final state = Uri.parse(authUrlLine.trim()).queryParameters['state']!;
        io.sendLine(
          'http://127.0.0.1:1455/auth/callback?code=code-4&state=$state',
        );
        await waitForIt(
          () => io.out.toString().contains('provider name [chatgpt.com]'),
        );
        io.sendLine('');
        await waitForIt(
          () => io.out.toString().contains('switched provider to chatgpt'),
        );
        io.sendLine('/exit');
        await run;

        // Empty live list → no picker, the bundled Codex default.
        expect(io.out.toString(), isNot(contains('ChatGPT model')));
        expect(registry.entries.single.modelId, chatGptCodexDefaultModel);
      },
    );

    test('/provider chatgpt oauth rejects invalid usage', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/provider chatgpt oauth too many args');
      await waitForIt(
        () => io.out.toString().contains('usage: /provider chatgpt oauth'),
      );
      io.sendLine('/exit');
      await run;
    });
  });
}

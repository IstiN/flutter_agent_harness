// Issue #706 (identity half): one provider identity per auth domain in
// the /model picker — no `chatgpt` + `chatgpt.com` twins both marked
// "current". Covers the load-time merge of split records, the OAuth
// write path's alias resolution (no second record), and the picker rows.
import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// The config seam's inline exchange-fn type (no public typedef).
typedef ExchangeFn =
    Future<ChatGptOAuthCredentials> Function({
      required String code,
      required String redirectUri,
      required String verifier,
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
    CustomProviderRegistry? customProviders,
    SecureKeyCache? secureKeys,
    Future<List<String>> Function(String baseUrl, {required String apiKey})?
    modelsFetcher,
    String? Function(String name)? envVarValue,
    ExchangeFn? chatGptOAuthExchangeFn,
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
        providerKind: 'openai-completions',
        chatGptOAuthExchangeFn: chatGptOAuthExchangeFn,
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  ExchangeFn okExchange() =>
      ({required code, required redirectUri, required verifier}) async =>
          const ChatGptOAuthCredentials(
            accessToken: 'at-706',
            refreshToken: 'rt-706',
            idToken: 'it-706',
            accountId: 'acc-706',
          );

  group('provider identity canonicalization (#706)', () {
    test('load merges chatgpt + chatgpt.com onto one entry', () {
      // A split config (hand-edited ghost `chatgpt` + the OAuth-minted
      // `chatgpt.com`) must load as ONE record — nothing dropped: the
      // union keeps the key slot and the last-used models, with a note.
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'chatgpt.com',
          apiType: 'chatgpt',
          baseUrl: 'https://chatgpt.com/backend-api/codex',
          modelId: 'gpt-5-codex',
          keyName: 'FA_KEY_CHATGPT_COM_WORK',
        ),
        CustomProviderEntry(
          name: 'chatgpt',
          apiType: 'chatgpt',
          baseUrl: 'https://chatgpt.com/backend-api/codex',
          modelId: 'gpt-5',
          keyName: 'CHATGPT_OAUTH_CREDENTIALS',
        ),
      ]);
      expect(registry.entries, hasLength(1));
      final merged = registry.entries.single;
      expect(merged.apiType, 'chatgpt');
      // Union: the surviving record inherits fields the twin carried.
      expect(merged.keyName, isNotNull);
      expect(registry.mergeNotes, isNotEmpty);
    });

    test('ghost-first load: the note names the record that survives', () {
      // Reserved ghost listed FIRST (hand-edited config order): the
      // non-reserved twin takes over as the survivor, so the merge note
      // must name `chatgpt.com` as the survivor — an earlier note
      // emitter named the first-seen record and claimed the ghost
      // received the merge (#706 review).
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'chatgpt', // reserved: would shadow /provider chatgpt
          apiType: 'chatgpt',
          baseUrl: 'https://chatgpt.com/backend-api/codex',
          modelId: 'gpt-5',
          keyName: 'CHATGPT_OAUTH_CREDENTIALS',
        ),
        CustomProviderEntry(
          name: 'chatgpt.com',
          apiType: 'chatgpt',
          baseUrl: 'https://chatgpt.com/backend-api/codex',
          modelId: 'gpt-5-codex',
        ),
      ]);
      expect(registry.entries, hasLength(1));
      final survivor = registry.entries.single;
      expect(survivor.name, 'chatgpt.com');
      // The union path: the survivor inherits the twin's key slot
      // (nothing dropped) but keeps its OWN last-used model — the
      // twin's modelId is the one that falls away.
      expect(survivor.keyName, 'CHATGPT_OAUTH_CREDENTIALS');
      expect(survivor.modelId, 'gpt-5-codex');
      expect(registry.mergeNotes, [
        'merged duplicate provider record "chatgpt" onto "chatgpt.com" '
            '(same auth domain)',
      ]);
    });

    test(
      'the picker shows one chatgpt identity with one current marker',
      () async {
        // The owner screenshot repro: after ChatGPT OAuth the registry
        // holds `chatgpt.com` while the active catalog provider is
        // `chatgpt` — the /model provider step listed BOTH rows, each
        // marked "current" (one via the active custom entry, one via the
        // active provider). Exactly one row may carry the marker.
        final fake = FakeStreamFunction([textTurn('ok')]);
        final store = FakeSecureKeyStore();
        final cache = SecureKeyCache(store);
        await cache.probe();
        final registry = CustomProviderRegistry([
          // A second, unrelated provider forces the provider step of the
          // two-step pick — the screen the owner screenshot shows.
          CustomProviderEntry(
            name: 'work',
            apiType: 'openai',
            baseUrl: 'http://localhost:9000/v1',
            modelId: 'work-model',
          ),
        ]);
        final cli = cliFor(
          fake.call,
          customProviders: registry,
          secureKeys: cache,
          envVarValue: (_) => null,
          modelsFetcher: (baseUrl, {required apiKey}) async => const [],
          chatGptOAuthExchangeFn: okExchange(),
        );
        final run = cli.run();

        io.sendLine('/provider chatgpt oauth headless');
        await waitForIt(
          () => io.out.toString().contains('ChatGPT OAuth (headless)'),
        );
        await waitForIt(() => io.out.toString().contains('redirect URL:'));
        final authUrlLine = io.out
            .toString()
            .split('\n')
            .firstWhere((line) => line.contains('auth.openai.com'));
        final state = Uri.parse(authUrlLine.trim()).queryParameters['state'];
        io.sendLine(
          'http://127.0.0.1:1455/auth/callback?code=auth-code-xyz&state=$state',
        );
        // Accept the default account name.
        await waitForIt(() => io.out.toString().contains('provider name ['));
        io.sendLine('');
        await waitForIt(
          () => io.out.toString().contains('switched provider to chatgpt'),
        );
        io.sendLine('/exit');
        await run;

        final items = cli.buildModelMenuForTest('');
        final providerRows = items.where((i) => i.key.startsWith('@')).toList();
        expect(providerRows, isNotEmpty);
        // One identity per auth domain: no `chatgpt` + `chatgpt.com` twins.
        final chatgptRows = providerRows
            .where((i) => canonicalProviderName(i.label) == 'chatgpt')
            .toList();
        expect(chatgptRows, hasLength(1));
        // ...and across ALL rows exactly one current marker.
        final currentRows = providerRows
            .where((i) => i.description.contains('current'))
            .toList();
        expect(currentRows, hasLength(1));
      },
    );

    test(
      'OAuth with an existing same-domain entry mints no second record',
      () async {
        // The write path resolves aliases: with a same-domain record
        // already saved (alias spelling `chatgpt.com`, base URL variant),
        // completing OAuth must land on THAT record, not mint a twin.
        final fake = FakeStreamFunction([textTurn('ok')]);
        final store = FakeSecureKeyStore();
        final cache = SecureKeyCache(store);
        await cache.probe();
        final registry = CustomProviderRegistry([
          CustomProviderEntry(
            name: 'chatgpt.com',
            apiType: 'chatgpt',
            baseUrl: 'https://chatgpt.com/backend-api/codex/',
            modelId: 'gpt-5',
          ),
        ]);
        final cli = cliFor(
          fake.call,
          customProviders: registry,
          secureKeys: cache,
          envVarValue: (_) => null,
          modelsFetcher: (baseUrl, {required apiKey}) async => const [],
          chatGptOAuthExchangeFn: okExchange(),
        );
        final run = cli.run();

        io.sendLine('/provider chatgpt oauth headless');
        await waitForIt(
          () => io.out.toString().contains('ChatGPT OAuth (headless)'),
        );
        await waitForIt(() => io.out.toString().contains('redirect URL:'));
        final authUrlLine = io.out
            .toString()
            .split('\n')
            .firstWhere((line) => line.contains('auth.openai.com'));
        final state = Uri.parse(authUrlLine.trim()).queryParameters['state'];
        io.sendLine(
          'http://127.0.0.1:1455/auth/callback?code=auth-code-xyz&state=$state',
        );
        await waitForIt(() => io.out.toString().contains('provider name ['));
        // Accept the default: it must resolve onto the existing entry.
        io.sendLine('');
        await waitForIt(
          () => io.out.toString().contains('switched provider to chatgpt'),
        );
        io.sendLine('/exit');
        await run;

        // No second record: the pre-seeded same-domain entry received the
        // login (in place — same record, refreshed key slot and model).
        expect(registry.entries, hasLength(1));
        final landed = registry.entries.single;
        expect(landed.name, 'chatgpt.com');
        expect(landed.apiType, 'chatgpt');
        expect(
          store.map[landed.keyName],
          contains('"access_token":"at-706"'),
          reason: 'the OAuth blob lives in the landed record\'s key slot',
        );
      },
    );

    test(
      'a same-named entry on a different backend never receives the login',
      () async {
        // A proxy entry named `chatgpt.com` (its endpoint host) but on
        // the openai dialect against a different path is NOT the chatgpt
        // auth domain. Alias landing matched on NAME alone: the OAuth
        // blob overwrote the proxy's key slot while the entry kept its
        // own apiType/baseUrl — bricked. The match is constrained to
        // the same domain (this backend's dialect or endpoint); a
        // name-only twin on another backend is left alone and the login
        // mints a fresh record under a non-clashing name.
        final fake = FakeStreamFunction([textTurn('ok')]);
        final store = FakeSecureKeyStore();
        final cache = SecureKeyCache(store);
        await cache.probe();
        final registry = CustomProviderRegistry([
          CustomProviderEntry(
            name: 'chatgpt.com',
            apiType: 'openai',
            baseUrl: 'https://chatgpt.com/v1',
            modelId: 'proxy-model',
            keyName: 'FA_KEY_CHATGPT_COM_PROXY',
          ),
        ]);
        store.map['FA_KEY_CHATGPT_COM_PROXY'] = 'sk-proxy-key';
        final cli = cliFor(
          fake.call,
          customProviders: registry,
          secureKeys: cache,
          envVarValue: (_) => null,
          modelsFetcher: (baseUrl, {required apiKey}) async => const [],
          chatGptOAuthExchangeFn: okExchange(),
        );
        final run = cli.run();

        io.sendLine('/provider chatgpt oauth headless');
        await waitForIt(
          () => io.out.toString().contains('ChatGPT OAuth (headless)'),
        );
        await waitForIt(() => io.out.toString().contains('redirect URL:'));
        final authUrlLine = io.out
            .toString()
            .split('\n')
            .firstWhere((line) => line.contains('auth.openai.com'));
        final state = Uri.parse(authUrlLine.trim()).queryParameters['state'];
        io.sendLine(
          'http://127.0.0.1:1455/auth/callback?code=cross-backend&state=$state',
        );
        await waitForIt(() => io.out.toString().contains('provider name ['));
        // The default name (`chatgpt.com`, the host) clashes with the
        // proxy entry on another endpoint — the prompt must RETRY...
        io.sendLine('');
        await waitForIt(
          () => io.out.toString().contains('already used by'),
          reason: 'name-only twin must not silently receive the login',
        );
        // ...and the typed name mints a separate same-domain record.
        io.sendLine('codex-main');
        await waitForIt(
          () => io.out.toString().contains('switched provider to chatgpt'),
        );
        io.sendLine('/exit');
        await run;

        // The proxy entry is untouched: dialect, endpoint, and its own
        // key slot still hold the original key — never the OAuth blob.
        final proxy = registry.find('chatgpt.com')!;
        expect(proxy.apiType, 'openai');
        expect(proxy.baseUrl, 'https://chatgpt.com/v1');
        expect(proxy.modelId, 'proxy-model');
        expect(proxy.keyName, 'FA_KEY_CHATGPT_COM_PROXY');
        expect(store.map['FA_KEY_CHATGPT_COM_PROXY'], 'sk-proxy-key');
        // The login landed on a fresh chatgpt-domain record instead.
        final codex = registry.find('codex-main')!;
        expect(codex.apiType, 'chatgpt');
        expect(codex.baseUrl, 'https://chatgpt.com/backend-api/codex');
        expect(
          store.map[codex.keyName],
          contains('"access_token":"at-706"'),
          reason: 'the OAuth blob lives in the new record\'s own slot',
        );
      },
    );
  });
}

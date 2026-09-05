import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// CLI-level tests for `/provider aiin` (see
/// `aiin_connect_server_test.dart` for the loopback-flow tests). The
/// connect itself is a canned [AiinConnectResult] through
/// `AgentCliConfig.aiinConnectFn`; the identity-provider list and the
/// model list come from mocks.
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  http.Client aiinProvidersMock({
    List<String> providers = const ['google', 'github'],
  }) {
    return http_testing.MockClient((request) async {
      if (request.url.host == 'auth.aiin.by' &&
          request.url.path == '/api/oauth-proxy/providers') {
        return http.Response(jsonEncode({'providers': providers}), 200);
      }
      return http.Response('not found', 404);
    });
  }

  AgentCli cliFor(
    StreamFunction streamFunction, {
    String? Function(String name)? envVarValue,
    Future<List<String>> Function(String baseUrl, {required String apiKey})?
    modelsFetcher,
    SecureKeyCache? secureKeys,
    CustomProviderRegistry? customProviders,
    http.Client? modelsHttpClient,
    Future<void> Function(String kind, String key)? onProviderChanged,
    Future<AiinConnectResult?> Function({
      required String provider,
      void Function(String)? onStatus,
    })?
    aiinConnectFn,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: '[REDACTED:Sensitive Value]',
        env: env,
        sessionRoot: '/sessions',
        envVarValue: envVarValue,
        modelsFetcher: modelsFetcher,
        modelsHttpClient: modelsHttpClient,
        secureKeys: secureKeys,
        customProviders: customProviders,
        onProviderChanged: onProviderChanged,
        providerKind: 'aiin',
        aiinConnectFn: aiinConnectFn,
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  AiinConnectResult cannedResult({String? email}) {
    final jwt = aiinJwtForTest(email: email);
    return AiinConnectResult(
      apiKey: AiinApiKey(
        raw: 'sk-aiin-${'a' * 32}',
        id: 'key-1',
        prefix: 'sk-aiin-aaaaaaaa',
        createdAt: '2026-01-01T00:00:00Z',
      ),
      tokens: AiinOAuthTokens(
        accessToken: jwt,
        refreshToken: 'rt-1',
        tokenType: 'Bearer',
        expiresIn: 3600,
        refreshExpiresIn: 2592000,
      ),
      email: email,
    );
  }

  test('/provider aiin browser connect: provider pick, email-named entry, '
      'key stored, switch', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final store = FakeSecureKeyStore();
    final cache = SecureKeyCache(store);
    await cache.probe();
    final registry = CustomProviderRegistry([]);
    final changes = <(String, String)>[];
    var usedProvider = '';
    final cli = cliFor(
      fake.call,
      envVarValue: (_) => null,
      modelsFetcher: (baseUrl, {required apiKey}) async => [
        'm1',
        'test-model',
      ],
      secureKeys: cache,
      customProviders: registry,
      onProviderChanged: (kind, key) async { changes.add((kind, key)); },
      modelsHttpClient: aiinProvidersMock(),
      aiinConnectFn: ({required provider, onStatus}) async {
        usedProvider = provider;
        onStatus?.call('connected');
        return cannedResult(email: 'user@aiin.by');
      },
    );
    final run = cli.run();

    io.sendLine('/provider aiin');
    await waitForIt(
      () => io.out.toString().contains('AIIN (aiin.by) sign-in'),
    );
    io.sendLine('1'); // the browser connect
    await waitForIt(
      () => io.out.toString().contains('AIIN sign-in provider'),
    );
    io.sendLine('1'); // google (sorted first)
    await waitForIt(
      () => io.out.toString().contains('provider name [user@aiin.by]'),
    );
    io.sendLine(''); // keep the email-derived name
    await waitForIt(() => io.out.toString().contains('AIIN model'));
    io.sendLine('1'); // m1
    await waitForIt(
      () => io.out.toString().contains('switched provider to aiin'),
    );
    io.sendLine('/exit');
    await run;

    expect(usedProvider, 'google');
    final output = io.out.toString();
    expect(output, contains('AIIN API key registered (sk-aiin-aaaaaaaa…)'));
    final entry = registry.find('user@aiin.by')!;
    expect(entry.apiType, 'aiin');
    expect(entry.baseUrl, 'https://api.aiin.by/v1');
    expect(entry.modelId, 'm1');
    expect(store.map[entry.keyName], 'sk-aiin-${'a' * 32}');
    expect(changes.single.$1, 'aiin');
    expect(cli.agent.state.model.provider, 'aiin');
    expect(cli.providerKind, 'aiin');
    // The raw key never reaches the transcript.
    expect(output, isNot(contains('sk-aiin-${'a' * 32}')));
  });

  test('/provider aiin key <token>: no sign-in menu, explicit name kept',
      () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final store = FakeSecureKeyStore();
    final cache = SecureKeyCache(store);
    await cache.probe();
    final registry = CustomProviderRegistry([]);
    final cli = cliFor(
      fake.call,
      envVarValue: (_) => null,
      modelsFetcher: (baseUrl, {required apiKey}) async => ['m1'],
      secureKeys: cache,
      customProviders: registry,
    );
    final run = cli.run();

    io.sendLine('/provider aiin key sk-aiin-manual');
    await waitForIt(() => io.out.toString().contains('provider name'));
    io.sendLine('my-aiin');
    await waitForIt(() => io.out.toString().contains('AIIN model'));
    io.sendLine('1');
    await waitForIt(
      () => io.out.toString().contains('switched provider to aiin'),
    );
    io.sendLine('/exit');
    await run;

    final entry = registry.find('my-aiin')!;
    expect(entry.apiType, 'aiin');
    expect(store.map[entry.keyName], 'sk-aiin-manual');
    expect(io.out.toString(), isNot(contains('sk-aiin-manual')));
  });

  test('/provider aiin key with an empty answer cancels', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final registry = CustomProviderRegistry([]);
    final cli = cliFor(
      fake.call,
      envVarValue: (_) => null,
      customProviders: registry,
    );
    final run = cli.run();

    io.sendLine('/provider aiin');
    await waitForIt(
      () => io.out.toString().contains('AIIN (aiin.by) sign-in'),
    );
    io.sendLine('2'); // paste an existing key
    io.sendLine(''); // empty answer
    await waitForIt(() => io.out.toString().contains('AIIN setup cancelled'));
    io.sendLine('/exit');
    await run;

    expect(registry.entries, isEmpty);
  });

  test('/provider aiin cancels at the sign-in menu', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final registry = CustomProviderRegistry([]);
    final cli = cliFor(
      fake.call,
      envVarValue: (_) => null,
      customProviders: registry,
    );
    final run = cli.run();

    io.sendLine('/provider aiin');
    await waitForIt(() => io.out.toString().contains('type a number:'));
    io.interrupt(); // cancel the menu
    await waitForIt(
      () => io.out.toString().contains('AIIN setup cancelled'),
    );
    io.sendLine('/exit');
    await run;

    expect(registry.entries, isEmpty);
  });

  test('/provider aiin cancels at the identity-provider pick', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final registry = CustomProviderRegistry([]);
    final cli = cliFor(
      fake.call,
      envVarValue: (_) => null,
      customProviders: registry,
      modelsHttpClient: aiinProvidersMock(),
    );
    final run = cli.run();

    io.sendLine('/provider aiin');
    await waitForIt(
      () => io.out.toString().contains('AIIN (aiin.by) sign-in'),
    );
    io.sendLine('1'); // the browser connect
    await waitForIt(
      () => io.out.toString().contains('AIIN sign-in provider'),
    );
    io.interrupt(); // cancel the provider pick
    await waitForIt(
      () => io.out.toString().contains('AIIN setup cancelled'),
    );
    io.sendLine('/exit');
    await run;

    expect(registry.entries, isEmpty);
  });

  test('/provider aiin argument errors print usage', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call, envVarValue: (_) => null);
    final run = cli.run();

    io.sendLine('/provider aiin bogus');
    io.sendLine('/provider aiin key a b');
    await waitForIt(() {
      final output = io.out.toString();
      return 'usage: /provider aiin [key [apiKey]]'.allMatches(output).length >=
          2;
    });
    io.sendLine('/exit');
    await run;
  });

  test('/provider aiin connect failure (null result) applies nothing',
      () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final registry = CustomProviderRegistry([]);
    final cli = cliFor(
      fake.call,
      envVarValue: (_) => null,
      customProviders: registry,
      modelsHttpClient: aiinProvidersMock(providers: []),
      aiinConnectFn: ({required provider, onStatus}) async => null,
    );
    final run = cli.run();

    io.sendLine('/provider aiin');
    await waitForIt(
      () => io.out.toString().contains('AIIN (aiin.by) sign-in'),
    );
    io.sendLine('1'); // the browser connect
    // The provider list is empty -> the google fallback. The canned
    // connect returns null -> the flow reports a cancel, nothing applied.
    await waitForIt(
      () => io.out.toString().contains('AIIN sign-in provider'),
    );
    io.sendLine('1');
    await waitForIt(
      () => io.out.toString().contains('AIIN setup cancelled'),
    );
    io.sendLine('/exit');
    await run;

    expect(registry.entries, isEmpty);
  });
}

/// A minimal three-part JWT carrying an [email] claim.
String aiinJwtForTest({String? email}) {
  String part(Object? json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final payload = email == null ? <String, dynamic>{} : {'email': email};
  return '${part({'alg': 'none'})}.${part(payload)}.sig';
}

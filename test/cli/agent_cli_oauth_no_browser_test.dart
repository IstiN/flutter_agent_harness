// gh-1450 at the command layer: `--no-browser` on the OAuth-ish
// `/provider …` flows skips the browser launch, prints the authorization
// URL prominently, and the manual-callback round-trip still completes.
//
// These drive the REAL flows end-to-end (real loopback sockets): the
// test plays the browser — it reads the printed URL, extracts the
// callback target, and fires the callback exactly as a user pasting the
// redirect would. The exchange/key endpoints ride injected fakes (seam
// or MockClient), so nothing leaves the machine.
//
// ChatGPT's flow is flow-test-only here: its callback server binds the
// pinned ports 1455/1457 (not ephemeral), so a parallel test run could
// collide; the `--no-browser` behavior itself is pinned by
// chatgpt_oauth_server_test.dart and the flag threading by the usage
// test below.
@Tags(['io'])
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/openrouter_oauth_server.dart'
    show authorizationUrlPrefix, browserLaunchSkippedMessage;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

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
    String? Function(String name)? envVarValue,
    Future<List<String>> Function(String baseUrl, {required String apiKey})?
    modelsFetcher,
    http.Client? modelsHttpClient,
    SecureKeyCache? secureKeys,
    CustomProviderRegistry? customProviders,
    void Function(String name, String value)? onSecretStored,
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
        onSecretStored: onSecretStored,
        providerKind: 'openai-completions',
        openRouterOAuthExchangeFn: openRouterOAuthExchangeFn,
        chatGptOAuthExchangeFn: chatGptOAuthExchangeFn,
        codeMieSsoAuthenticateFn: codeMieSsoAuthenticateFn,
        codeMieGuidedSetupFn: codeMieGuidedSetupFn,
        aiinConnectFn: aiinConnectFn,
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  /// The authorization URL printed after the skip line (last one wins).
  String authorizationUrlFrom(String output) {
    final index = output.lastIndexOf(authorizationUrlPrefix);
    expect(index, greaterThanOrEqualTo(0), reason: 'no authorization URL');
    return output
        .substring(index + authorizationUrlPrefix.length)
        .split('\n')
        .first
        .trim();
  }

  /// A CodeMie SSO token: base64 JSON wrapping cookie-shaped JWTs.
  String codeMieToken() {
    final header = base64Url.encode(utf8.encode(jsonEncode({'alg': 'HS256'})));
    final payload = base64Url.encode(
      utf8.encode(jsonEncode({'exp': 9999999999})),
    );
    final jwt = '$header.$payload.signature';
    return base64.encode(
      utf8.encode(
        jsonEncode({
          'cookies': {'codemie_access_token': jwt},
        }),
      ),
    );
  }

  /// The fake AIIN backend: providers list, OAuth exchange, key
  /// registration. Everything the real connect flow hits besides the
  /// loopback callback.
  http.Client aiinBackend() {
    return http_testing.MockClient((request) async {
      final host = request.url.host;
      final path = request.url.path;
      if (host == 'auth.aiin.by' && path == '/api/oauth-proxy/providers') {
        return http.Response(
          jsonEncode({
            'providers': ['google'],
          }),
          200,
        );
      }
      if (host == 'auth.aiin.by' && path == '/api/oauth-proxy/initiate') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final redirect = body['client_redirect_uri'] as String? ?? '';
        final provider = body['provider'] as String? ?? 'google';
        // The hosted sign-in page embeds the redirect target and the
        // server-issued state — exactly what the fake browser reads.
        return http.Response(
          jsonEncode({
            'auth_url':
                'https://auth.aiin.by/login?client_redirect_uri='
                '${Uri.encodeComponent(redirect)}&state=it-state-1'
                '&provider=$provider',
            'state': 'it-state-1',
            'expires_in': 900,
          }),
          200,
        );
      }
      if (host == 'auth.aiin.by' && path == '/api/oauth-proxy/exchange') {
        return http.Response(
          jsonEncode({
            'access_token': aiinTestJwt(email: 'user@aiin.by'),
            'refresh_token': 'refresh.jwt.sig',
            'token_type': 'Bearer',
            'expires_in': 3600,
          }),
          200,
        );
      }
      if (host == 'api.aiin.by' && path == '/v1/keys') {
        return http.Response(
          jsonEncode({
            'id': 'key-1',
            'prefix': 'sk-aiin-abc12345',
            'key': 'sk-aiin-${'a' * 32}',
          }),
          201,
        );
      }
      return http.Response('not found', 404);
    });
  }

  test('/provider openrouter oauth --no-browser prints the URL and completes '
      'via a manual callback', () async {
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
      openRouterOAuthExchangeFn:
          ({
            required String code,
            required String codeVerifier,
            String? label,
          }) async {
            expect(code, 'manual-code');
            return const OpenRouterOAuthKey(key: 'sk-or-manual');
          },
    );
    final run = cli.run();

    io.sendLine('/provider openrouter oauth --no-browser');
    await waitForIt(
      () => io.out.toString().contains(browserLaunchSkippedMessage),
    );
    final authUrl = authorizationUrlFrom(io.out.toString());
    expect(authUrl, startsWith('https://openrouter.ai/auth?'));

    // Play the browser: authorize and land on the loopback redirect.
    final callbackUrl =
        Uri.parse(authUrl).queryParameters['callback_url'] ?? '';
    expect(callbackUrl, startsWith('http://127.0.0.1:'));
    final response = await http.get(
      Uri.parse(callbackUrl).replace(queryParameters: {'code': 'manual-code'}),
    );
    expect(response.statusCode, 200);

    await waitForIt(
      () => io.out.toString().contains('provider name [openrouter.ai]'),
    );
    io.sendLine('my-openrouter');
    await waitForIt(
      () => io.out.toString().contains('switched provider to openrouter'),
    );
    io.sendLine('/exit');
    await run;

    final entry = registry.find('my-openrouter');
    expect(entry, isNotNull);
    expect(store.map[entry!.keyName], 'sk-or-manual');
  });

  test('/provider codemie sso --no-browser prints the URL and completes via a '
      'manual token callback', () async {
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
      codeMieGuidedSetupFn: (apiBase, cookie, pickOption, askLine) async =>
          'codemie-model-1',
    );
    final run = cli.run();

    io.sendLine('/provider codemie sso --no-browser');
    await waitForIt(
      () => io.out.toString().contains(browserLaunchSkippedMessage),
    );
    final ssoUrl = authorizationUrlFrom(io.out.toString());
    expect(
      ssoUrl,
      startsWith(
        'https://codemie.lab.epam.com/code-assistant-api/v1/auth/login/',
      ),
    );

    // Play the browser: the organization redirects back with the token.
    final portMatch = RegExp(r'/auth/login/(\d+)').firstMatch(ssoUrl);
    expect(portMatch, isNotNull, reason: 'sso URL carries the port');
    final response = await http.get(
      Uri.parse(
        'http://127.0.0.1:${portMatch!.group(1)}/?token=${codeMieToken()}',
      ),
    );
    expect(response.statusCode, 200);

    await waitForIt(
      () => io.out.toString().contains('provider name [codemie.lab.epam.com]'),
    );
    io.sendLine('my-codemie');
    await waitForIt(() => io.out.toString().contains('saved provider'));
    io.sendLine('/exit');
    await run;

    final output = io.out.toString();
    expect(output, contains('CodeMie authorized'));
    final entry = registry.find('my-codemie');
    expect(entry, isNotNull);
    expect(
      entry!.baseUrl,
      'https://codemie.lab.epam.com/code-assistant-api/v1',
    );
    expect(store.map[entry.keyName], startsWith('codemie_access_token='));
  });

  test('/provider aiin --no-browser runs the real connect flow without a '
      'browser launch', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final store = FakeSecureKeyStore();
    final cache = SecureKeyCache(store);
    await cache.probe();
    final registry = CustomProviderRegistry([]);
    final cli = cliFor(
      fake.call,
      envVarValue: (_) => null,
      modelsFetcher: (baseUrl, {required apiKey}) async => ['m1'],
      modelsHttpClient: aiinBackend(),
      secureKeys: cache,
      customProviders: registry,
    );
    final run = cli.run();

    io.sendLine('/provider aiin --no-browser');
    await waitForIt(() => io.out.toString().contains('AIIN (aiin.by) sign-in'));
    io.sendLine('1'); // browser connect
    await waitForIt(() => io.out.toString().contains('AIIN sign-in provider'));
    io.sendLine('1'); // google
    await waitForIt(
      () => io.out.toString().contains(browserLaunchSkippedMessage),
    );
    final authUrl = authorizationUrlFrom(io.out.toString());
    expect(authUrl, contains('client_redirect_uri='));

    // Play the browser: read the redirect target + state from the
    // hosted login URL and fire the callback at the real loopback
    // server.
    final login = Uri.parse(authUrl);
    final redirect = login.queryParameters['client_redirect_uri'] ?? '';
    final state = login.queryParameters['state'] ?? '';
    final callbackResponse = await http.get(
      Uri.parse(
        redirect,
      ).replace(queryParameters: {'code': 'auth-code', 'state': state}),
    );
    expect(callbackResponse.statusCode, 200);

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

    final output = io.out.toString();
    expect(output, contains('AIIN API key registered'));
    final entry = registry.find('user@aiin.by');
    expect(entry, isNotNull);
    expect(store.map[entry!.keyName], 'sk-aiin-${'a' * 32}');
    // The raw key never reaches the transcript.
    expect(output, isNot(contains('sk-aiin-${'a' * 32}')));
  });

  test('mangled --no-browser command shapes fall back to usage', () async {
    final fake = FakeStreamFunction([textTurn('ok')]);
    final cli = cliFor(fake.call, envVarValue: (_) => null);
    final run = cli.run();

    io.sendLine('/provider chatgpt oauth --no-browser extra');
    await waitForIt(() => io.out.toString().contains('usage:'));
    io.sendLine('/provider codemie sso --no-browser not-a-url');
    await waitForIt(
      () => io.out.toString().contains('usage: /provider codemie'),
    );
    io.sendLine('/provider openrouter oauth bogus');
    await waitForIt(
      () => io.out.toString().contains('usage: /provider openrouter'),
    );
    io.sendLine('/provider aiin --no-browser extra');
    await waitForIt(() => io.out.toString().contains('usage: /provider aiin'));
    io.sendLine('/exit');
    await run;

    expect(
      io.out.toString(),
      isNot(contains(browserLaunchSkippedMessage)),
      reason: 'usage errors never start a flow',
    );
  });
}

/// A minimal three-part JWT carrying an [email] claim (same shape the
/// AIIN connect suite uses — `aiinJwtEmail` reads the payload claim).
String aiinTestJwt({String? email}) {
  String part(Object? json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final payload = email == null ? <String, dynamic>{} : {'email': email};
  return '${part({'alg': 'none'})}.${part(payload)}.sig';
}

// The CodeMie provider setup line-mode tests (issue #1809): the
// `/provider codemie` URL prompt, the guided project → model flow on every
// SSO/JWT connect (keep-current row on re-login), the loud failed-projects
// fetch, and the persisted project riding requests as `x-codemie-project`.
// Split out of `agent_cli_provider_test.dart` (2800-line gate, gh-1809 r2);
// network rides `modelsHttpClient` MockClients with EXACT path matchers —
// a doubled /v1 segment can never silently pass.
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
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
    http.Client? modelsHttpClient,
    SecureKeyCache? secureKeys,
    CustomProviderRegistry? customProviders,
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
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        envVarValue: envVarValue,
        modelsHttpClient: modelsHttpClient,
        secureKeys: secureKeys,
        customProviders: customProviders,
        providerKind: 'openai-completions',
        codeMieSsoAuthenticateFn: codeMieSsoAuthenticateFn,
        codeMieGuidedSetupFn: codeMieGuidedSetupFn,
      ),
      io: io,
      streamFunction: streamFunction,
    );
  }

  group('CodeMie SSO', () {
    test(
      '/provider codemie sso saves a custom provider, stores the cookie and switches',
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
          codeMieSsoAuthenticateFn: (url, onStatus) async {
            expect(url, 'https://codemie.lab.epam.com');
            return const CodeMieSsoCredentials(
              cookies: {'_oauth2_proxy': 'proxy-val', 'session': 's-1'},
              apiUrl: 'https://codemie.lab.epam.com/code-assistant-api',
              expiresAt: 9999999999999,
            );
          },
          codeMieGuidedSetupFn: (apiBase, cookie, pickOption, askLine) async {
            return 'codemie-model-1';
          },
        );
        final run = cli.run();

        io.sendLine('/provider codemie sso');
        // First login offers the provider-name step every add flow has.
        await waitForIt(
          () => io.out.toString().contains(
            'provider name [codemie.lab.epam.com]',
          ),
        );
        io.sendLine('my-codemie');
        await waitForIt(() => io.out.toString().contains('saved provider'));
        io.sendLine('/exit');
        await run;

        final output = io.out.toString();
        expect(output, contains('CodeMie session expires'));
        final entry = registry.find('my-codemie');
        expect(entry, isNotNull, reason: 'saved under the typed name');
        expect(
          entry!.baseUrl,
          'https://codemie.lab.epam.com/code-assistant-api/v1',
        );
        // A custom name scopes the store key (name-scoped slot).
        expect(entry.keyName, 'FA_KEY_CODEMIE_LAB_EPAM_COM_MY_CODEMIE');
        // The full cookie string is stored as the key.
        expect(store.map[entry.keyName], '_oauth2_proxy=proxy-val;session=s-1');
        expect(cli.providerKind, 'openai-completions');
        expect(
          cli.agent.state.model.baseUrl,
          'https://codemie.lab.epam.com/code-assistant-api/v1',
        );
        // The model carries cookie-header auth, not Bearer.
        expect(cli.agent.state.model.headers, {
          'cookie': '_oauth2_proxy=proxy-val;session=s-1',
        });
      },
    );

    test('same-account re-login still shows the project picker and the '
        'keep-current row preserves the pair (gh-1809)', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'codemie.lab.epam.com',
          apiType: 'openai',
          baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
          modelId: 'codemie-model-1',
          authMethod: CustomProviderAuthMethod.sso,
          project: 'demo-project',
        ),
      ]);
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        customProviders: registry,
        modelsHttpClient: _codeMieSsoMockClient(),
        codeMieSsoAuthenticateFn: (url, onStatus) async {
          return const CodeMieSsoCredentials(
            cookies: {'_oauth2_proxy': 'new-val'},
            apiUrl: 'https://codemie.lab.epam.com/code-assistant-api',
            expiresAt: 9999999999999,
          );
        },
      );
      final run = cli.run();

      io.sendLine('/provider codemie sso');
      // Explicit connect always offers the provider-name step — Enter
      // here keeps the existing entry (same-account cookie refresh).
      await waitForIt(
        () =>
            io.out.toString().contains('provider name [codemie.lab.epam.com]'),
      );
      io.sendLine('');
      // The project picker runs on the SAME-account path too (gh-1809
      // AC2/AC6) — led by the keep-current row.
      await waitForIt(() => io.out.toString().contains('CodeMie project'));
      await waitForIt(
        () => io.out.toString().contains('keep current project/model'),
      );
      io.sendLine('1'); // keep current project/model
      await waitForIt(() => io.out.toString().contains('saved provider'));
      io.sendLine('/exit');
      await run;

      // One entry, last-used model + project preserved, key refreshed.
      expect(registry.entries, hasLength(1));
      expect(registry.entries.single.modelId, 'codemie-model-1');
      expect(registry.entries.single.project, 'demo-project');
      expect(cli.agent.state.model.id, 'codemie-model-1');
      // The refreshed cookie and the picked project both ride the model.
      expect(cli.agent.state.model.headers?['cookie'], '_oauth2_proxy=new-val');
      expect(
        cli.agent.state.model.headers?['x-codemie-project'],
        'demo-project',
      );
    });

    test(
      're-login finds a renamed entry by base URL and keeps its name',
      () async {
        // The entry lookup is by base URL, not the derived host name — a
        // user-renamed entry must not duplicate on re-login; the name
        // prompt is offered, Enter keeps it.
        final fake = FakeStreamFunction([textTurn('ok')]);
        final registry = CustomProviderRegistry([
          CustomProviderEntry(
            name: 'work-codemie',
            apiType: 'openai',
            baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
            modelId: 'codemie-model-1',
            authMethod: CustomProviderAuthMethod.sso,
            project: 'demo-project',
          ),
        ]);
        final cli = cliFor(
          fake.call,
          envVarValue: (_) => null,
          customProviders: registry,
          modelsHttpClient: _codeMieSsoMockClient(),
          codeMieSsoAuthenticateFn: (url, onStatus) async {
            return const CodeMieSsoCredentials(
              cookies: {'_oauth2_proxy': 'new-val'},
              apiUrl: 'https://codemie.lab.epam.com/code-assistant-api',
              expiresAt: 9999999999999,
            );
          },
        );
        final run = cli.run();

        io.sendLine('/provider codemie sso');
        await waitForIt(
          () => io.out.toString().contains('provider name [work-codemie]'),
        );
        io.sendLine('');
        await waitForIt(() => io.out.toString().contains('CodeMie project'));
        io.sendLine('1'); // keep current project/model (gh-1809 AC2)
        await waitForIt(() => io.out.toString().contains('saved provider'));
        io.sendLine('/exit');
        await run;

        expect(registry.entries, hasLength(1), reason: 'no duplicate entry');
        expect(registry.entries.single.name, 'work-codemie');
        expect(registry.entries.single.modelId, 'codemie-model-1');
        expect(registry.entries.single.project, 'demo-project');
      },
    );

    test('/provider codemie sso with an existing entry asks for a name '
        'so a second account gets its own entry', () async {
      // User scenario: first codemie account saved, then adding a
      // SECOND one with a different enterprise profile. The explicit
      // connect flow must ask for a name — a typed name becomes a
      // SEPARATE entry, Enter keeps the existing one.
      final fake = FakeStreamFunction([textTurn('ok')]);
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'codemie.lab.epam.com',
          apiType: 'openai',
          baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
          modelId: 'codemie-model-1',
        ),
      ]);
      var guidedSetupCalls = 0;
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        customProviders: registry,
        codeMieSsoAuthenticateFn: (url, onStatus) async {
          return const CodeMieSsoCredentials(
            cookies: {'_oauth2_proxy': 'profile-2'},
            apiUrl: 'https://codemie.lab.epam.com/code-assistant-api',
            expiresAt: 9999999999999,
          );
        },
        codeMieGuidedSetupFn: (apiBase, cookie, pickOption, askLine) async {
          guidedSetupCalls++;
          return 'codemie-model-2';
        },
      );
      final run = cli.run();

      io.sendLine('/provider codemie sso');
      await waitForIt(
        () =>
            io.out.toString().contains('provider name [codemie.lab.epam.com]'),
      );
      io.sendLine('work');
      await waitForIt(() => io.out.toString().contains('saved provider'));
      io.sendLine('/exit');
      await run;

      // Two entries: the original kept, a new 'work' entry for the
      // second account.
      expect(registry.entries, hasLength(2));
      expect(registry.find('codemie.lab.epam.com'), isNotNull);
      final work = registry.find('work');
      expect(work, isNotNull);
      // A NEW account runs its own project → model pick (the profile
      // selection the CodeMie flow asks for), so its model is the guided
      // setup's choice, not the first account's.
      expect(guidedSetupCalls, 1);
      expect(work!.modelId, 'codemie-model-2');
      expect(registry.find('codemie.lab.epam.com')!.modelId, 'codemie-model-1');
      // The new entry's key is name-scoped — the existing entry's slot
      // is untouched.
      expect(work.keyName, 'FA_KEY_CODEMIE_LAB_EPAM_COM_WORK');
    });

    test(
      'selecting a saved CodeMie provider with an expired cookie re-runs SSO',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final registry = CustomProviderRegistry([
          CustomProviderEntry(
            name: 'codemie.lab.epam.com',
            apiType: 'openai',
            baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
            modelId: 'codemie-model-1',
            keyName: 'FA_KEY_CODEMIE_LAB_EPAM_COM',
          ),
        ]);
        final store = FakeSecureKeyStore();
        final cache = SecureKeyCache(store);
        await cache.probe();
        final expiredJwtPayload = base64Url.encode(utf8.encode('{"exp":1}'));
        await cache.save(
          'FA_KEY_CODEMIE_LAB_EPAM_COM',
          'codemie_access_token=eyJhbGciOiJIUzI1NiJ9.$expiredJwtPayload.sig',
        );
        var ssoCalled = false;
        final cli = cliFor(
          fake.call,
          envVarValue: (_) => null,
          secureKeys: cache,
          customProviders: registry,
          codeMieSsoAuthenticateFn: (url, onStatus) async {
            ssoCalled = true;
            expect(url, 'https://codemie.lab.epam.com');
            return const CodeMieSsoCredentials(
              cookies: {'_oauth2_proxy': 'refreshed'},
              apiUrl: 'https://codemie.lab.epam.com/code-assistant-api',
              expiresAt: 9999999999999,
            );
          },
          codeMieGuidedSetupFn: (apiBase, cookie, pickOption, askLine) async {
            return 'codemie-model-1';
          },
        );
        final run = cli.run();

        io.sendLine('/provider codemie.lab.epam.com');
        await waitForIt(
          () =>
              io.out.toString().contains('CodeMie session expired or missing'),
        );
        await waitForIt(() => io.out.toString().contains('saved provider'));
        io.sendLine('/exit');
        await run;

        expect(ssoCalled, isTrue);
        expect(cli.agent.state.model.id, 'codemie-model-1');
      },
    );

    test('a failed projects fetch is loud and the entry has no project '
        '(gh-1809 AC3/AC4)', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final registry = CustomProviderRegistry([]);
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        customProviders: registry,
        // /v1/user 403s — the broken-response case that used to look
        // identical to "no projects" (gh-1809 AC3).
        modelsHttpClient: _codeMieSsoMockClient(userStatus: 403),
        codeMieSsoAuthenticateFn: (url, onStatus) async {
          return const CodeMieSsoCredentials(
            cookies: {'_oauth2_proxy': 'proxy-val'},
            apiUrl: 'https://codemie.lab.epam.com/code-assistant-api',
            expiresAt: 9999999999999,
          );
        },
      );
      final run = cli.run();

      io.sendLine('/provider codemie sso');
      await waitForIt(
        () =>
            io.out.toString().contains('provider name [codemie.lab.epam.com]'),
      );
      io.sendLine('');
      await waitForIt(
        () => io.out.toString().contains('CodeMie projects fetch failed'),
      );
      // The picker was skipped — the flow moved on to the model step.
      await waitForIt(() => io.out.toString().contains('CodeMie model'));
      io.sendLine('1'); // pick codemie-model-1
      await waitForIt(() => io.out.toString().contains('saved provider'));
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      expect(output, contains('CodeMie projects fetch failed'));
      expect(output, isNot(contains('CodeMie project\n')));
      expect(registry.entries.single.project, isNull);
      expect(registry.entries.single.modelId, 'codemie-model-1');
      expect(cli.agent.state.model.headers?['x-codemie-project'], isNull);
    });

    test('first connect picks a project and it persists and rides the '
        'requests (gh-1809 AC4)', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final registry = CustomProviderRegistry([]);
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        customProviders: registry,
        modelsHttpClient: _codeMieSsoMockClient(),
        codeMieSsoAuthenticateFn: (url, onStatus) async {
          return const CodeMieSsoCredentials(
            cookies: {'_oauth2_proxy': 'proxy-val'},
            apiUrl: 'https://codemie.lab.epam.com/code-assistant-api',
            expiresAt: 9999999999999,
          );
        },
      );
      final run = cli.run();

      io.sendLine('/provider codemie sso');
      await waitForIt(
        () =>
            io.out.toString().contains('provider name [codemie.lab.epam.com]'),
      );
      io.sendLine('');
      // First connect: no keep-current row — the fetched projects only.
      await waitForIt(() => io.out.toString().contains('CodeMie project'));
      io.sendLine('2'); // demo-project (sorted after admin-project)
      await waitForIt(() => io.out.toString().contains('CodeMie model'));
      io.sendLine('1'); // pick codemie-model-1
      await waitForIt(() => io.out.toString().contains('saved provider'));
      io.sendLine('/exit');
      await run;

      expect(io.out.toString(), contains('selected project: demo-project'));
      expect(registry.entries.single.project, 'demo-project');
      expect(registry.entries.single.modelId, 'codemie-model-1');
      expect(
        cli.agent.state.model.headers?['x-codemie-project'],
        'demo-project',
      );
      expect(cli.agent.state.model.headers?['cookie'], isNotNull);
    });

    test('/provider codemie sso rejects a bad org URL', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/provider codemie sso not-a-url');
      await waitForIt(
        () => io.out.toString().contains('usage: /provider codemie sso'),
      );
      io.sendLine('/exit');
      await run;
    });

    test('/provider codemie jwt rejects a bad org URL', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/provider codemie jwt not-a-url token');
      await waitForIt(
        () => io.out.toString().contains('usage: /provider codemie jwt'),
      );
      io.sendLine('/exit');
      await run;
    });

    test('/provider codemie jwt rejects an invalid token format', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine(
        '/provider codemie jwt https://codemie.lab.epam.com not-a-jwt',
      );
      await waitForIt(
        () => io.out.toString().contains('Invalid JWT token format'),
      );
      io.sendLine('/exit');
      await run;
    });

    test('/provider codemie jwt rejects an expired token', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      final expiredToken = _makeJwtToken(exp: 1);
      io.sendLine(
        '/provider codemie jwt https://codemie.lab.epam.com $expiredToken',
      );
      await waitForIt(() => io.out.toString().contains('JWT token expired'));
      io.sendLine('/exit');
      await run;
    });

    test('/provider codemie jwt cancels on empty token', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/provider codemie jwt https://codemie.lab.epam.com');
      await waitForIt(() => io.out.toString().contains('JWT token:'));
      io.sendLine('');
      await waitForIt(
        () => io.out.toString().contains('CodeMie JWT setup cancelled'),
      );
      io.sendLine('/exit');
      await run;
    });

    test('/provider codemie bogus shows usage', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/provider codemie bogus');
      await waitForIt(
        () => io.out.toString().contains(
          'usage: /provider codemie [sso [orgUrl] [--no-browser] | '
          'jwt [orgUrl] [token]]',
        ),
      );
      io.sendLine('/exit');
      await run;
    });

    test(
      '/provider codemie jwt saves a custom provider, stores the token and switches',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final store = FakeSecureKeyStore();
        final cache = SecureKeyCache(store);
        await cache.probe();
        final registry = CustomProviderRegistry([]);
        final jwtToken = _makeJwtToken(exp: 9999999999);
        final mockClient = _codeMieJwtMockClient(jwtToken);
        final cli = cliFor(
          fake.call,
          envVarValue: (_) => null,
          secureKeys: cache,
          customProviders: registry,
          modelsHttpClient: mockClient,
        );
        final run = cli.run();

        io.sendLine(
          '/provider codemie jwt https://codemie.lab.epam.com $jwtToken',
        );
        // The JWT path runs the project step too (gh-1809 AC5).
        await waitForIt(() => io.out.toString().contains('CodeMie project'));
        io.sendLine('1'); // pick demo
        await waitForIt(() => io.out.toString().contains('CodeMie model'));
        io.sendLine('1'); // pick codemie-model-jwt
        await waitForIt(
          () => io.out.toString().contains(
            'provider name [codemie.lab.epam.com]',
          ),
        );
        io.sendLine(''); // keep the host-derived default name
        await waitForIt(() => io.out.toString().contains('saved provider'));
        io.sendLine('/exit');
        await run;

        final output = io.out.toString();
        expect(output, contains('JWT token expires in'));
        final entry = registry.find('codemie.lab.epam.com');
        expect(entry, isNotNull);
        expect(entry!.authMethod, CustomProviderAuthMethod.jwt);
        expect(
          entry.baseUrl,
          'https://codemie.lab.epam.com/code-assistant-api/v1',
        );
        // The picked project persists and rides the requests (gh-1809 AC4).
        expect(entry.project, 'demo');
        expect(cli.agent.state.model.headers?['x-codemie-project'], 'demo');
        expect(store.map[entry.keyName], jwtToken);
        expect(cli.providerKind, 'openai-completions');
        expect(cli.agent.state.model.baseUrl, entry.baseUrl);
        // JWT uses regular Bearer auth, not a cookie header.
        expect(cli.agent.state.model.headers, isNot(contains('cookie')));
      },
    );

    test('/provider codemie shows the URL prompt then the auth-method '
        'picker (gh-1809 AC1 default URL)', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final registry = CustomProviderRegistry([]);
      final jwtToken = _makeJwtToken(exp: 9999999999);
      final mockClient = _codeMieJwtMockClient(jwtToken);
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        customProviders: registry,
        modelsHttpClient: mockClient,
      );
      final run = cli.run();

      io.sendLine('/provider codemie');
      // The bare command asks WHERE CodeMie lives before the method
      // picker (gh-1809 AC1) — Enter applies the hosted default.
      await waitForIt(() => io.out.toString().contains('CodeMie URL ['));
      io.sendLine('');
      await waitForIt(
        () => io.out.toString().contains('CodeMie sign-in method'),
      );
      io.sendLine('2'); // JWT option
      await waitForIt(() => io.out.toString().contains('JWT token:'));
      io.sendLine(jwtToken);
      await waitForIt(() => io.out.toString().contains('CodeMie project'));
      io.sendLine('1'); // pick demo (gh-1809 AC5)
      await waitForIt(() => io.out.toString().contains('CodeMie model'));
      io.sendLine('1'); // pick codemie-model-jwt
      await waitForIt(
        () =>
            io.out.toString().contains('provider name [codemie.lab.epam.com]'),
      );
      io.sendLine(''); // keep the host-derived default name
      await waitForIt(() => io.out.toString().contains('saved provider'));
      io.sendLine('/exit');
      await run;

      final output = io.out.toString();
      expect(output, contains('CodeMie sign-in method'));
      expect(output, contains('JWT token:'));
      final entry = registry.find('codemie.lab.epam.com');
      expect(entry, isNotNull);
      expect(entry!.project, 'demo');
    });

    test('bare /provider codemie cancels on Ctrl-C, rejects a non-http '
        'URL, and https-defaults a bare host (gh-1809 AC1)', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final cli = cliFor(fake.call);
      final run = cli.run();

      io.sendLine('/provider codemie');
      await waitForIt(() => io.out.toString().contains('CodeMie URL ['));
      io.interrupt(); // cancel at the URL prompt
      await waitForIt(
        () => io.out.toString().contains('CodeMie setup cancelled'),
      );

      // Each restart re-waits on a FRESH prompt (output grown past the
      // snapshot) — the earlier flow's identical prompt text must not
      // satisfy the wait and desync the scripted lines.
      var before = io.out.toString().length;
      io.sendLine('/provider codemie');
      await waitForIt(
        () =>
            io.out.toString().length > before &&
            io.out.toString().contains('CodeMie URL ['),
      );
      io.sendLine('ftp://nope');
      await waitForIt(
        () => io.out.toString().contains('invalid CodeMie URL: ftp://nope'),
      );

      // A scheme-less host is accepted — https is assumed.
      before = io.out.toString().length;
      io.sendLine('/provider codemie');
      await waitForIt(
        () =>
            io.out.toString().length > before &&
            io.out.toString().contains('CodeMie URL ['),
      );
      io.sendLine('codie.myorg.com');
      // Wait for the picker's line prompt (same sync block as the
      // interrupt listener) — interrupting on the title alone races the
      // prompt install and the Ctrl-C is lost.
      await waitForIt(() => io.out.toString().contains('type a number:'));
      io.interrupt(); // end the flow — the URL normalization was the point
      // The interrupt rides the broadcast controller's async delivery —
      // one pump before asserting keeps this deterministic.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await waitForIt(
        () => io.out.toString().contains('CodeMie setup cancelled'),
      );
      io.sendLine('/exit');
      await run;
    });

    test('bare /provider codemie accepts a custom org URL end-to-end '
        '(gh-1809 AC1)', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final registry = CustomProviderRegistry([]);
      final seenUrls = <String>[];
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        customProviders: registry,
        codeMieSsoAuthenticateFn: (url, onStatus) async {
          seenUrls.add(url);
          return CodeMieSsoCredentials(
            cookies: const {'_oauth2_proxy': 'corp-val'},
            apiUrl: 'https://codie.corp.example.com/code-assistant-api',
            expiresAt: 9999999999999,
          );
        },
        codeMieGuidedSetupFn: (apiBase, cookie, pickOption, askLine) async =>
            'corp-model-1',
      );
      final run = cli.run();

      io.sendLine('/provider codemie');
      await waitForIt(() => io.out.toString().contains('CodeMie URL ['));
      io.sendLine('https://codie.corp.example.com');
      await waitForIt(
        () => io.out.toString().contains('CodeMie sign-in method'),
      );
      io.sendLine('1'); // Browser SSO
      await waitForIt(
        () => io.out.toString().contains(
          'provider name [codie.corp.example.com]',
        ),
      );
      io.sendLine('');
      await waitForIt(() => io.out.toString().contains('saved provider'));
      io.sendLine('/exit');
      await run;

      expect(seenUrls, ['https://codie.corp.example.com']);
      final entry = registry.find('codie.corp.example.com');
      expect(entry, isNotNull);
      expect(
        entry!.baseUrl,
        'https://codie.corp.example.com/code-assistant-api/v1',
      );
    });

    test('JWT re-login to an existing entry leads with the keep-current '
        'row (gh-1809 AC2/AC5)', () async {
      final fake = FakeStreamFunction([textTurn('ok')]);
      final jwtToken = _makeJwtToken(exp: 9999999999);
      final store = FakeSecureKeyStore()
        ..map['FA_KEY_CODEMIE_LAB_EPAM_COM'] = jwtToken;
      final cache = SecureKeyCache(store);
      await cache.probe();
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'codemie.lab.epam.com',
          apiType: 'openai',
          baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
          modelId: 'codemie-model-jwt',
          keyName: 'FA_KEY_CODEMIE_LAB_EPAM_COM',
          authMethod: CustomProviderAuthMethod.jwt,
        ),
      ]);
      final cli = cliFor(
        fake.call,
        envVarValue: (_) => null,
        secureKeys: cache,
        customProviders: registry,
        modelsHttpClient: _codeMieJwtMockClient(jwtToken),
      );
      final run = cli.run();

      io.sendLine(
        '/provider codemie jwt https://codemie.lab.epam.com '
        '$jwtToken',
      );
      // A re-login (existing entry, no project yet) keeps the current
      // MODEL — the label drops the project half.
      await waitForIt(() => io.out.toString().contains('keep current model'));
      io.sendLine('1');
      await waitForIt(
        () =>
            io.out.toString().contains('provider name [codemie.lab.epam.com]'),
      );
      io.sendLine('');
      await waitForIt(() => io.out.toString().contains('saved provider'));
      io.sendLine('/exit');
      await run;

      expect(registry.entries, hasLength(1));
      expect(registry.entries.single.modelId, 'codemie-model-jwt');
      expect(registry.entries.single.project, isNull);
      // The keep pick skipped the model fetch — no model picker ran.
      expect(io.out.toString(), isNot(contains('fetching CodeMie models...')));
    });

    test(
      'selecting a saved CodeMie JWT provider switches with Bearer auth',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final jwtToken = _makeJwtToken(exp: 9999999999);
        final store = FakeSecureKeyStore();
        final cache = SecureKeyCache(store);
        await cache.probe();
        await cache.save('FA_KEY_CODEMIE_LAB_EPAM_COM', jwtToken);
        final registry = CustomProviderRegistry([
          CustomProviderEntry(
            name: 'codemie.lab.epam.com',
            apiType: 'openai',
            baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
            modelId: 'codemie-model-jwt',
            keyName: 'FA_KEY_CODEMIE_LAB_EPAM_COM',
            authMethod: CustomProviderAuthMethod.jwt,
          ),
        ]);
        final cli = cliFor(
          fake.call,
          envVarValue: (_) => null,
          secureKeys: cache,
          customProviders: registry,
        );
        final run = cli.run();

        io.sendLine('/provider codemie.lab.epam.com');
        await waitForIt(
          () => io.out.toString().contains('switched provider to openai'),
        );
        io.sendLine('/exit');
        await run;

        expect(cli.agent.state.model.id, 'codemie-model-jwt');
        expect(cli.agent.state.model.headers, isNot(contains('cookie')));
      },
    );

    test(
      'selecting a saved CodeMie JWT provider with an expired token reports expiry',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final jwtToken = _makeJwtToken(exp: 1);
        final store = FakeSecureKeyStore();
        final cache = SecureKeyCache(store);
        await cache.probe();
        await cache.save('FA_KEY_CODEMIE_LAB_EPAM_COM', jwtToken);
        final registry = CustomProviderRegistry([
          CustomProviderEntry(
            name: 'codemie.lab.epam.com',
            apiType: 'openai',
            baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
            modelId: 'codemie-model-jwt',
            keyName: 'FA_KEY_CODEMIE_LAB_EPAM_COM',
            authMethod: CustomProviderAuthMethod.jwt,
          ),
        ]);
        final cli = cliFor(
          fake.call,
          envVarValue: (_) => null,
          secureKeys: cache,
          customProviders: registry,
        );
        final run = cli.run();

        io.sendLine('/provider codemie.lab.epam.com');
        await waitForIt(() => io.out.toString().contains('JWT token expired'));
        io.sendLine('/exit');
        await run;

        expect(cli.agent.state.model.id, isNot('codemie-model-jwt'));
      },
    );

    test(
      'selecting a saved CodeMie JWT provider with a missing token reports it',
      () async {
        final fake = FakeStreamFunction([textTurn('ok')]);
        final registry = CustomProviderRegistry([
          CustomProviderEntry(
            name: 'codemie.lab.epam.com',
            apiType: 'openai',
            baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
            modelId: 'codemie-model-jwt',
            keyName: 'FA_KEY_CODEMIE_LAB_EPAM_COM',
            authMethod: CustomProviderAuthMethod.jwt,
          ),
        ]);
        final cli = cliFor(
          fake.call,
          envVarValue: (_) => null,
          customProviders: registry,
        );
        final run = cli.run();

        io.sendLine('/provider codemie.lab.epam.com');
        await waitForIt(
          () => io.out.toString().contains('CodeMie JWT token missing'),
        );
        io.sendLine('/exit');
        await run;

        expect(cli.agent.state.model.id, isNot('codemie-model-jwt'));
      },
    );
  });

  test('startup restore rides the saved CodeMie project as a header '
      '(gh-1809 AC4)', () async {
    final registry = CustomProviderRegistry([
      CustomProviderEntry(
        name: 'codemie.lab.epam.com',
        apiType: 'openai',
        baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
        modelId: 'gpt-4.1-mini',
        keyName: 'FA_KEY_CODEMIE_LAB_EPAM_COM',
        authMethod: CustomProviderAuthMethod.sso,
        project: 'demo-project',
      ),
    ]);
    const codeMieModel = Model(
      id: 'gpt-4.1-mini',
      api: 'openai-completions',
      provider: 'openai',
      baseUrl: 'https://codemie.lab.epam.com/code-assistant-api/v1',
      contextWindow: 200000,
      maxTokens: 4096,
    );
    final store = FakeSecureKeyStore()
      ..map['FA_KEY_CODEMIE_LAB_EPAM_COM'] = '_oauth2_proxy=abc123';
    final secureKeys = SecureKeyCache(store);
    await secureKeys.preload(['FA_KEY_CODEMIE_LAB_EPAM_COM']);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: codeMieModel,
        apiKey: '',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        customProviders: registry,
        secureKeys: secureKeys,
      ),
      io: io,
    );
    expect(cli.agent.state.model.headers?['x-codemie-project'], 'demo-project');
    expect(cli.agent.state.model.headers?['cookie'], '_oauth2_proxy=abc123');
  });
}

String _makeJwtToken({required int exp}) {
  final header = base64Url.encode(utf8.encode('{"alg":"none"}'));
  final payload = base64Url.encode(utf8.encode('{"exp":$exp}'));
  return '$header.$payload.signature';
}

http.Client _codeMieJwtMockClient(String jwtToken) {
  return http_testing.MockClient((request) async {
    final auth = request.headers['authorization'];
    if (auth == null || !auth.endsWith(jwtToken)) {
      return http.Response('Unauthorized', 401);
    }
    // Exact paths — a doubled /v1 segment can never match (gh-1809 r2).
    final path = request.url.path;
    if (path == '/code-assistant-api/v1/user') {
      return http.Response(
        jsonEncode({
          'applications': ['demo'],
        }),
        200,
      );
    }
    if (path == '/code-assistant-api/v1/llm_models') {
      return http.Response(
        jsonEncode([
          {'id': 'codemie-model-jwt'},
        ]),
        200,
      );
    }
    return http.Response('Not found: ${request.url}', 404);
  });
}

/// The CodeMie SSO (cookie-auth) backend: `/v1/user` with two projects
/// ([userStatus] injects the broken-response case) and `/llm_models`.
/// Exact paths — a doubled /v1 segment can never match (gh-1809 r2).
http.Client _codeMieSsoMockClient({int userStatus = 200}) {
  return http_testing.MockClient((request) async {
    if (request.headers['cookie'] == null) {
      return http.Response('Unauthorized', 401);
    }
    final path = request.url.path;
    if (path == '/code-assistant-api/v1/user') {
      if (userStatus != 200) {
        return http.Response(
          'CodeMie user info failed ($userStatus)',
          userStatus,
        );
      }
      return http.Response(
        jsonEncode({
          'applications': ['demo-project'],
          'applications_admin': ['admin-project'],
        }),
        200,
      );
    }
    if (path == '/code-assistant-api/v1/llm_models') {
      return http.Response(
        jsonEncode([
          {'id': 'codemie-model-1'},
          {'id': 'codemie-model-2'},
        ]),
        200,
      );
    }
    return http.Response('Not found: ${request.url}', 404);
  });
}

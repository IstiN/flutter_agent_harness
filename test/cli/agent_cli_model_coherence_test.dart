// IT-1..IT-4 / REG-1..REG-3 (gh-178): the coherence gates driven against
// the CLI — typed, numbered and picker switch paths over a ≥2-provider
// candidate space with overlapping-looking ids, the request-build refusal
// with zero requests issued, the restore gate, and the full 2026-10-22
// incident replay.
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() {
    io.close();
  });

  /// The incident-shaped fixture: a saved Copilot entry (enterprise
  /// endpoint, its own key slot) is ACTIVE, and kimi is reachable as an
  /// env-keyed catalog provider (KIMI_API_KEY in the environment) whose
  /// `/models` answer overlaps nothing with the copilot entry's.
  Future<(AgentCli, FakeStreamFunction)> incidentCli({
    String? kimiEnvKey,
    String entryApiType = 'copilot',
    String bootProvider = 'copilot',
    bool rideCatalogStream = false,
    Future<List<String>> Function(String baseUrl, {required String apiKey})?
    modelsFetcher,
    Model? bootModel,
  }) async {
    final store = FakeSecureKeyStore()
      ..map['FA_KEY_COPILOT_ACME'] = 'copilot-key';
    // KIMI's key rides the ENVIRONMENT (env-keyed catalog provider, no
    // saved entry) — a store twin would make the env value non-genuine
    // and hide the kimi rows from the picker.
    final envVars = <String, String>{'KIMI_API_KEY': ?kimiEnvKey};
    final cache = SecureKeyCache(store);
    await cache.preload(store.map.keys.toList());
    final registry = CustomProviderRegistry([
      CustomProviderEntry(
        name: 'copilot-acme',
        apiType: entryApiType,
        baseUrl: 'https://api.enterprise.githubcopilot.com',
        keyName: 'FA_KEY_COPILOT_ACME',
        modelId: 'gemini-4-argon',
      ),
    ]);
    final fake = FakeStreamFunction([
      textTurn('ok-1'),
      textTurn('ok-2'),
      textTurn('ok-3'),
      textTurn('ok-4'),
      textTurn('ok-5'),
    ]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model:
            bootModel ??
            Model(
              id: 'gemini-4-argon',
              api: 'openai-completions',
              provider: bootProvider,
              baseUrl: 'https://api.enterprise.githubcopilot.com',
              contextWindow: 1000000,
              maxTokens: 32768,
            ),
        apiKey: 'copilot-key',
        env: env,
        sessionRoot: '/sessions',
        envVarValue: (name) => envVars[name] ?? store.map[name],
        envVarIsSet: (name) =>
            envVars.containsKey(name) || store.map.containsKey(name),
        secureKeys: cache,
        customProviders: registry,
        activeCustomName: 'copilot-acme',
        modelsFetcher: modelsFetcher,
        providerKind: 'copilot',
        // rideCatalogStream: the message turn flows through the REAL
        // stream factory (`_catalogStreamFunction` → the G2 wrapper →
        // the fake inner), so the test observes the wiring a switch
        // actually builds.
        catalogStreamOverride: rideCatalogStream
            ? (kind, key) => fake.call
            : null,
      ),
      io: io,
      streamFunction: rideCatalogStream ? null : fake.call,
    );
    return (cli, fake);
  }

  // Returns the UNAWAITED run future (await would flatten and deadlock
  // against the /exit each test sends before awaiting it).
  Future<Future<void>> boot(AgentCli cli) {
    final run = cli.run();
    return waitForIt(
      () => !cli.isBusy && io.out.toString().isNotEmpty,
    ).then((_) => run);
  }

  group('IT-1: every switch path resolves the whole triple (AC1)', () {
    test('typed `/model kimi/kimi-for-coding` switches provider + endpoint '
        '+ key family, not just the id', () async {
      final fetches = <String>[];
      final (cli, fake) = await incidentCli(
        kimiEnvKey: 'kimi-key',
        modelsFetcher: (baseUrl, {required apiKey}) async {
          fetches.add(baseUrl);
          return baseUrl.contains('kimi')
              ? const ['kimi-for-coding', 'k3-256k']
              : const ['gemini-4-argon'];
        },
      );
      final run = await boot(cli);

      io.sendLine('/model kimi/kimi-for-coding');
      await waitForIt(() => cli.agent.state.model.provider == 'kimi');
      io.sendLine('/exit');
      await run;

      // The whole quadruple moved (provider + endpoint + key family).
      expect(cli.agent.state.model.id, 'kimi-for-coding');
      expect(cli.agent.state.model.provider, 'kimi');
      expect(cli.agent.state.model.baseUrl, 'https://api.kimi.com/coding/v1');
    });

    test(
      'numbered pick of a cross-provider row moves the whole triple',
      () async {
        final (cli, _) = await incidentCli(
          kimiEnvKey: 'kimi-key',
          entryApiType: 'openai',
          bootProvider: 'openai',
          modelsFetcher: (baseUrl, {required apiKey}) async =>
              baseUrl.contains('kimi')
              ? const ['kimi-for-coding', 'k3-256k']
              : const ['gemini-4-argon'],
        );
        final run = await boot(cli);

        io.sendLine('/models');
        await waitForIt(
          () => io.out.toString().contains('kimi/kimi-for-coding'),
        );
        final output = io.out.toString();
        final kimiRow = output
            .split('\n')
            .firstWhere(
              (line) => line.contains('kimi/kimi-for-coding'),
              orElse: () => fail('no kimi row listed:\n$output'),
            );
        final number = RegExp(
          r'(\d+)\)\s+kimi/kimi-for-coding',
        ).firstMatch(kimiRow)?.group(1);
        expect(number, isNotNull, reason: 'unparsed listing row: $kimiRow');
        io.sendLine('/model $number');
        await waitForIt(
          () =>
              cli.agent.state.model.provider == 'kimi' &&
              cli.agent.state.model.id == 'kimi-for-coding',
        );
        io.sendLine('/exit');
        await run;

        expect(cli.agent.state.model.baseUrl, 'https://api.kimi.com/coding/v1');
      },
    );

    test('picker pick (provider|model key) moves the whole triple', () async {
      final (cli, _) = await incidentCli(
        kimiEnvKey: 'kimi-key',
        modelsFetcher: (baseUrl, {required apiKey}) async =>
            baseUrl.contains('kimi')
            ? const ['kimi-for-coding', 'k3-256k']
            : const ['gemini-4-argon'],
      );
      final run = await boot(cli);

      await cli.tuiSelectModelForTest('kimi|kimi-for-coding');
      await waitForIt(
        () =>
            cli.agent.state.model.provider == 'kimi' &&
            cli.agent.state.model.id == 'kimi-for-coding',
      );
      io.sendLine('/exit');
      await run;

      expect(cli.agent.state.model.baseUrl, 'https://api.kimi.com/coding/v1');
    });

    test(
      'a same-provider pick keeps the current triple (no provider hop)',
      () async {
        final (cli, _) = await incidentCli(
          kimiEnvKey: 'kimi-key',
          modelsFetcher: (baseUrl, {required apiKey}) async =>
              baseUrl.contains('kimi')
              ? const ['kimi-for-coding']
              : const ['gemini-4-argon', 'gpt-5-copilot'],
        );
        final run = await boot(cli);

        io.sendLine('/model copilot-acme/gpt-5-copilot');
        await waitForIt(() => cli.agent.state.model.id == 'gpt-5-copilot');
        io.sendLine('/exit');
        await run;

        expect(cli.agent.state.model.provider, 'copilot');
        expect(
          cli.agent.state.model.baseUrl,
          'https://api.enterprise.githubcopilot.com',
        );
      },
    );
  });

  group('IT-1/E1: provider removed after listing refuses', () {
    test('a cross-provider pick of an unresolvable provider refuses and '
        'applies no partial triple', () async {
      final (cli, _) = await incidentCli(
        kimiEnvKey: 'kimi-key',
        modelsFetcher: (baseUrl, {required apiKey}) async =>
            baseUrl.contains('kimi')
            ? const ['kimi-for-coding']
            : const ['gemini-4-argon'],
      );
      final run = await boot(cli);

      // E1 is a LISTING-vs-pick race: the row arrives as a STRUCTURED
      // (provider, model) pair whose provider no longer resolves. A TYPED
      // unknown prefix stays a coherent same-provider pasthrough (an
      // OpenRouter-style vendor id) — covered by the UT-1 parser tests.
      await cli.tuiSelectModelForTest('gone-provider|kimi-for-coding');
      await waitForIt(
        () => io.out.toString().contains('model coherence refusal'),
      );
      io.sendLine('/exit');
      await run;

      expect(io.out.toString(), contains('gone-provider'));
      // No partial triple: the active model is untouched.
      expect(cli.agent.state.model.id, 'gemini-4-argon');
      expect(cli.agent.state.model.provider, 'copilot');
    });
  });

  group('IT-1/E3: cross-provider pick with no target key refuses up front', () {
    test(
      'the refusal names the TARGET key slot; no request is built',
      () async {
        // A saved kimi entry whose key slot has no value: listed, pickable,
        // but the switch would bake an empty key — refused up front.
        final store = FakeSecureKeyStore()
          ..map['FA_KEY_COPILOT_ACME'] = 'copilot-key';
        final cache = SecureKeyCache(store);
        final registry = CustomProviderRegistry([
          CustomProviderEntry(
            name: 'copilot-acme',
            apiType: 'copilot',
            baseUrl: 'https://api.enterprise.githubcopilot.com',
            keyName: 'FA_KEY_COPILOT_ACME',
            modelId: 'gemini-4-argon',
          ),
          CustomProviderEntry(
            name: 'kimi-act',
            apiType: 'openai',
            baseUrl: 'https://api.kimi.com/coding/v1',
            keyName: 'FA_KEY_KIMI_ACT',
            modelId: 'kimi-for-coding',
          ),
        ]);
        final fake = FakeStreamFunction([textTurn('ok-1'), textTurn('ok-2')]);
        final cli = AgentCli(
          config: AgentCliConfig(
            model: const Model(
              id: 'gemini-4-argon',
              api: 'openai-completions',
              provider: 'copilot',
              baseUrl: 'https://api.enterprise.githubcopilot.com',
              contextWindow: 1000000,
              maxTokens: 32768,
            ),
            apiKey: 'copilot-key',
            env: env,
            sessionRoot: '/sessions',
            envVarValue: (name) => store.map[name],
            envVarIsSet: (name) => store.map.containsKey(name),
            secureKeys: cache,
            customProviders: registry,
            providerKind: 'copilot',
          ),
          io: io,
          streamFunction: fake.call,
        );
        final run = await boot(cli);

        io.sendLine('/model kimi-act/kimi-for-coding');
        await waitForIt(
          () => io.out.toString().contains('model coherence refusal'),
        );
        io.sendLine('/exit');
        await run;

        final output = io.out.toString();
        expect(output, contains('/key set FA_KEY_KIMI_ACT'));
        expect(output, contains('kimi-act'));
        // The switch never happened — no partial triple, no keyless wiring.
        expect(cli.agent.state.model.provider, 'copilot');
        expect(fake.calls, 0);
      },
    );
  });

  group('IT-2/REG-2: the request-build gate refuses before any socket', () {
    test('a forced mixed active model surfaces the refusal and issues ZERO '
        'requests (AC2, AC4)', () async {
      // The G2 guard wraps the catalog stream factory, so this test rides
      // catalogStreamOverride instead of an injected streamFunction.
      final store = FakeSecureKeyStore()..map['KIMI_API_KEY'] = 'kimi-key';
      final cache = SecureKeyCache(store);
      final fake = FakeStreamFunction([textTurn('should-never-run')]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: const Model(
            id: 'kimi-for-coding',
            api: 'openai-completions',
            provider: 'copilot',
            baseUrl: 'https://api.enterprise.githubcopilot.com',
            contextWindow: 1000000,
            maxTokens: 32768,
          ),
          // The incident's mixed boot wiring: copilot kind + a kimi key.
          apiKey: 'kimi-key',
          env: env,
          sessionRoot: '/sessions',
          envVarValue: (name) => store.map[name],
          envVarIsSet: (name) => store.map.containsKey(name),
          secureKeys: cache,
          providerKind: 'copilot',
          catalogStreamOverride: (kind, key) => fake.call,
        ),
        io: io,
      );
      final run = await boot(cli);

      io.sendLine('hello');
      await waitForIt(() => !cli.isBusy);
      io.sendLine('/exit');
      await run;

      expect(fake.calls, 0, reason: 'no request may leave the process');
      expect(io.out.toString(), contains('model coherence refusal'));
      expect(io.out.toString(), contains('/provider copilot'));
    });

    test('a coherent model streams through the same wrapper (no false '
        'refusal)', () async {
      final store = FakeSecureKeyStore()..map['KIMI_API_KEY'] = 'kimi-key';
      final cache = SecureKeyCache(store);
      final fake = FakeStreamFunction([textTurn('streams-fine')]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: const Model(
            id: 'kimi-for-coding',
            api: 'openai-completions',
            provider: 'kimi',
            baseUrl: 'https://api.kimi.com/coding/v1',
            contextWindow: 200000,
            maxTokens: 16384,
          ),
          apiKey: 'kimi-key',
          env: env,
          sessionRoot: '/sessions',
          envVarValue: (name) => store.map[name],
          envVarIsSet: (name) => store.map.containsKey(name),
          secureKeys: cache,
          providerKind: 'openai-completions',
          catalogStreamOverride: (kind, key) => fake.call,
        ),
        io: io,
      );
      final run = await boot(cli);

      io.sendLine('hello');
      await waitForIt(() => !cli.isBusy && fake.calls == 1);
      io.sendLine('/exit');
      await run;

      expect(fake.calls, 1);
      expect(io.out.toString(), contains('streams-fine'));
      expect(io.out.toString(), isNot(contains('model coherence refusal')));
    });
  });

  group('IT-4/REG-2: the 2026-10-22 incident replay fails closed (AC4)', () {
    test(
      'mixed boot + picker pick of kimi-for-coding + message never '
      'produces a copilot-endpoint request carrying kimi-for-coding',
      () async {
        final (cli, fake) = await incidentCli(
          kimiEnvKey: 'kimi-key',
          rideCatalogStream: true,
          modelsFetcher: (baseUrl, {required apiKey}) async =>
              baseUrl.contains('kimi')
              ? const ['kimi-for-coding', 'k3-256k']
              : const ['gemini-4-argon'],
        );
        final run = await boot(cli);

        // The incident's pick, via the picker's cross-provider key.
        await cli.tuiSelectModelForTest('kimi|kimi-for-coding');
        await waitForIt(() => cli.agent.state.model.id == 'kimi-for-coding');

        // REG-3 (AC5): status line, transcript record and the live model
        // agree on the provider after the switch.
        expect(cli.statusProviderLabelForTest(), 'kimi');
        final sessionFile = await _lastModelChangeProvider(env);
        expect(sessionFile, 'kimi');

        io.sendLine('are you coherent?');
        await waitForIt(() => !cli.isBusy && fake.calls == 1);
        io.sendLine('/exit');
        await run;

        // The wire carried the kimi quadruple — never a copilot-endpoint
        // request with a kimi model id.
        expect(fake.models.single.provider, 'kimi');
        expect(fake.models.single.baseUrl, 'https://api.kimi.com/coding/v1');
        expect(fake.models.single.id, 'kimi-for-coding');
      },
    );
  });

  group('rework: review-thread coverage (gh-1788 rework)', () {
    // Thread PRRT_kwDOTXdlLc6vbU_u (BLOCKING): the G2 refusal ErrorEvent
    // must be TERMINAL — the finalized snapshot claims `StopReason.error`
    // (the pushStreamErrorEvent house contract), so the empty-completion
    // classifier verdicts abortedOrError and the one-shot "continue"
    // nudge never fires a second refusal cycle.
    test('a refused turn records stopReason error and fires no '
        'continuation nudge', () async {
      final store = FakeSecureKeyStore()..map['KIMI_API_KEY'] = 'kimi-key';
      final cache = SecureKeyCache(store);
      final fake = FakeStreamFunction([textTurn('should-never-run')]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: const Model(
            id: 'kimi-for-coding',
            api: 'openai-completions',
            provider: 'copilot',
            baseUrl: 'https://api.enterprise.githubcopilot.com',
            contextWindow: 1000000,
            maxTokens: 32768,
          ),
          apiKey: 'kimi-key',
          env: env,
          sessionRoot: '/sessions',
          envVarValue: (name) => store.map[name],
          envVarIsSet: (name) => store.map.containsKey(name),
          secureKeys: cache,
          providerKind: 'copilot',
          catalogStreamOverride: (kind, key) => fake.call,
        ),
        io: io,
      );
      final run = await boot(cli);

      io.sendLine('hello');
      await waitForIt(() => !cli.isBusy);
      io.sendLine('/exit');
      await run;

      expect(fake.calls, 0, reason: 'no request may leave the process');
      final output = io.out.toString();
      expect(output, contains('model coherence refusal'));
      final messages = cli.agent.state.messages;
      final last = messages.last;
      expect(last, isA<AssistantMessage>());
      final refusalMessage = last as AssistantMessage;
      expect(
        refusalMessage.stopReason,
        StopReason.error,
        reason:
            'a coherence refusal is a terminal error stop, never a '
            'clean empty completion',
      );
      expect(refusalMessage.errorMessage, isNotNull);
      expect(
        messages.whereType<UserMessage>().map((m) => m.content),
        isNot(contains(emptyContinuationNudge)),
        reason: 'the auto-continue nudge must not ride a refused turn',
      );
    });

    // Thread PRRT_kwDOTXdlLc6vbVCd (IMPORTANT): the backstop re-parses
    // with a narrower predicate than the router — a pick the router
    // resolved SAME-provider (active-identity head + a nested
    // vendor-prefixed id the cache does not list) must switch, not be
    // re-refused.
    test('a nested vendor-prefixed id behind the ACTIVE identity head '
        'switches instead of being re-refused by the backstop', () async {
      final (cli, _) = await incidentCli(
        kimiEnvKey: 'kimi-key',
        modelsFetcher: (baseUrl, {required apiKey}) async =>
            baseUrl.contains('kimi')
            ? const ['kimi-for-coding', 'k3-256k']
            : const ['gemini-4-argon'],
      );
      final run = await boot(cli);

      io.sendLine('/model copilot-acme/openai/gpt-4o');
      await waitForIt(
        () =>
            io.out.toString().contains('switched model to') ||
            io.out.toString().contains('model coherence refusal'),
      );
      io.sendLine('/exit');
      await run;

      // The router's rule 1 verdict (head == active identity) stands: a
      // same-provider pick of the full vendor-prefixed id.
      expect(io.out.toString(), contains('switched model to openai/gpt-4o'));
      expect(io.out.toString(), isNot(contains('model coherence refusal')));
      expect(cli.agent.state.model.id, 'openai/gpt-4o');
      expect(cli.agent.state.model.provider, 'copilot');
      expect(
        cli.agent.state.model.baseUrl,
        'https://api.enterprise.githubcopilot.com',
      );
    });

    // Thread PRRT_kwDOTXdlLc6vbVEo (2): the `_switchModel` backstop
    // refusal, driven DIRECTLY (a raw cross-provider shape, no router
    // resolution) — the last-resort guard pins the invariant.
    test('the backstop refuses a forced cross-provider shape and leaves '
        'the state untouched', () async {
      final (cli, fake) = await incidentCli(
        kimiEnvKey: 'kimi-key',
        modelsFetcher: (baseUrl, {required apiKey}) async =>
            baseUrl.contains('kimi')
            ? const ['kimi-for-coding', 'k3-256k']
            : const ['gemini-4-argon'],
      );
      final run = await boot(cli);

      await cli.switchModelUnresolvedForTest('kimi/kimi-for-coding');
      await waitForIt(
        () => io.out.toString().contains('model coherence refusal'),
      );
      io.sendLine('/exit');
      await run;

      expect(
        io.out.toString(),
        contains('"/model" reuse cannot carry a cross-provider pick'),
      );
      expect(io.out.toString(), contains('/provider'));
      // Nothing moved: the triple, the wiring, no request.
      expect(cli.agent.state.model.id, 'gemini-4-argon');
      expect(cli.agent.state.model.provider, 'copilot');
      expect(fake.calls, 0);
    });

    // Thread PRRT_kwDOTXdlLc6vbVEo (1): the WIRED G3 note branch — a
    // re-apply restore whose persisted triple fails the binding
    // validation keeps the boot-coherent model with the loud note.
    test('a persisted triple that fails the binding boots on the launch '
        'model with the loud G3 note and unchanged wiring', () async {
      Future<AgentCli> factory(FakeCliIO cliIo, String sessionName) async {
        final cli = AgentCli(
          config: AgentCliConfig(
            model: Model(
              id: 'start-model',
              api: 'test-api',
              provider: 'test-provider',
              baseUrl: 'https://example.test',
              contextWindow: 100000,
              maxTokens: 4096,
            ),
            apiKey: '',
            env: env,
            sessionRoot: '/sessions',
            sessionName: sessionName,
          ),
          io: cliIo,
          streamFunction: fakeTextTurn,
        );
        return cli;
      }

      // Seed the session the second boot will resume.
      final seedIo = FakeCliIO();
      final first = await factory(seedIo, 'g3-note');
      final run1 = first.run();
      seedIo.sendLine('hi');
      await waitForIt(() => !first.isBusy && seedIo.out.toString().isNotEmpty);
      seedIo.sendLine('/exit');
      await run1;
      await seedIo.close();

      // A triple that BUILDS (buildCliDefaultModel resolves anthropic and
      // builds any id) but FAILS the validating binding constructor: a
      // gpt id on the family-exclusive anthropic endpoint.
      await saveFolderModelState(
        env,
        sessionsRoot: '/sessions',
        cwd: '/work',
        providerKind: 'anthropic',
        modelId: 'gpt-4o',
        baseUrl: null,
      );

      final g3Io = FakeCliIO();
      final second = await factory(g3Io, 'g3-note');
      final streamBefore = second.agent.streamFunction;
      final run2 = second.run();
      await waitForIt(() => g3Io.out.toString().contains('persisted model'));
      g3Io.sendLine('/exit');
      await run2;
      await g3Io.close();

      final out = g3Io.out.toString();
      // The loud note names the conflicted fields and the repair.
      expect(out, contains('model coherence refusal'));
      expect(
        out,
        contains(
          'persisted model "gpt-4o" does not form a valid binding with '
          'provider "anthropic"',
        ),
      );
      expect(out, contains('/provider'));
      // The kept model is the boot-coherent one (OQ3 repair semantics).
      expect(out, contains('keeping start-model'));
      expect(out, isNot(contains('restored gpt-4o')));
      // The boot model and the wiring are untouched.
      expect(second.agent.state.model.id, 'start-model');
      expect(second.agent.state.model.provider, 'test-provider');
      expect(second.agent.state.model.baseUrl, 'https://example.test');
      expect(identical(second.agent.streamFunction, streamBefore), isTrue);
    });
  });

  // The CRAP ratchet CI red (gh-1788 validation): `_foreignFamilyHoldsKey`
  // measured CC-9 at 30.8% coverage — the saved-entry (custom registry)
  // half of the scan had no test reaching it. These drive the three
  // saved-family verdicts end to end: holds the wiring key → refusal,
  // holds a different key → no false refusal, keyless slot → never
  // judged.
  group('rework: the saved-family key check (G2 conservative arm, gh-1788)',
  () {
    /// The mixed-boot fixture with SAVED entries instead of an env-keyed
    /// catalog provider: the copilot entry is active, and a kimi saved
    /// entry exists whose key slot [kimiKey] may or may not hold the key
    /// the session wiring carries.
    Future<(AgentCli, FakeStreamFunction)> savedFamilyCli({
      String? kimiKey,
      String? kimiKeyName = 'FA_KEY_KIMI_ACT',
    }) async {
      final store = FakeSecureKeyStore()
        ..map['FA_KEY_COPILOT_ACME'] = 'copilot-key';
      if (kimiKey != null && kimiKeyName != null) {
        store.map[kimiKeyName] = kimiKey;
      }
      final cache = SecureKeyCache(store);
      await cache.preload(store.map.keys.toList());
      final registry = CustomProviderRegistry([
        CustomProviderEntry(
          name: 'copilot-acme',
          apiType: 'copilot',
          baseUrl: 'https://api.enterprise.githubcopilot.com',
          keyName: 'FA_KEY_COPILOT_ACME',
          modelId: 'gemini-4-argon',
        ),
        CustomProviderEntry(
          name: 'kimi-act',
          apiType: 'openai',
          baseUrl: 'https://api.kimi.com/coding/v1',
          keyName: kimiKeyName,
          modelId: 'kimi-for-coding',
        ),
      ]);
      final fake = FakeStreamFunction([textTurn('streams-through')]);
      final cli = AgentCli(
        config: AgentCliConfig(
          model: const Model(
            id: 'kimi-for-coding',
            api: 'openai-completions',
            provider: 'copilot',
            baseUrl: 'https://api.enterprise.githubcopilot.com',
            contextWindow: 1000000,
            maxTokens: 32768,
          ),
          // The incident's mixed boot wiring: copilot kind + a kimi key.
          apiKey: '[REDACTED:Sensitive Value]',
          env: env,
          sessionRoot: '/sessions',
          envVarValue: (name) => store.map[name],
          envVarIsSet: (name) => store.map.containsKey(name),
          secureKeys: cache,
          customProviders: registry,
          activeCustomName: 'copilot-acme',
          providerKind: 'copilot',
          catalogStreamOverride: (kind, key) => fake.call,
        ),
        io: io,
      );
      return (cli, fake);
    }

    test('a saved foreign family whose key slot holds the WIRING key '
        'refuses the request', () async {
      final (cli, fake) = await savedFamilyCli(kimiKey: 'kimi-key');
      final run = await boot(cli);

      io.sendLine('hello');
      await waitForIt(() => !cli.isBusy);
      io.sendLine('/exit');
      await run;

      expect(fake.calls, 0, reason: 'no request may leave the process');
      final output = io.out.toString();
      expect(output, contains('model coherence refusal'));
      expect(output, contains('DIFFERENT provider family'));
      // No partial anything: the boot triple is untouched.
      expect(cli.agent.state.model.provider, 'copilot');
      expect(cli.agent.state.model.id, 'kimi-for-coding');
    });

    test('a saved foreign family holding a DIFFERENT key never refuses '
        '(the conservative arm)', () async {
      final (cli, fake) = await savedFamilyCli(kimiKey: 'other-key');
      final run = await boot(cli);

      io.sendLine('hello');
      await waitForIt(() => !cli.isBusy && fake.calls == 1);
      io.sendLine('/exit');
      await run;

      expect(fake.calls, 1);
      expect(io.out.toString(), contains('streams-through'));
      expect(io.out.toString(), isNot(contains('model coherence refusal')));
    });

    test('a KEYLESS saved entry is never judged (no slot, no verdict)',
        () async {
      final (cli, fake) = await savedFamilyCli(kimiKey: null, kimiKeyName: null);
      final run = await boot(cli);

      io.sendLine('hello');
      await waitForIt(() => !cli.isBusy && fake.calls == 1);
      io.sendLine('/exit');
      await run;

      expect(fake.calls, 1);
      expect(io.out.toString(), contains('streams-through'));
      expect(io.out.toString(), isNot(contains('model coherence refusal')));
    });
  });
}

/// A one-turn fake stream serving a single text completion (the G3 fixture
/// shares the shape of the restore-suite helper).
StreamFunction get fakeTextTurn => (model, context, {cancelToken}) {
  final stream = AssistantMessageEventStream();
  stream.push(
    DoneEvent(
      reason: StopReason.stop,
      message: AssistantMessage(
        content: [TextContent(text: 'ok')],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: Usage.zero,
        stopReason: StopReason.stop,
        timestamp: DateTime.now(),
      ),
    ),
  );
  stream.end();
  return stream;
};

/// The provider named by the LAST `model_change` record under the session
/// root — the transcript half of the REG-3 agreement.
Future<String?> _lastModelChangeProvider(MemoryExecutionEnv env) async {
  String? provider;
  Future<void> walk(String dir) async {
    final listing = await env.listDir(dir);
    for (final info in listing.valueOrNull ?? const <FileInfo>[]) {
      final path = '$dir/${info.name}';
      if (info.kind == FileKind.directory) {
        await walk(path);
      } else if (info.name.endsWith('.jsonl')) {
        final text = (await env.readTextFile(path)).valueOrNull;
        for (final line in (text ?? '').split('\n')) {
          if (!line.contains('"model_change"')) continue;
          try {
            final record = jsonDecode(line) as Map<String, dynamic>;
            provider = record['provider'] as String?;
          } on FormatException {
            // skip torn line
          }
        }
      }
    }
  }

  await walk('/sessions');
  return provider;
}

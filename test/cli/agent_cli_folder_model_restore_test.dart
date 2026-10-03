import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Per-folder model memory across session switches: the boot applies the
/// LAUNCH folder's saved triple, but a session opened via `--session` (or
/// the /sessions picker) can live in a DIFFERENT folder — its own saved
/// model must win there (user report: a z.ai session reopened as copilot).
void main() {
  late MemoryExecutionEnv env;
  final ios = <FakeCliIO>[];

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    ios.clear();
  });

  tearDown(() async {
    for (final io in ios) {
      await io.close();
    }
  });

  FakeCliIO freshIo() {
    final io = FakeCliIO();
    ios.add(io);
    return io;
  }

  AgentCli cliFactory({required String sessionName, String? modelId}) {
    return AgentCli(
      config: AgentCliConfig(
        model: Model(
          id: modelId ?? 'start-model',
          api: 'test-api',
          provider: 'test-provider',
          baseUrl: 'https://example.test',
          contextWindow: 100000,
          maxTokens: 4096,
        ),
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        sessionName: sessionName,
      ),
      io: freshIo(),
      streamFunction: _singleTextResponse('ok'),
    );
  }

  test(
    'resuming a session applies that folder’s saved model triple',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      // Boot 1: create the session in /work on the launch default.
      final first = cliFactory(sessionName: 'resume-me');
      final firstIo = ios.single;
      final run1 = first.run();
      firstIo.sendLine('hi');
      // A message persists the session; an empty one is deleted on switch.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      firstIo.sendLine('/exit');
      await run1;

      // The folder saves a different provider/model (as a /model switch
      // would): the zai catalog kind keeps the test network-free.
      await saveFolderModelState(
        env,
        sessionsRoot: '/sessions',
        cwd: '/work',
        providerKind: 'zai',
        modelId: 'glm-5.3-flash',
        baseUrl: null,
      );

      // Boot 2: same session, fresh process — the saved triple must win.
      final second = cliFactory(
        sessionName: 'resume-me',
        modelId: 'other-model',
      );
      final secondIo = ios.last;
      final run2 = second.run();
      secondIo.sendLine('/exit');
      await run2;

      expect(second.agent.state.model.id, 'glm-5.3-flash');
      expect(second.providerKind, 'zai');
      expect(
        secondIo.out.toString(),
        contains('restored glm-5.3-flash (zai) from this folder'),
      );
    },
  );

  test(
    'a folder-state restore adopts the saved entry’s authHeader '
    '(issue #964)',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      // Boot 1: create the session on the launch default.
      final first = cliFactory(sessionName: 'gateway');
      final firstIo = ios.single;
      final run1 = first.run();
      firstIo.sendLine('hi');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      firstIo.sendLine('/exit');
      await run1;

      // The folder last used a gateway endpoint whose saved entry declares
      // x-api-key (issue #964): the restore must carry the header.
      await saveFolderModelState(
        env,
        sessionsRoot: '/sessions',
        cwd: '/work',
        providerKind: 'openai-completions',
        modelId: 'bedrock-model',
        baseUrl: 'https://gateway.example.com/v1',
      );

      final second = AgentCli(
        config: AgentCliConfig(
          model: Model(
            id: 'other-model',
            api: 'test-api',
            provider: 'test-provider',
            baseUrl: 'https://example.test',
            contextWindow: 100000,
            maxTokens: 4096,
          ),
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          sessionName: 'gateway',
          customProviders: CustomProviderRegistry([
            CustomProviderEntry(
              name: 'gateway.example.com',
              apiType: 'openai',
              baseUrl: 'https://gateway.example.com/v1',
              modelId: 'bedrock-model',
              authHeader: 'x-api-key',
            ),
          ]),
        ),
        io: freshIo(),
        streamFunction: _singleTextResponse('ok'),
      );
      final secondIo = ios.last;
      final run2 = second.run();
      secondIo.sendLine('/exit');
      await run2;

      expect(second.agent.state.model.id, 'bedrock-model');
      expect(second.agent.state.model.authHeader, 'x-api-key');
    },
  );

  test(
    'a name-shaped folder state restores through the seam (issue #772)',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      final first = cliFactory(sessionName: 'name-shaped');
      final run1 = first.run();
      ios.single.sendLine('hi');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      ios.single.sendLine('/exit');
      await run1;

      // The pre-#772 app shape: the catalog NAME persisted as providerKind.
      await saveFolderModelState(
        env,
        sessionsRoot: '/sessions',
        cwd: '/work',
        providerKind: 'chatgpt',
        modelId: 'gpt-5-codex',
        baseUrl: null,
      );

      // Boot 2: the resume twin must feed the RESOLVED kind into the
      // stream factory — the raw name would throw
      // `Unknown provider kind: chatgpt` at _catalogStreamFunction and
      // persist itself back into the state file.
      final second = cliFactory(
        sessionName: 'name-shaped',
        modelId: 'other-model',
      );
      final secondIo = ios.last;
      final run2 = second.run();
      secondIo.sendLine('/exit');
      await run2;

      expect(second.agent.state.model.id, 'gpt-5-codex');
      expect(second.agent.state.model.provider, 'chatgpt');
      expect(second.providerKind, 'chatgpt-codex');
      expect(
        secondIo.out.toString(),
        isNot(contains('Unknown provider kind')),
      );
      // The state file keeps the name spelling (restore never mutates);
      // the fix is at the seam, not a rewrite.
      final state = await loadFolderModelState(
        env,
        sessionsRoot: '/sessions',
        cwd: '/work',
      );
      expect(state!.providerKind, 'chatgpt');
    },
  );

  test(
    'an explicit launch pin disables the folder restore',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      final first = cliFactory(sessionName: 'pinned');
      final run1 = first.run();
      ios.single.sendLine('hi');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      ios.single.sendLine('/exit');
      await run1;

      await saveFolderModelState(
        env,
        sessionsRoot: '/sessions',
        cwd: '/work',
        providerKind: 'zai',
        modelId: 'glm-5.3-flash',
        baseUrl: null,
      );

      final second = AgentCli(
        config: AgentCliConfig(
          model: Model(
            id: 'pinned-model',
            api: 'test-api',
            provider: 'test-provider',
            baseUrl: 'https://example.test',
            contextWindow: 100000,
            maxTokens: 4096,
          ),
          apiKey: 'test-key',
          env: env,
          sessionRoot: '/sessions',
          sessionName: 'pinned',
          // --provider/--model on the launch command line.
          folderModelStateApplies: false,
        ),
        io: freshIo(),
        streamFunction: _singleTextResponse('ok'),
      );
      final run2 = second.run();
      ios.last.sendLine('/exit');
      await run2;

      expect(second.agent.state.model.id, 'pinned-model');
    },
  );

  group('provider pin restore (gh-1000)', () {
    const kimiUrl = 'https://api.kimi.com/coding/v1';
    const iraKeyName = 'FA_KEY_API_KIMI_COM_IRA_1';
    const kimiMeKeyName = 'FA_KEY_API_KIMI_COM_KIMI_ME';

    /// Two saved providers sharing ONE modelId and ONE endpoint — the
    /// exact gh-1000 fixture. A first-match-by-endpoint scan picks ira-1.
    CustomProviderRegistry twinRegistry() => CustomProviderRegistry([
      CustomProviderEntry(
        name: 'ira-1',
        apiType: 'kimi',
        baseUrl: kimiUrl,
        modelId: 'k3-256k',
        keyName: iraKeyName,
      ),
      CustomProviderEntry(
        name: 'kimi_me',
        apiType: 'openai',
        baseUrl: kimiUrl,
        modelId: 'k3-256k',
        keyName: kimiMeKeyName,
      ),
    ]);

    Future<void> seedSession(String name) async {
      final first = cliFactory(sessionName: name);
      final run = first.run();
      ios.single.sendLine('hi');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      ios.single.sendLine('/exit');
      await run;
    }

    // Async: the secure cache mirrors the real boot preload (reads hit the
    // snapshot, never live store spawns).
    Future<AgentCli> pinnedCliFactory({
      required String sessionName,
      CustomProviderRegistry? registry,
      FakeSecureKeyStore? store,
    }) async {
      final keyCache = SecureKeyCache(store ?? FakeSecureKeyStore());
      await keyCache.preload(
        store == null ? const <String>[] : store.map.keys.toList(),
      );
      return AgentCli(
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
          customProviders: registry,
          secureKeys: keyCache,
        ),
        io: freshIo(),
        streamFunction: _singleTextResponse('ok'),
      );
    }

    test(
      'UT-1: two providers sharing a modelId — the session resumes onto '
      'the NAMED entry (AC1)',
      timeout: const Timeout(Duration(seconds: 60)),
      () async {
        await seedSession('twin');
        await saveFolderModelState(
          env,
          sessionsRoot: '/sessions',
          cwd: '/work',
          providerKind: 'openai-completions',
          modelId: 'k3-256k',
          baseUrl: kimiUrl,
          customProvider: 'kimi_me',
        );

        final store =
            FakeSecureKeyStore()
              ..map[iraKeyName] = 'ira-key'
              ..map[kimiMeKeyName] = 'me-key';
        final second = await pinnedCliFactory(
          sessionName: 'twin',
          registry: twinRegistry(),
          store: store,
        );
        final io = ios.last;
        final run = second.run();
        io.sendLine('/provider');
        io.sendLine('/exit');
        await run;

        expect(second.agent.state.model.id, 'k3-256k');
        // Name-pinned, NOT first-endpoint-match (which would be ira-1):
        // the active binding names kimi_me in the status bar, its row is
        // the (current) one, and its OWN key slot serves the session.
        expect(second.activeCustomProviderName, 'kimi_me');
        expect(second.agent.state.model.baseUrl, kimiUrl);
        expect(
          io.out.toString(),
          contains('kimi_me — https://api.kimi.com/coding/v1 · '
              'k3-256k (current)'),
        );
        expect(io.out.toString(), contains('kimi_me/k3-256k'));
        expect(io.out.toString(), contains('key: $kimiMeKeyName'));
        expect(io.out.toString(), isNot(contains('no longer configured')));
      },
    );

    test(
      'IT-3: a store-backed key resumes with no env var exported (AC3)',
      timeout: const Timeout(Duration(seconds: 60)),
      () async {
        await seedSession('store-key');
        await saveFolderModelState(
          env,
          sessionsRoot: '/sessions',
          cwd: '/work',
          providerKind: 'openai-completions',
          modelId: 'k3-256k',
          baseUrl: kimiUrl,
          customProvider: 'kimi_me',
        );

        final second = await pinnedCliFactory(
          sessionName: 'store-key',
          registry: twinRegistry(),
          store: FakeSecureKeyStore()..map[kimiMeKeyName] = 'me-key',
        );
        final io = ios.last;
        final run = second.run();
        io.sendLine('/exit');
        await run;

        expect(second.agent.state.model.id, 'k3-256k');
        expect(second.activeCustomProviderName, 'kimi_me');
        expect(io.out.toString(), contains('restored k3-256k'));
        // No re-auth degradation: the key resolved from the store.
        expect(io.out.toString(), isNot(contains('no key for')));
      },
    );

    test(
      'E3: a missing store key degrades to a named re-auth note',
      timeout: const Timeout(Duration(seconds: 60)),
      () async {
        await seedSession('no-key');
        await saveFolderModelState(
          env,
          sessionsRoot: '/sessions',
          cwd: '/work',
          providerKind: 'openai-completions',
          modelId: 'k3-256k',
          baseUrl: kimiUrl,
          customProvider: 'kimi_me',
        );

        final second = await pinnedCliFactory(
          sessionName: 'no-key',
          registry: twinRegistry(),
          store: FakeSecureKeyStore(),
        );
        final io = ios.last;
        final run = second.run();
        io.sendLine('/exit');
        await run;

        // The model is kept (status bar), the fix is named.
        expect(second.agent.state.model.id, 'k3-256k');
        expect(io.out.toString(), contains('kimi_me'));
        expect(io.out.toString(), contains('/key set $kimiMeKeyName'));
      },
    );

    test(
      'E1: a deleted provider entry degrades to endpoint-keyed restore',
      timeout: const Timeout(Duration(seconds: 60)),
      () async {
        await seedSession('renamed');
        await saveFolderModelState(
          env,
          sessionsRoot: '/sessions',
          cwd: '/work',
          providerKind: 'openai-completions',
          modelId: 'k3-256k',
          baseUrl: kimiUrl,
          customProvider: 'gone-provider',
        );

        final second = await pinnedCliFactory(
          sessionName: 'renamed',
          registry: twinRegistry(),
          store: FakeSecureKeyStore()..map[kimiMeKeyName] = 'me-key',
        );
        final io = ios.last;
        final run = second.run();
        io.sendLine('/exit');
        await run;

        expect(second.agent.state.model.id, 'k3-256k');
        expect(second.activeCustomProviderName, isNull);
        expect(io.out.toString(), contains('gone-provider'));
        expect(io.out.toString(), contains('no longer configured'));
      },
    );

    test(
      'REG-5: a pre-change state file (no provider name) restores like '
      'today',
      timeout: const Timeout(Duration(seconds: 60)),
      () async {
        await seedSession('legacy');
        await saveFolderModelState(
          env,
          sessionsRoot: '/sessions',
          cwd: '/work',
          providerKind: 'openai-completions',
          modelId: 'k3-256k',
          baseUrl: kimiUrl,
        );

        final second = await pinnedCliFactory(
          sessionName: 'legacy',
          registry: twinRegistry(),
          store: FakeSecureKeyStore()..map[kimiMeKeyName] = 'me-key',
        );
        final io = ios.last;
        final run = second.run();
        io.sendLine('/exit');
        await run;

        expect(second.agent.state.model.id, 'k3-256k');
        expect(second.activeCustomProviderName, isNull);
        expect(io.out.toString(), contains('restored k3-256k'));
        expect(io.out.toString(), isNot(contains('no longer configured')));
      },
    );

    test(
      'roles mode: the restored pin re-points the default chain (AC3)',
      timeout: const Timeout(Duration(seconds: 60)),
      () async {
        await seedSession('roles-pin');
        await saveFolderModelState(
          env,
          sessionsRoot: '/sessions',
          cwd: '/work',
          providerKind: 'openai-completions',
          modelId: 'k3-256k',
          baseUrl: kimiUrl,
          customProvider: 'kimi_me',
        );

        // Boot 2 runs roles-driven: the config's default chain pins
        // ANOTHER provider (the gh-1000 repro shape). The restore must
        // re-pin the chain onto the named entry's key.
        final store = FakeSecureKeyStore()..map[kimiMeKeyName] = 'me-key';
        final keys = SecureKeyCache(store);
        await keys.preload(const [kimiMeKeyName]);
        final resolver = ModelRolesResolver(
          config: ModelRolesConfig(
            roles: {
              'default': const [
                ModelRef(provider: 'anthropic', modelId: 'claude-a'),
              ],
            },
          ),
          secrets: const {'ANTHROPIC_API_KEY': 'test-key'},
          streamFactory: (kind, apiKey) => _singleTextResponse('ok'),
        );
        final second = AgentCli(
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
            sessionName: 'roles-pin',
            customProviders: twinRegistry(),
            secureKeys: keys,
            modelRolesResolver: resolver,
          ),
          io: freshIo(),
          streamFunction: _singleTextResponse('ok'),
        );
        final io = ios.last;
        final run = second.run();
        io.sendLine('/exit');
        await run;

        final resolved = second.config.modelRolesResolver!.resolveRole(
          'default',
        );
        expect(resolved, isNotNull);
        expect(resolved!.model.id, 'k3-256k');
        expect(resolved.model.baseUrl, kimiUrl);
      },
    );

    test(
      'roles mode: the restored pin keeps the saved entry authHeader '
      '(issue #964)',
      timeout: const Timeout(Duration(seconds: 60)),
      () async {
        await seedSession('roles-header');
        await saveFolderModelState(
          env,
          sessionsRoot: '/sessions',
          cwd: '/work',
          providerKind: 'openai-completions',
          modelId: 'k3-256k',
          baseUrl: kimiUrl,
          customProvider: 'kimi_me',
        );

        // kimi_me is a GATEWAY entry: it carries an authHeader (issue #964).
        final registry = CustomProviderRegistry([
          twinRegistry().find('ira-1')!,
          twinRegistry().find('kimi_me')!..authHeader = 'x-api-key',
        ]);
        final store = FakeSecureKeyStore()..map[kimiMeKeyName] = 'me-key';
        final keys = SecureKeyCache(store);
        await keys.preload(const [kimiMeKeyName]);
        final resolver = ModelRolesResolver(
          config: ModelRolesConfig(
            roles: {
              'default': const [
                ModelRef(provider: 'anthropic', modelId: 'claude-a'),
              ],
            },
          ),
          secrets: const {'ANTHROPIC_API_KEY': 'test-key'},
          streamFactory: (kind, apiKey) => _singleTextResponse('ok'),
        );
        final second = AgentCli(
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
            sessionName: 'roles-header',
            customProviders: registry,
            secureKeys: keys,
            modelRolesResolver: resolver,
          ),
          io: freshIo(),
          streamFunction: _singleTextResponse('ok'),
        );
        final io = ios.last;
        final run = second.run();
        io.sendLine('/exit');
        await run;

        final resolved = second.config.modelRolesResolver!.resolveRole(
          'default',
        );
        expect(resolved, isNotNull);
        expect(resolved!.model.id, 'k3-256k');
        expect(resolved.model.baseUrl, kimiUrl);
        // The gateway header must ride the CHAIN model: the roles stream
        // serves from the chain entry, not the agent state — a ModelRef
        // without the header 401s on the next turn (issue #964).
        expect(resolved.model.authHeader, 'x-api-key');
      },
    );

    test(
      'roles mode: a failed re-pin keeps the previous model AND chain '
      '(no status/stream split)',
      timeout: const Timeout(Duration(seconds: 60)),
      () async {
        await seedSession('roles-repin-fail');
        await saveFolderModelState(
          env,
          sessionsRoot: '/sessions',
          cwd: '/work',
          providerKind: 'openai-completions',
          modelId: 'k3-256k',
          baseUrl: kimiUrl,
          customProvider: 'kimi_me',
        );

        // The pinned key is MISSING: the chain re-pin mutates the resolver,
        // then applyToAgent throws. The restore must roll the whole pin
        // back — the status bar and the stream keep describing the SAME
        // (old) provider until the key is set.
        final second = AgentCli(
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
            sessionName: 'roles-repin-fail',
            customProviders: twinRegistry(),
            secureKeys: SecureKeyCache(FakeSecureKeyStore()),
            modelRolesResolver: ModelRolesResolver(
              config: ModelRolesConfig(
                roles: {
                  'default': const [
                    ModelRef(provider: 'anthropic', modelId: 'claude-a'),
                  ],
                },
              ),
              secrets: const {'ANTHROPIC_API_KEY': 'test-key'},
              streamFactory: (kind, apiKey) => _singleTextResponse('ok'),
            ),
          ),
          io: freshIo(),
          streamFunction: _singleTextResponse('ok'),
        );
        final io = ios.last;
        final run = second.run();
        io.sendLine('/exit');
        await run;

        // The agent model is untouched — NOT the restored k3-256k.
        expect(second.agent.state.model.id, 'start-model');
        // The resolver still resolves the OLD default chain.
        final resolved = second.config.modelRolesResolver!.resolveRole(
          'default',
        );
        expect(resolved, isNotNull);
        expect(resolved!.model.provider, 'anthropic');
        expect(resolved.model.id, 'claude-a');
        // The fix is named; nothing claims a completed restore.
        expect(io.out.toString(), contains('/key set $kimiMeKeyName'));
        expect(io.out.toString(), isNot(contains('restored k3-256k')));
        expect(second.activeCustomProviderName, isNull);
      },
    );

    test(
      'E1: a stale LEAF pin degrades with the named note (model kept)',
      timeout: const Timeout(Duration(seconds: 60)),
      () async {
        await seedSession('leaf-stale');
        // The session's own last model_change pins a provider entry that no
        // longer exists in the registry (deleted/renamed since).
        final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
        final sessions = await repo.list();
        expect(sessions, isNotEmpty);
        final session = await repo.open(sessions.first);
        await session.appendModelChange(
          provider: 'openai-completions',
          modelId: 'k3-256k',
          baseUrl: kimiUrl,
          customProvider: 'gone-provider',
        );

        final second = await pinnedCliFactory(
          sessionName: 'leaf-stale',
          registry: twinRegistry(),
          store: FakeSecureKeyStore()..map[kimiMeKeyName] = 'me-key',
        );
        final io = ios.last;
        final run = second.run();
        io.sendLine('/exit');
        await run;

        // E1: the model is kept, the stale name is said, the fallback is
        // endpoint-keyed — never a silent unpin that can bind the twin
        // account's key (round-3 review).
        expect(second.agent.state.model.id, 'k3-256k');
        expect(io.out.toString(), contains('gone-provider'));
        expect(io.out.toString(), contains('no longer configured'));
      },
    );

    test(
      'AC1: a live-switch leaf pin survives a folder-state drift',
      timeout: const Timeout(Duration(seconds: 60)),
      () async {
        // Boot A: a LIVE /provider switch — the switch must record the leaf
        // pin itself (round-3 review: the restore alone writing pins is not
        // enough).
        final store =
            FakeSecureKeyStore()
              ..map[iraKeyName] = 'ira-key'
              ..map[kimiMeKeyName] = 'me-key';
        final bootA = await pinnedCliFactory(
          sessionName: 'drift-a',
          registry: twinRegistry(),
          store: store,
        );
        final ioA = ios.last;
        final runA = bootA.run();
        await Future<void>.delayed(const Duration(milliseconds: 200));
        ioA.sendLine('hi');
        await Future<void>.delayed(const Duration(milliseconds: 200));
        ioA.sendLine('/provider kimi_me');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        ioA.sendLine('/exit');
        await runA;
        expect(bootA.activeCustomProviderName, 'kimi_me');

        // A sibling session drifts the SHARED folder state onto the twin
        // account (the interleaved-switch case AC1 targets).
        await saveFolderModelState(
          env,
          sessionsRoot: '/sessions',
          cwd: '/work',
          providerKind: 'openai-completions',
          modelId: 'k3-256k',
          baseUrl: kimiUrl,
          customProvider: 'ira-1',
        );

        // Restoring A must follow A's OWN leaf pin — not the drifted folder
        // state — so kimi_me's OWN key slot serves the session.
        final bootC = await pinnedCliFactory(
          sessionName: 'drift-a',
          registry: twinRegistry(),
          store: store,
        );
        final ioC = ios.last;
        final runC = bootC.run();
        ioC.sendLine('/exit');
        await runC;

        if (bootC.agent.state.model.id != 'k3-256k') {
          fail('BOOT-C-OUT:\n${ioC.out.toString()}');
        }
        expect(bootC.activeCustomProviderName, 'kimi_me');
        expect(
          bootC.agent.state.model.baseUrl,
          kimiUrl,
        );
      },
    );
  });
}

StreamFunction _singleTextResponse(String text) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final message = AssistantMessage(
      content: [TextContent(text: text)],
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

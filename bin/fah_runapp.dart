part of 'fah.dart';

Future<void> _runApp(List<String> args) async {
  final packageVersion = _packageVersion();
  _applyProviderFilterEnv();
  // Platform-aware chord display (issue #809): Option/Cmd labels on macOS.
  tuiKeyHintDarwin = Platform.isMacOS;
  // `fa serve [--a2a|--bridge] [--port N] [--token T]` — the parser does
  // not know the serve forms, so they are intercepted before CliArgs
  // parsing: serve-specific flags are stripped from the parsed args and
  // kept for the late interception below (after model/key resolution).
  final serve = splitServeA2aArgs(args);
  // `fa wire-serve [--port N] [--stdio] [--token T]` (issue #1103) — the
  // headless AWP server. Intercepted like serve: the parser does not know
  // the form, and the words must never reach prompt parsing. Flag errors
  // (--stdio with --port, a bad --port) are LOUD startup failures (E2) —
  // never a silent fallback to another mode.
  final WireServeArgs wireServe;
  try {
    wireServe = splitWireServeArgs(args);
  } on FormatException catch (error) {
    _fail(
      'usage: fa wire-serve [--port N] [--stdio] [--token T]\n'
      '${error.message}',
    );
  }
  // `fa hub serve [--port N]` — a local DAP hub, no agent boot
  // (docs/dap.md §8.1). Intercepted on the raw args BEFORE the serve
  // marker check below (`hub serve` contains the word "serve" but is a
  // different command): the words must never reach prompt parsing.
  if (args.isNotEmpty && args.first == 'hub') {
    exit(await runHubCommand(args.sublist(1)));
  }
  // `fa dap start|stop|status [--port N]` — the one-step local DAP hub
  // (issue #304): probe/spawn/enroll/stop with no agent boot, same raw-
  // args interception as `fa hub serve`.
  if (args.isNotEmpty && args.first == 'dap') {
    exit(await runDapCommand(args.sublist(1)));
  }
  final serveMarkerCount =
      (serve.serveA2a ? 1 : 0) + (serve.serveBridge ? 1 : 0);
  if (serveMarkerCount != 1 && args.contains('serve')) {
    _fail(
      'usage: fa serve --a2a [--port N] [--token T] | '
      'fa serve --bridge [--port N] [--token T]',
    );
  }

  late final CliArgs parsed;
  try {
    parsed = switch (parseCliArgs(
      wireServe.wireServe ? wireServe.cliArgs : serve.cliArgs,
    )) {
      CliArgsHelp() => _exitWithUsage(packageVersion),
      CliArgsVersion(:final output) => _exitWithVersion(
        packageVersion,
        output: output,
      ),
      final CliArgs cliArgs => cliArgs,
    };
  } on CliArgsException catch (error) {
    _fail(error.message);
  }

  // Quick self-management commands, intercepted before prompt resolution:
  // `fa update` swaps in the latest release binary; `fa uninstall` removes
  // the binary + PATH entry (and ~/.fah on a second confirmation).
  if (parsed.positionals.length == 1 && parsed.prompt == null) {
    switch (parsed.positionals.single) {
      case 'update':
        exit(await runSelfUpdate(currentVersion: packageVersion));
      case 'uninstall':
        exit(await runSelfUninstall());
    }
  }
  // `fa trajectory <verb> [sessionId] [--json] [--at N]` — read-only
  // trajectory views over a stored session; intercepted before prompt
  // resolution so the verb words never become a prompt.
  final trajectory = parsed.trajectory;
  if (trajectory != null) {
    exit(await _runTrajectoryCommand(trajectory, parsed));
  }

  // `fa ext <verb> ...` — headless JS extension management, intercepted
  // like trajectory: no agent boot, the exit code propagates.
  final ext = parsed.ext;
  if (ext != null) {
    final extEnv = LocalExecutionEnv(cwd: parsed.cwd ?? Directory.current.path);
    exit(
      await runExtCliCommand(
        ext,
        io: _TerminalCliIO(headless: true),
        env: extEnv,
        projectDir: extEnv.cwd,
        userDir: _homeDir(),
      ),
    );
  }

  // `fa jsr widget:test|widget:screenshot …` — the js_widget_runtime agent
  // CLI pass-through (gh-1033), intercepted like trajectory: no agent
  // boot. The child's stdout/stderr stream straight through and its exit
  // code propagates (CI-usable); platform bits (PATH) come from the
  // process, the only dart:io layer here.
  final jsr = parsed.jsr;
  if (jsr != null) {
    final jsrEnv = LocalExecutionEnv(cwd: parsed.cwd ?? Directory.current.path);
    exit(
      await runJsrCliCommand(
        jsr,
        io: SinkJsrCliIo(
          onStdout: stdout.write,
          onStderr: stderr.write,
          onNote: stderr.writeln,
        ),
        env: jsrEnv,
        projectDir: jsrEnv.cwd,
        pathEnv: Platform.environment['PATH'] ?? '',
        pathListSeparator: Platform.isWindows ? ';' : ':',
        windowsQuoting: Platform.isWindows,
      ),
    );
  }
  // `fa session list [--json] [--flat]` (issue #198) — the tree-grouped
  // session listing, intercepted like trajectory: no agent boot.
  final sessionList = parsed.sessionList;
  if (sessionList != null) {
    final io = _TerminalCliIO(headless: true);
    final listEnv = LocalExecutionEnv(
      cwd: parsed.cwd ?? Directory.current.path,
    );
    exit(
      await runSessionListCliCommand(
        write: io.write,
        writeln: io.writeln,
        env: listEnv,
        sessionRoot: parsed.sessionRoot ?? _defaultSessionRoot(),
        cwd: listEnv.cwd,
        json: sessionList.json,
        flat: sessionList.flat,
      ),
    );
  }

  // JS extension bootstrap (.fa/bootstrap.yaml, project then user): every
  // normal start applies it idempotently before the REPL or headless run;
  // E15 soft-fail lines go to stderr. FA_EXT_BOOTSTRAP_STRICT=1 makes a
  // bootstrap failure fatal instead.
  try {
    await applyBootstrapIfPresent(
      io: _TerminalCliIO(headless: parsed.isHeadless),
      env: LocalExecutionEnv(cwd: parsed.cwd ?? Directory.current.path),
      projectDir: parsed.cwd ?? Directory.current.path,
      userDir: _homeDir(),
      strict: _envTruthy('FA_EXT_BOOTSTRAP_STRICT'),
    );
  } on Object catch (error) {
    _fail('ext bootstrap failed: $error');
  }

  // Headless prompt resolution: --prompt-file read as UTF-8 verbatim
  // (missing/unreadable = usage error); -p verbatim; a first positional
  // naming an existing file inlines text files (.md/.markdown/.txt) or
  // attaches other files as a path reference; anything else is plain
  // prompt text.
  final String? headlessPrompt;
  try {
    headlessPrompt = resolveHeadlessPrompt(
      prompt: parsed.prompt,
      promptFile: parsed.promptFile,
      positionals: parsed.positionals,
    );
  } on CliArgsException catch (error) {
    _fail(error.message);
  }

  // `fa config check|path|get|set` runs BEFORE loadCliConfig: check must
  // be able to diagnose exactly the broken config that would abort boot
  // (issue #29). homeDir may be null — the service reports the global
  // scope honestly.
  final earlyConfigCmd = parsed.config;
  if (earlyConfigCmd != null && earlyConfigCmd.verb != 'export-providers') {
    exit(
      await runConfigServiceCommand(
        earlyConfigCmd,
        io: _TerminalCliIO(headless: true),
        env: LocalExecutionEnv(cwd: Directory.current.path),
        homeDir: homeDirectory(),
      ),
    );
  }

  final home = homeDirectory();
  if (home == null || home.isEmpty) {
    _fail('cannot resolve home directory; pass --session-root');
  }
  late final CliConfig saved;
  try {
    saved = loadCliConfig(home);
  } on ConfigException catch (error) {
    _fail('invalid ~/.fah/config.yaml: ${error.message}');
  }
  // Provider watchdog overrides (`providerTimeouts:` section): process-wide,
  // read by the adapters' connect/idle watchdogs on every request. The
  // FA_PROVIDER_TIMEOUT_SECONDS env value folds in over the section
  // (issue #1036: non-streaming fetch bound; env wins for CI runners).
  try {
    providerTimeoutsOverride = applyProviderTimeoutEnvOverride(
      saved.providerTimeouts,
      Platform.environment['FA_PROVIDER_TIMEOUT_SECONDS'],
    );
  } on ConfigException catch (error) {
    _fail(error.message);
  }
  // Session image registry (`images:` section, issue #171): process-wide,
  // read inside the agent loop's request build. Default: on.
  imageRegistryConfig = saved.images ?? const ImageRegistryConfig();

  // `fa config export-providers` — needs the loaded config (saved
  // providers + key names); check|path|get|set already ran above.
  final configCmd = parsed.config;
  if (configCmd != null) {
    final exportKeys = SecureKeyCache(platformSecureKeyStore());
    await exportKeys.preload(secureKeyPreloadNames(saved, baseUrl: null));
    exit(
      await runProviderExportCommand(
        configCmd,
        io: _TerminalCliIO(headless: true),
        env: LocalExecutionEnv(cwd: Directory.current.path),
        entries: saved.customProviders,
        secureRead: exportKeys.read,
      ),
    );
  }

  late final ({
    CliArgs args,
    String provider,
    EnvProviderPreconfig? faPreconfig,
    String? unknownSavedProvider,
    String? incompatibleSavedEndpoint,
  })
  cliStartup;
  try {
    cliStartup = resolveEffectiveCliArgs(
      parsed,
      saved,
      env: Platform.environment,
    );
  } on ConfigException catch (error) {
    _fail(error.message);
  }
  final effective = cliStartup.args;
  var provider = cliStartup.provider;
  final faPreconfig = cliStartup.faPreconfig;

  // gh-760: a persisted provider id no version knows must never brick the
  // boot. The config is shared with surfaces the CLI does not control
  // (the app, the extension, older/newer versions); the bad value gets a
  // loud named warning here (value, file, fallback taken, likely version
  // skew) and the known fallback provider takes over. The config file is
  // NOT modified — warn, don't mutate.
  if (cliStartup.unknownSavedProvider case final unknown?) {
    stderr.writeln(
      'warning: unknown provider "$unknown" in $home/.fah/config.yaml - '
      'written by a newer app/CLI version? falling back to '
      '"$provider" (the config was not modified; run /provider or edit '
      'the file to switch)',
    );
  }
  // gh-760 (review): a persisted provider/baseUrl PAIR an endpoint-locked
  // kind cannot serve (codex pointed at a stale foreign endpoint by a
  // partial write) degrades like an unknown id - the key gate would
  // otherwise refuse the boot with self-contradictory guidance.
  if (cliStartup.incompatibleSavedEndpoint case final conflict?) {
    stderr.writeln(
      'warning: saved provider "$conflict" only works with its own '
      'default endpoint - the saved baseUrl "${effective.baseUrl}" in '
      '$home/.fah/config.yaml is not servable by it; falling back to '
      '"$provider" (the config was not modified; run /provider or edit '
      'the file to switch)',
    );
  }

  final cwd = effective.cwd ?? Directory.current.path;
  final sessionRoot = effective.sessionRoot ?? _defaultSessionRoot();
  // The execution env shared by the CLI config (tools, session storage),
  // the presence store (live-session heartbeats) and the per-folder model
  // state IO. Mutable cwd: a resumed session re-points it (see _loadSession).
  final cliEnv = LocalExecutionEnv(cwd: cwd);

  // Per-folder model memory: restore the model/provider triple last used
  // in THIS folder — a `/model` switch in another workspace must not leak
  // in across restarts. Explicit per-launch declarations win: --model,
  // --provider, --base-url, or an FA_PROVIDER_* env preconfig.
  final folderState = await loadFolderModelState(
    cliEnv,
    sessionsRoot: sessionRoot,
    cwd: cwd,
  );
  final applyFolderState =
      folderState != null &&
      folderModelStateApplies(
        modelExplicit: parsed.model != null,
        providerExplicit: parsed.providerExplicit,
        baseUrlExplicit: parsed.baseUrl != null,
        hasProviderPreconfig: faPreconfig != null,
      );
  // gh-760: the folder state is written by the same shared-config family
  // — validate its provider kind the same way. An unrecognizable kind
  // gets a named warning and the state file is ignored (never a boot
  // throw); every catalog name/kind resolves by construction. The restore
  // takes the RESOLVED spec's KIND (review): a state file carrying a
  // catalog name must not leak the raw name into the stream factory.
  final folderSpec = applyFolderState
      ? resolveCliProviderSpec(folderState.providerKind)
      : null;
  final state = folderState;
  // gh-760 (review): the same provider/baseUrl PAIR judgement as the saved
  // config restore — an endpoint-locked kind over a foreign state baseUrl
  // is not servable; the state file is ignored with a named warning.
  final folderEndpointConflict =
      state != null &&
      folderSpec != null &&
      folderSpec.endpointLocked &&
      state.baseUrl != null &&
      state.baseUrl != folderSpec.defaultBaseUrl;
  final folderStateUsable =
      applyFolderState && folderSpec != null && !folderEndpointConflict;
  if (state != null && applyFolderState && !folderStateUsable) {
    stderr.writeln(
      folderEndpointConflict
          ? 'warning: saved folder model state pairs '
                '"${state.providerKind}" with a foreign baseUrl '
                '"${state.baseUrl}" - the kind only works with its '
                'own default endpoint '
                '(${folderModelStatePath(sessionsRoot: sessionRoot, cwd: cwd)})'
                ' — ignoring it and keeping "$provider"'
          : 'warning: saved folder model state names unknown provider '
                '"${state.providerKind}" '
                '(${folderModelStatePath(sessionsRoot: sessionRoot, cwd: cwd)}) — '
                'ignoring it and keeping "$provider"',
    );
  }
  // gh-1000 (AC1): the state's saved-provider NAME pins WHICH saved entry
  // serves the restored model — two entries can share one endpoint and
  // modelId, and endpoint-keyed resolution would pick the first config
  // match (possibly the other account's key → 401). A name that no
  // longer resolves degrades to endpoint-keyed resolution with a note
  // (E1 — the model is kept). The resolution lives in fah_boot_restore.dart
  // (the pin logic's one testable home; round-3 review).
  final folderPinned = resolveBootFolderPin(
    state: folderStateUsable ? state : null,
    entries: saved.customProviders,
  );
  if (folderPinned.note != null) {
    stderr.writeln('note: ${folderPinned.note}');
  }
  final folderPinnedEntry = folderPinned.entry;
  final applyFolderModel = applyFolderState && folderStateUsable;
  if (applyFolderModel) {
    provider = folderSpec.kind;
  }
  final baseUrl = applyFolderModel ? folderState.baseUrl : effective.baseUrl;

  final model = applyFolderModel
      ? buildCliDefaultModel(
          provider,
          modelId: folderState.modelId,
          baseUrl: folderState.baseUrl,
          // A saved custom-provider entry carrying this endpoint's
          // authHeader (issue #964) must survive the restore.
          authHeader: authHeaderForBaseUrl(
            saved.customProviders,
            folderState.baseUrl,
          ),
          thinkingLevel: faPreconfig?.thinkingLevel,
        )
      : _buildModel(
          effective,
          input: faPreconfig?.input,
          thinkingLevel: faPreconfig?.thinkingLevel,
        );

  // Initial cube (fa_cube Phase 1): --cube-config path > --cube name > the
  // project `.fah/config.yaml` `cube:` section > the saved user `cube:`
  // section (each config section only when enabled). A broken manifest is
  // a hard error — a requested cube must never fail open into an
  // unconfined run.
  String? cubeSource;
  CubeSpec? cubeSpec;
  try {
    cubeSource = resolveStartupCubeSource(
      flagConfigPath: parsed.cubeConfigPath,
      flagName: parsed.cubeName,
      project: loadProjectCubeSettings(cwd),
      user: saved.cube,
    );
    final isPath = cubeSource?.contains('/') ?? false;
    cubeSpec = await CubeResolver.resolve(
      env: cliEnv,
      path: isPath ? cubeSource : null,
      name: isPath ? null : cubeSource,
      homeDir: home,
    );
  } on ConfigException catch (error) {
    _fail(error.message);
  }

  // Compaction engine (issue #148, default flip #287): `--compaction-engine`
  // flag > the project `.fah/config.yaml` `compaction:` section > the saved
  // user `compaction:` section > structured (2.0 default; classic is the
  // legacy rollback). Strict parse errors are hard startup errors (a typo
  // must never silently downgrade the engine).
  final compactionEngine = resolveCompactionEngine(
    session: effective.compactionEngine,
    project: loadProjectCompactionEngine(cwd),
    global: saved.compactionEngine,
  );

  // Judge budget knob (issue #541): user-level `compaction.
  // judgeBudgetSeconds`; `null` keeps the 90s default.
  final compactionJudgeBudgetSeconds = saved.compactionJudgeBudgetSeconds;

  // Raw wire dumps (issue #385 F5): opt-in only — the project
  // `.fah/config.yaml` `trajectory:` section wins over the user one.
  final wireDump = loadProjectWireDump(cwd) ?? saved.wireDump;

  // Remote provider catalog (fa1.dev/models-catalog.json): default model
  // ids and per-provider context-window tables for endpoints that don't
  // publish them. Preloaded once, non-blocking (a 10s timeout, never
  // throws) — pickers fall back to the live endpoint + local defaults.
  await remoteCatalogEnrichment.preload(client: sharedProviderHttpClient());

  // Platform secure storage (macOS Keychain / Secret Service / Windows
  // Credential Locker): backs up every provider key the environment does
  // not set. Reads are process spawns, so the store is preloaded once into
  // a synchronous session cache — every later lookup (startup resolution,
  // the banner, `/provider`, `/key`) hits the snapshot.
  //
  // gh-1059: the preload report feeds the boot diagnostics — every read
  // logged under --debug-secrets / FA_DEBUG_KEYS, and a config that
  // references store keys while NONE resolve prints a warning instead of
  // the silent keyless boot.
  final keyCache = SecureKeyCache(platformSecureKeyStore());
  final keyPreloadReport = await keyCache.preload(
    secureKeyPreloadNames(saved, baseUrl: baseUrl),
  );
  for (final line in secureKeyBootDiagnostics(
    report: keyPreloadReport,
    referencedKeyNames: referencedSecureKeyNames(saved),
    debug:
        parsed.debugSecrets ||
        isTruthyEnvValue(Platform.environment['FA_DEBUG_KEYS']),
    storeLabel: keyCache.label,
  )) {
    stderr.writeln(line);
  }

  // gh-1000 (E2): when the boot-pinned key slot exists in BOTH the
  // environment and the store with different values, note the provenance
  // order (the env value wins). Detection + wording are the shared
  // envShadowingNote rule (key_status.dart) — the restore note and the
  // banner hint use the same one.
  final pinnedKeyName = folderPinnedEntry?.keyName;
  if (pinnedKeyName != null) {
    final note = envShadowingNote(
      pinnedKeyName,
      Platform.environment[pinnedKeyName],
      keyCache.read(pinnedKeyName),
    );
    if (note != null) stderr.writeln('note: $note');
  }

  // Prompt overrides: the `prompts:` section of ~/.fah/config.yaml (file
  // paths resolve against the agent cwd, `~` expands; missing files are a
  // hard error, never a silent fallback).
  late final PromptOverrides promptOverrides;
  try {
    promptOverrides = resolvePromptOverrides(
      saved.promptOverrides,
      homeDir: home,
      baseDir: cwd,
    );
  } on ConfigException catch (error) {
    _fail('invalid ~/.fah/config.yaml: ${error.message}');
  }

  // --system-prompt[-file]: a per-invocation system prompt override that
  // wins over the config prompts: section and the built-in mode prompts.
  // The flag file resolves like file-as-prompt: relative to the process
  // working directory, where the user typed the command.
  var flagSystemPrompt = parsed.systemPrompt;
  final systemPromptFile = parsed.systemPromptFile;
  if (systemPromptFile != null) {
    try {
      flagSystemPrompt = loadPromptFile(
        systemPromptFile,
        homeDir: home,
        baseDir: Directory.current.path,
        source: '--system-prompt-file',
      );
    } on ConfigException catch (error) {
      _fail(error.message);
    }
  }

  // Model roles (optional): when ~/.fah/config.yaml declares a `roles:`
  // section, runs resolve through the default role's fallback chain with
  // key rotation. The legacy single provider/model path stays the fallback
  // when no default role resolves.
  final rolesConfig = saved.modelRoles;
  final roleSecrets = rolesConfig == null
      ? const <String, String>{}
      : collectRoleSecrets(rolesConfig, keyCache);
  ModelRolesResolver? rolesResolver;
  var defaultRoleResolved = false;
  if (rolesConfig != null) {
    rolesResolver = ModelRolesResolver(
      config: rolesConfig,
      secrets: roleSecrets,
      cwd: cwd,
      homeDir: home,
    );
    // FA_PROVIDER_* preconfig = one explicit provider switch for the whole
    // session: pin the default role to a single-entry chain on the env
    // provider — the same setDefaultChain + applyToAgent path a runtime
    // `/provider <name>` switch takes in roles mode. Roles the config
    // pins explicitly keep their chains; unpinned roles inherit the
    // default, so every resolution (default/smol/slow/plan) lands on the
    // env provider. A keyless declaration cannot form a chain entry
    // (chains require a key) — roles keep owning selection there, and
    // the boot note says so.
    if (faPreconfig case final preconfig? when preconfig.apiKeyEnvVar != null) {
      rolesResolver.addSecret(preconfig.apiKeyEnvVar!, preconfig.apiKey);
      rolesResolver.setDefaultChain([
        ModelRef(
          provider: preconfig.spec.name,
          modelId: preconfig.modelId,
          baseUrl: preconfig.baseUrl,
          apiKeyName: preconfig.apiKeyEnvVar,
          input: preconfig.input,
          thinkingLevel: preconfig.thinkingLevel,
        ),
      ]);
    }
    try {
      defaultRoleResolved = rolesResolver.resolveRole(defaultModelRole) != null;
    } on UnknownProviderRoleException catch (error) {
      // gh-760: degrade, never brick. The chain names providers NO version
      // knows (a config written by a newer app/CLI version) — warn on
      // stderr with the reasons and fall back to the legacy single-model
      // path. Unknown-provider entries were already skipped with named
      // reasons by the resolver; the throw only fires when no usable
      // entry remains. The drop is whole-resolver BY DESIGN (gh-760
      // review): the per-turn main-model path re-enters chainFor, so a
      // half-alive resolver would move the failure to mid-session; the
      // aux roles ride guarded best-effort paths either way.
      stderr.writeln(
        'warning: model roles config is unusable (${error.message}) — '
        'falling back to the configured single provider/model',
      );
      rolesResolver = null;
      defaultRoleResolved = false;
    } on ConfigException catch (error) {
      // A CURRENT-version misconfiguration (e.g. every entry of a KNOWN
      // provider missing its key) keeps the pre-#760 contract: a loud
      // boot failure — never a silently-ignored roles config.
      _fail('invalid model roles config: ${error.message}');
    }
  }
  late final String apiKey;
  try {
    // The FA_PROVIDER_* declaration carries its own key resolution (the
    // apiKeyEnvVar ref, or its _BASE64 twin): the env value IS the source
    // of truth for the booted session — store and config never override
    // it. Empty means a keyless endpoint (no ref declared — the spec's
    // env names are never probed).
    apiKey = faPreconfig != null
        ? faPreconfig.apiKey
        : startupApiKey(
            provider,
            keyCache,
            baseUrl: baseUrl,
            customProviders: saved.customProviders,
            defaultRoleResolved: defaultRoleResolved,
            interactive: headlessPrompt == null && !wireServe.wireServe,
            // The restored folder state's saved entry (gh-1000 AC1): its
            // own key slot resolves FIRST — the account the session
            // actually ran on, never a same-endpoint twin.
            pinnedKeyName: folderPinnedEntry?.keyName,
          );
  } on ConfigException catch (error) {
    _fail(error.message);
  }

  // Provider queue (issue #418): FA_PROVIDERS_QUEUE env > project
  // .fah/config.yaml `providersQueue:` > user ~/.fah/config.yaml. A parse
  // error in a PRESENT scope is a hard startup error (line:col); no queue
  // set anywhere = zero change (byte-identical legacy boot). The winning
  // queue REPLACES the main-model resolution; the boot notes name the
  // winning scope and the shadowed scopes.
  ProviderQueueRuntime? queueRuntime;
  final queueNotices = <String>[];
  try {
    final queue = resolveProviderQueueAtBoot(projectDir: cwd, homeDir: home);
    if (queue.entries.isNotEmpty) {
      queueRuntime = ProviderQueueRuntime.build(
        queue,
        secrets: collectQueueSecrets(queue.entries, keyCache),
      );
      queueNotices.addAll(queue.notices);
    }
  } on ConfigException catch (error) {
    _fail(error.message);
  }

  // Redact the API keys this CLI knows about from tool results and the
  // provider context, so they cannot leak into the LLM conversation or the
  // session files (assembled by [buildSecretRedactor]).
  // The layered redaction pipeline (issue #24): assembled from the
  // `redact:` config (null = defaults) BEFORE the secret redactor so the
  // redactor's dual registration feeds the pipeline's registered layer.
  final redactionPipeline = buildRedactionPipeline(effective.redact);
  // Automatic tool-result spilling (issue #678): the project
  // `.fah/config.yaml` `spills:` section wins wholesale over the user
  // one (same merge as the other project sections). Null = absent —
  // no spill hooks, byte-identical legacy boot.
  final spillsConfig = loadProjectSpillsConfig(cwd) ?? saved.spills;
  final redactor = buildSecretRedactor(
    roleSecrets: roleSecrets,
    keys: keyCache,
    pipeline: redactionPipeline,
  );
  // The FA_PROVIDER_* key ref may name ANY env var (not one of the
  // well-known catalog names) — redact it under its own name so the ref'd
  // value can never reach the transcript. A keyless declaration (no ref)
  // carries no secret.
  if (faPreconfig case final preconfig? when preconfig.apiKey.isNotEmpty) {
    redactor.register(preconfig.apiKeyEnvVar!, preconfig.apiKey);
    redactionPipeline?.registerSecret(preconfig.apiKey);
  }
  // Whether the redactor is attached to the agent. A keyless startup leaves
  // it detached; a `/provider` token arriving at runtime attaches it then.
  var redactorAttached = !redactor.isEmpty;

  final webSearch = webSearchSecrets();

  late final Future<void> Function() persistConfig;

  InspectImageConfig? visionConfig;
  if (effective.visionModel != null) {
    visionConfig = InspectImageConfig(
      modelId: effective.visionModel!,
      apiKey: _resolveApiKey('vision', keyCache, fallback: apiKey),
      baseUrl: effective.visionBaseUrl,
    );
  }

  TranscribeAudioConfig? transcribeConfig;
  if (effective.transcribeModel != null) {
    transcribeConfig = TranscribeAudioConfig(
      modelId: effective.transcribeModel!,
      apiKey: _resolveApiKey('transcribe', keyCache, fallback: apiKey),
      baseUrl: effective.transcribeBaseUrl,
    );
  }

  // The process's single hub client instance: registered as the `hub`
  // plugin when enabled, and read by the settings-hub DAP / Hub flow's
  // snapshot seam below. Constructing it has no side effects — the client
  // connects only in `start()` (driven by the plugin host).
  // A MUTABLE copy of the process environment shared with the plugin
  // host: Platform.environment is read-only, but the interactive /dap
  // "Set master secret" flow enables DAP at runtime by writing into
  // this map (the hub plugin re-reads it on every access).
  final dapEnvironment = Map<String, String>.of(Platform.environment);
  // "The next boot is online by itself" (docs/dap.md): with no explicit
  // env credential, seed the hub kill-switch key from the persisted
  // `~/.dap/config.json` `clientSecret` (the explicit prior opt-in from
  // `/dap start`). Without this the hub plugin never connects on a fresh
  // boot and `agent_directory` shows file inboxes only — hub peers (the
  // browser extension, embedded hosts) stay invisible from the CLI.
  seedHubBootCredential(
    dapEnvironment,
    masterSecretKey: envMasterSecret,
    clientSecretKey: envClientSecret,
    dapConfig: readDapConfig(defaultDapConfigFile(null, dapEnvironment)),
  );
  final hubPlugin = HubPlugin(environment: dapEnvironment);
  final resolved = await _resolvePlugins(
    effective,
    cliEnv,
    hubPlugin,
    dapEnvironment,
    // `fabric.hub: false` (issue #304 E6) — the legacy kill switch: no
    // hub primary in the messaging fabric, byte-identical directory.
    fabricHubAllowed: saved.fabric?.hub ?? true,
  );

  if (!const {'code', 'architect', 'review'}.contains(effective.mode)) {
    _fail('unknown mode: ${effective.mode}');
  }
  final promptTemplateDirs = <String>[
    '$cwd/.fah/prompts',
    '$home/.fah/prompts',
    ...effective.promptTemplateDirs,
  ];

  final terminalIo = _TerminalCliIO(headless: headlessPrompt != null);
  // wire-serve (issue #1103): the io is a SILENT sink — every rendered
  // line dies there, so nothing TUI-shaped can ever reach the protocol
  // stream (the one stdout line is the startup line, written by the
  // transport, outside the CLI). Diagnostics keep stderr via writeln.
  CliIO io = wireServe.wireServe ? _WireServeSilentCliIO() : terminalIo;
  // --log-file (issue #91): tee the rendered session trace into a file so
  // a parent CLI's stdout capture cannot swallow it. The sink is a sync
  // RandomAccessFile — unbuffered, so `tail -f` streams the trace live and
  // even a SIGINT exit never loses the tail of the log. FA_LOG_FILE
  // (issue #178) is the env twin — the default when the flag is absent,
  // so CI hosts that cannot pass flags still leave the trace; flag wins.
  RandomAccessFile? logTeeFile;
  final logPath = parsed.logFile ?? logFileFromEnv(Platform.environment);
  if (logPath case final path?) {
    final RandomAccessFile tee;
    try {
      tee = File(path).openSync(mode: FileMode.write);
    } on Object catch (error) {
      _fail('cannot open --log-file "$path": $error');
    }
    logTeeFile = tee;
    io = TeeCliIO(terminalIo, tee.writeStringSync);
    if (parsed.logFile == null) {
      io.writeln('note: --log-file "$path" from the FA_LOG_FILE env var');
    }
  }
  // HEP events mode (issue #155): resolved below with the writer; the
  // assignment happens once `parsed.output` is known — see HepEventsIO.
  // The one boot notice for env preconfig (same channel as the raw-mode

  // The FA_PROVIDER_* notice: names the declaration (type, resolved name,
  // key ref — or its keyless absence) — never the key value. The pinned
  // declaration is the session default for every model role; only a
  // keyless declaration under an active roles: section (which cannot pin
  // a chain) stays fallback-only, and the note says so.
  if (faPreconfig case final preconfig?) {
    io.writeln(
      'note: provider ${preconfig.name} (${preconfig.spec.name}) '
      'from FA_PROVIDER_* env — key: '
      '${preconfig.apiKeyEnvVar ?? 'none (keyless endpoint)'}'
      '${preconfig.thinkingLevel == null ? '' : '; thinkingLevel: ${preconfig.thinkingLevel}'}',
    );
    // A declared level on an adapter that is not wired to the
    // config-carried level is carried but never sent — say so once
    // instead of silently ignoring it (issue #734 E1). Wording covers
    // both no-thinking adapters (openai-completions) and adapters with
    // their own thinking options that no config path reaches yet (google).
    if (preconfig.thinkingLevel != null &&
        preconfig.spec.api != anthropicMessagesApi) {
      io.writeln(
        'note: the ${preconfig.spec.api} adapter is not wired to the '
        'config-carried thinkingLevel — the declared level is carried '
        'but unused',
      );
    }
    if (defaultRoleResolved) {
      io.writeln(
        preconfig.apiKeyEnvVar == null
            ? 'note: FA_PROVIDER_* preconfig applies to the fallback model '
                  'only (roles: section is active; a keyless declaration '
                  'cannot pin a roles chain)'
            : 'note: FA_PROVIDER_* preconfig is the session default — all '
                  'model roles resolve to it unless roles: pins a chain',
      );
    }
  }
  // The provider-queue boot notes: winning scope + shadowed scopes —
  // the loud handover, never a silent degrade (issue #418).
  for (final notice in queueNotices) {
    io.writeln(notice);
  }
  if (io.isInteractive && !io.supportsRawMode) {
    io.writeln(
      'note: this terminal does not support raw-mode input; '
      'interactive slash/model menus are unavailable.',
    );
  }

  // `fa serve --a2a [--port N] [--token T]` — mount this agent as an A2A
  // endpoint (Phase 5b). Uses the fully-resolved model/key/provider. The
  // endpoint also accepts cross-machine fabric mail (issue #27 phase 3):
  // inbound faMail envelopes deposit into this project's file inboxes.
  if (serve.serveA2a) {
    final port = _serveFlagInt(args, '--port', 8300);
    final token = _serveFlagStr(args, '--token');
    final projectFabric = _projectMessagingRepository(
      env: cliEnv,
      sessionRoot: sessionRoot,
      homeDir: home,
    );
    await _serveA2a(
      model: model,
      provider: provider,
      apiKey: apiKey,
      port: port,
      token: token,
      mailSink: (envelope) =>
          A2aMailGateway.accept(envelope, fabric: projectFabric),
    );
    exit(0);
  }
  // `fa serve --bridge [--port N] [--token T]` — mount the loopback
  // browser bridge over this project's messaging fabric. The token comes
  // from --token or `.fah/bridge/token` (mint-if-absent, mode 0600).
  if (serve.serveBridge) {
    final port = _serveFlagInt(args, '--port', bridgeDefaultPort);
    final tokenFlag = _serveFlagStr(args, '--token');
    await runBridgeServer(
      messaging: _projectMessagingRepository(
        env: cliEnv,
        sessionRoot: sessionRoot,
        homeDir: home,
      ),
      root: cwd,
      port: port,
      token: tokenFlag,
      version: packageVersion,
    );
    exit(0);
  }
  // `late` so the onProviderChanged closure can reach the agent (to attach
  // the secret redactor on a runtime token) before the variable is assigned.
  late final AgentCli cli;
  // The live third-party skills consent (`skills:` config section): the
  // startup dialog and `/skills access` change it — persisted via
  // persistConfig.
  var skillsAccess = saved.skillsAccess;
  // The RUNTIME `tools:` availability scope: the `--tools` flag wins over
  // the `FA_TOOLS` env twin (the flag is already parsed into
  // effective.tools). A malformed env spec is a hard startup error — a
  // typo must never silently enable a tool the user meant to disable.
  ToolsConfig? runtimeTools;
  try {
    final flagTools = effective.tools;
    runtimeTools = flagTools != null && !flagTools.isEmpty
        ? flagTools
        : toolsSpecFromEnv(Platform.environment);
  } on ConfigException catch (error) {
    _fail('invalid --tools/FA_TOOLS spec: ${error.message}');
  }

  // The tool-load preset (issue #680): `--omp` wins over the
  // `FA_AGENT_MODE` env twin, which wins over `agent.mode` config. An
  // unknown env/config label is a hard startup error — a typo must never
  // silently boot the default mode.
  AgentLoadMode loadMode;
  try {
    loadMode = resolveAgentLoadMode(
      flagOmp: effective.ompMode,
      envMode: Platform.environment['FA_AGENT_MODE'],
      configMode: saved.agentLoadMode,
    );
  } on ArgumentError catch (error) {
    _fail('invalid load mode: ${error.message}');
  }

  // Per-folder model memory: mirror the active triple into the folder's
  // state file (the LIVE cwd — a resumed session re-points `cliEnv.cwd`),
  // so the next `fa` in that folder restores this model, not the global
  // last-switch. Declared before `cli` because the model/provider change
  // callbacks below call it; `cli` is `late final` and only reached from
  // the closures after the assignment.
  Future<void> persistFolderModelState() async {
    await saveFolderModelState(
      cliEnv,
      sessionsRoot: sessionRoot,
      cwd: cliEnv.cwd,
      providerKind: cli.providerKind,
      modelId: cli.agent.state.model.id,
      baseUrl: cli.agent.state.model.baseUrl,
      // The active saved entry (gh-1000): the pin makes the next restore
      // land on the same account's key, not the first endpoint match.
      customProvider: cli.activeCustomProviderName,
    );
  }

  // The loopback browser-bridge handle: shared by `/browser connect` and
  // the browser tools' controller (the controller resolves lazily).
  final bridgeHandle = _FaBrowserBridgeHandle(
    env: cliEnv,
    sessionRoot: sessionRoot,
    homeDir: home,
    faVersion: packageVersion,
    providers: saved.customProviders,
    keys: keyCache,
  );

  // The execution env shared by the CLI config (tools, session storage)
  // and the presence store (live-session heartbeats) — see `cliEnv` above.
  // Backend agent mode (issue #155): `--output events[=full]` turns
  // stdout into a HEP v1 JSONL stream owned by the HepWriter; the CLI's
  // prose deltas are dropped (frames carry them) and diagnostics keep
  // flowing to their channel. `--attach` files ride the first user
  // message as image blocks.
  final eventsMode = headlessPrompt != null && parsed.output != null;
  // Stream-json mode (issue #695): `--output-format stream-json` (alias
  // `--mode json`) turns headless stdout into pi-shaped NDJSON agent
  // events owned by the StreamJsonWriter — same stdout-exclusivity rule
  // as HEP events mode: prose writes are dropped (the frames carry them),
  // diagnostics keep their stderr channel.
  final streamJsonMode =
      headlessPrompt != null && parsed.outputFormat == 'stream-json';
  final hep = eventsMode
      ? HepWriter(
          emit: _writeHepLine,
          fahVersion: packageVersion,
          toolArgs: parsed.output == 'events=full'
              ? HepToolArgs.full
              : HepToolArgs.summary,
          redactionPipeline: redactionPipeline,
        )
      : null;
  final streamJson = streamJsonMode
      ? StreamJsonWriter(emit: _writeStreamJsonLine)
      : null;
  final attachedImages = <ImageContent>[];
  final attachReferences = <String>[];
  for (final attachment in parsed.attachments) {
    final file = File(attachment);
    if (!file.existsSync()) {
      _fail('--attach: no such file: $attachment');
    }
    final bytes = file.readAsBytesSync();
    final mime = _sniffMime(bytes);
    if (mime == _unknownAttachMime) {
      // Not an image (magic-byte sniff missed): pass through as a path
      // reference — the same marker positional file-as-prompt uses — so
      // the agent opens it with its tools instead of a provider-rejected
      // octet-stream image block (issue #196).
      attachReferences.add(attachPathReference(file.absolute.path));
    } else {
      attachedImages.add(
        ImageContent(data: base64Encode(bytes), mimeType: mime),
      );
    }
  }
  if (eventsMode || streamJsonMode) {
    // Stdout purity: deltas ride frames; diagnostics keep their channel
    // (and still tee to --log-file via the wrapper chain).
    io = HepEventsIO(io);
  }

  // The TUI predicate, shared with the HID gate below: a headless run
  // never polls the HID state, so it never pays for the probe.
  final useTui =
      headlessPrompt == null && stdout.supportsAnsiEscapes && io.isInteractive;
  // Shift+Enter HID polling (issue #355): resolved ONCE at startup, off
  // the UI isolate — a CoreGraphics call wedged by a GUI-less session
  // (SSH) must never block the REPL. Null: modifier-encoding terminals
  // still deliver Shift+Enter on the wire (kitty, legacy ESC CR).
  final hidShiftPressed = useTui
      ? await resolveHidShiftPressed(isMacOS: Platform.isMacOS)
      : null;

  // The harness mode (issue #679): `--pi` wins over `FA_PI_MODE` wins
  // over the config `agent.mode` (AC3). `saved` is already loaded here;
  // the wiring consumes the resolved value via `config.agentMode`.
  // The parsed [CliArgs.piMode] is the single reader of the flag — a raw
  // argv scan disagrees when a value flag consumes the token
  // (`fa --model --pi` parses as `model: '--pi'`, `piMode: false`).
  final harnessMode = resolveHarnessMode(
    flag: parsed.piMode,
    env: Platform.environment,
    configMode: saved.agentMode,
  );

  // The ONE markdown-surface resolution for the process (issue #774):
  // the same resolution pins the palette the markdown engine and the CLI
  // styling emit, so the two can never diverge (NO_COLOR / TERM=dumb
  // fold to null here).
  final markdownSurface = resolveMarkdownSurface(
    ansiSupported: stdout.supportsAnsiEscapes,
    environment: Platform.environment,
    noFormatFlag: parsed.noFormat,
    width: io.columns,
  );

  // Fresh install (issue #969): an interactive REPL boot with NOTHING
  // configured — no saved custom providers, no persisted provider switch,
  // no explicit provider/model/endpoint declaration, no roles or queue
  // driving the boot, and no key resolving anywhere — opens the guided
  // add-provider wizard before the first prompt instead of the default
  // provider's "no key set" banner noise. Headless (-p / prompt args)
  // never gets the flag; its hard key gate stays byte-identical. Two
  // explicit boot modes are also excluded: a named `--session` resume is
  // never a fresh install, and the pi benchmark profile (`--pi` /
  // FA_PI_MODE / `agent.mode: pi`) must stay deterministic.
  final freshInstallProviderFlow =
      headlessPrompt == null &&
      !wireServe.wireServe &&
      !applyFolderModel &&
      parsed.model == null &&
      !parsed.providerExplicit &&
      parsed.baseUrl == null &&
      faPreconfig == null &&
      !defaultRoleResolved &&
      queueRuntime == null &&
      effective.session == null &&
      harnessMode == null &&
      saved.providerKind == 'openai-completions' &&
      saved.baseUrl == providerCatalog['openrouter']!.defaultBaseUrl &&
      // The customProviders emptiness mirrors the pure decision's first
      // check (startup.dart) on purpose: the unit-tested function owns the
      // semantics; the glue names the term it gates on for readability.
      saved.customProviders.isEmpty &&
      freshInstallProviderState(
        customProviders: saved.customProviders,
        keys: keyCache,
        env: Platform.environment,
      );

  cli = AgentCli(
    // Same source of truth as the palette (issue #778 round 2): chrome
    // (status line, keyhints, warnings) styles iff the resolved theme
    // profile exists — NO_COLOR / TERM=dumb degrade the whole session,
    // not just the markdown.
    useColor: headlessPrompt == null && markdownSurface.profile != null,
    environment: Platform.environment,
    useTui: useTui,
    version: packageVersion,
    // The double-press Ctrl+C window (issue #830): the 3 s contract, or
    // the kSigintWindowEnvVar test-seam override resolved HERE (the only
    // dart:io context — lib/src stays pure). One instance for both input
    // paths (ACX.5) rides the cli into the TUI.
    sigintPolicy: SigintPolicy(
      window:
          resolveSigintWindowOverride(env: Platform.environment) ??
          kSigintPressWindow,
    ),
    // Markdown parity (issue #774): every non-TUI surface renders
    // assistant markdown through ONE policy — resolveMarkdownSurface
    // above (pipes stay byte-identical raw; NO_COLOR / TERM=dumb degrade
    // to plain; --no-format / FA_NO_FORMAT (truthy values, like
    // FA_PI_MODE) force raw; width is the stdout terminal width at
    // process start, irrelevant in raw mode).
    markdownSurface: markdownSurface,
    config: AgentCliConfig(
      wakeExecutable: wakeExecutable(),
      // The dispatch below: a prompt argument is a headless run (autonomous
      // supervision default); an interactive REPL/TUI session defaults to
      // advisory — a human is present (gh-1054 review).
      headlessRun: headlessPrompt != null,
      // Marathon-session resume parses its multi-hundred-MB tail off the
      // UI isolate (issue #503); the isolate executor is IO-only.
      parseExecutor: const IsolateSessionParseExecutor(),
      // The folder state's saved provider entry (gh-1000 AC1): the CLI
      // starts with that entry active — its key slot serves the restored
      // model and its name shows in the status bar.
      activeCustomName: folderPinnedEntry?.name,
      model: model,
      apiKey: apiKey,
      providerKind: provider,
      redactionPipeline: redactionPipeline,
      spills: spillsConfig,
      // Shared by the env config and the presence store below.
      env: cliEnv,
      // fa_cube sandbox profile (Phase 1): clamps fs + shell ops to the
      // cube's policies; `/cube` inspects and switches it live. The OS
      // name feeds the backend description (lib/src stays dart:io-free).
      cubeSpec: cubeSpec,
      cubeSource: cubeSource,
      osName: Platform.operatingSystem,
      // Real-symlink resolution for the cube fs guard (lib/src stays
      // dart:io-free; the executable owns the probe).
      fsProbe: const LocalCubeFsProbe(),
      // The banner names the key env var in play (name only, never the
      // value); the catalog maps the effective provider to its var names.
      // A name counts as set when the environment OR the secure store has
      // it; the value resolves env-first.
      envVarIsSet: (name) =>
          (Platform.environment[name] ?? '').isNotEmpty ||
          keyCache.read(name) != null,
      // `/provider` resolves the target provider's key from the environment
      // (or the secure store) when no explicit token is passed.
      envVarValue: (name) {
        final value = Platform.environment[name];
        if (value != null && value.isNotEmpty) return value;
        return keyCache.read(name);
      },
      // `/key` manages the platform secure store; `/provider ... <token>`
      // persists the token there.
      secureKeys: keyCache,
      // Saved custom providers (`customProviders:` config section): the
      // picker lists them first, the wizard appends, /model rewrites the
      // active entry's last-used model — all persisted via persistConfig.
      // The registry folds same-auth-domain duplicates onto one record
      // (#706); each merge surfaces as a named boot note. stderr, never
      // stdout: in --output events mode stdout is the strict-JSONL HEP
      // stream, and headless answers read it too — a plain-text note
      // there corrupts the channel (same rule as [CliIO.writeln]'s
      // headless branch).
      customProviders: CustomProviderRegistry(saved.customProviders)
        ..mergeNotes.forEach(stderr.writeln),
      freshInstallProviderFlow: freshInstallProviderFlow,
      sessionRoot: sessionRoot,
      // Backend agent mode (issue #155): a graceful SIGTERM/SIGINT
      // cancel leaves a resumable partial transcript.
      persistAbortedPartials: eventsMode,
      // The same launch-pin rule the boot restore used: explicit
      // --model/--provider/--base-url or an FA_PROVIDER_* preconfig wins
      // over per-folder memory, including later session switches.
      folderModelStateApplies: applyFolderState || folderState == null,
      // Live-session presence: the running CLI heartbeats its session so
      // the Fa app (sharing the sessions root on macOS) marks it live and
      // can attach. Null where the root is process-local (tests).
      presenceStore: FileSessionPresenceStore(env: cliEnv, root: sessionRoot),
      processId: pid,
      // Sleep prevention (issue #325, oh-my-pi port): one assertion for
      // the whole session — caffeinate on macOS (bound to our pid by
      // `-w`), systemd-inhibit on Linux, a clean no-op elsewhere. The
      // runner is the injection seam: tests never get one, so no unit
      // test spawns a real helper.
      powerSleepPrevention:
          saved.powerSleepPrevention ?? PowerAssertionLevel.idle,
      powerRunner: hostPowerRunner(pid: pid),
      // Provider quota monitoring (issue #823): badge opt-in (default off)
      // + cache TTL; the http client stays the shared provider keep-alive.
      quotaBadge: saved.quota.badge,
      quotaTtl: Duration(minutes: saved.quota.ttlMinutes),
      sessionName: effective.session,
      visionConfig: visionConfig,
      transcribeConfig: transcribeConfig,
      webSearchConfig: WebSearchConfig(secrets: webSearch),
      sqliteEngine: const Sqlite3Engine(),
      // The lsp tool: the io-side process transport spawns `dart
      // language-server` (and any server from .fah/lsp.json); the host pid
      // lets servers exit when this process dies.
      lspConfig: LspToolConfig(
        transportFactory: ioLspTransportFactory,
        processId: pid,
      ),
      // MCP servers (`mcp:` config section): the io-side factory spawns
      // stdio servers; remote (HTTP) servers work everywhere. Servers
      // connect in the background and register mcp__<server>__<tool> tools.
      mcpConfig: saved.mcp == null
          ? null
          : McpToolConfig(
              config: saved.mcp!,
              transportFactory: ioMcpTransportFactory,
            ),
      // A2A remote agents (`a2a:` config section, Phase 5a): pure-Dart HTTP
      // client, connects lazily per server.
      a2aConfig: saved.a2a,
      // JS extensions (#32): per-extension isolated QuickJS engines — the
      // io-side runtime spawns `qjs` (FA_QJS_BIN override) speaking the
      // stdio transport. Engine absence degrades per-extension (E1), never
      // blocks boot.
      extRuntimeFactory: (_) => QjsProcessRuntime(),
      // `/browser connect` + the browser tools' controller: one handle
      // owning the loopback bridge over the launch-cwd fabric (both
      // implemented above).
      browserBridgeHandle: bridgeHandle,
      browserController: bridgeHandle.browserController,
      plugins: resolved.plugins,
      pluginConfig: resolved.config,
      hubFabric: resolved.hubFabric,
      // Fabric discovery (issue #27 phase 2): capabilities from the
      // `fabric:` config section; the OS hostname enables `name@machine`
      // addressing (null when the platform cannot name the host).
      agentCapabilities: saved.fabric?.capabilities ?? const [],
      machineName: _localMachineName(),
      promptTemplateDirs: promptTemplateDirs,
      initialMode: effective.mode!,
      systemPrompt: flagSystemPrompt,
      promptOverrides: promptOverrides,
      approvalMode:
          approvalModeFromLabel(saved.approvalMode) ?? ApprovalMode.yolo,
      alwaysAllowTools: saved.allowedTools.toSet(),
      runtimeTools: runtimeTools,
      agentMode: harnessMode,
      loadMode: loadMode,
      misuseBreaker: saved.misuseBreaker,
      compactionEngine: compactionEngine,
      compactionJudgeBudgetSeconds: compactionJudgeBudgetSeconds,
      wireDump: wireDump,
      contextWindowCap: saved.contextWindowCap,
      stuckTool: saved.stuckTool,
      subagents: saved.subagents,
      jobs: saved.jobs,
      // The gh-1198 thinking stream: the `--stream-thinking` flag wins
      // over the `output.streamThinking` config for this run.
      streamThinking: resolveStreamThinking(
        flag: parsed.streamThinking,
        configValue: saved.streamThinking,
      ),
      modelRolesResolver: rolesResolver,
      providersQueueRuntime: queueRuntime,
      // The live models config (`models:` section): `/models set`/`remove`
      // mutate its media slot overrides and `/model <name>` resolves its
      // custom model definitions — persisted via persistConfig. An absent
      // section starts as an empty config so the commands always work.
      modelsConfig: saved.models ?? ModelsConfig(),
      onModelsConfigChanged: () async => persistConfig(),
      homeDir: home,
      tuiTheme: saved.tuiTheme,
      // TTSR stream rules: user config (~/.fah/config.yaml `ttsr:`) merged
      // with project rules (.fah/rules.yaml), project first.
      ttsr: _resolveTtsr(saved, cwd),
      // Project-level .fah/config.yaml memory: wins over the user one.
      memoryConfig: loadProjectMemoryConfig(cwd) ?? saved.memory,
      // The saved cube default (the `cube:` section): the settings-hub
      // Cube sandbox flow rewrites it — persisted via persistConfig.
      cubeSettings: saved.cube,
      onCubeSettingsChanged: () async => persistConfig(),
      // DAP / Hub settings flow: the snapshot seam resolves the effective
      // config (env > `hub:` section > `~/.dap/config.json` > defaults)
      // through the hub client and overlays the live plugin status — local
      // reads only, never a network dial. A missing/failed probe keeps the
      // flow honest about the state.
      dapHubState: () async {
        // Single parse source: the same loaded packages.yaml map the
        // plugin system consumes (loadPackagesConfig already flattened
        // the yaml tree to plain Dart values).
        final hubSection = resolved.config['hub'];
        final settings = resolveDapSettings(
          config: HubConfig.fromMap(
            hubSection is Map<String, dynamic> ? hubSection : const {},
            Platform.environment,
          ),
          environment: Platform.environment,
        );
        try {
          final status = await hubPlugin.status();
          return DapHubSnapshot(
            supported: true,
            url: status.url ?? settings.url,
            name: status.name ?? settings.name,
            agentId: status.agentId,
            channels: status.channels,
            connected: status.connected,
          );
        } on Object {
          // The plugin never started (opted out, or the connect failed):
          // report the resolved config without a live connection.
          return DapHubSnapshot(
            supported: true,
            url: settings.url,
            name: settings.name,
            channels: const [],
            connected: false,
          );
        }
      },
      onDapHubConfigChanged: ({url, name}) =>
          persistDapConfig(url: url, name: name, file: defaultDapConfigFile()),
      onModelChanged: (_) async {
        await persistConfig();
        await persistFolderModelState();
      },
      // `/provider` switches: redact an explicitly passed session token so
      // it cannot leak into tool results or session files, then persist the
      // new provider/model/baseUrl triple (never the key itself).
      onProviderChanged: (kind, key) async {
        if (key.isNotEmpty) {
          redactor.register('/provider token', key);
          redactionPipeline?.registerSecret(key);
          // A keyless startup never attached the redactor; a runtime token
          // still gets masked from here on.
          if (!redactorAttached) {
            attachSecretRedactor(cli.agent, redactor);
            redactorAttached = true;
          }
        }
        await persistConfig();
        await persistFolderModelState();
      },
      // `/key set` stored a secret: mask it from here on (same lazy attach).
      onSecretStored: (name, value) {
        redactor.register(name, value);
        redactionPipeline?.registerSecret(value);
        if (!redactorAttached && !redactor.isEmpty) {
          attachSecretRedactor(cli.agent, redactor);
          redactorAttached = true;
        }
      },
      // `request_secret` tool granted a secret: same redactor lazy attach.
      onSecretGranted: (name, value) {
        redactor.register(name, value);
        redactionPipeline?.registerSecret(value);
        if (!redactorAttached && !redactor.isEmpty) {
          attachSecretRedactor(cli.agent, redactor);
          redactorAttached = true;
        }
      },
      onModeChanged: (_) async => persistConfig(),
      onApprovalChanged: () async => persistConfig(),
      // Global `tools:` toggles (`/tools <id> global`): the CLI owns the
      // live scope; persistConfig writes it back (see below).
      onToolsConfigChanged: () async => persistConfig(),
      // Third-party skills consent (`skills:` config section): the startup
      // dialog and `/skills access` set it; shell `!`cmd`` injections in
      // skill bodies follow `disableShellExecution`.
      skillsAccess: saved.skillsAccess,
      skillsDisableShellExecution: saved.skillsDisableShellExecution,
      // Global per-skill toggles (`skills:` config section, issue #1151):
      // the CLI owns the live view; persistConfig writes it back.
      skillToggles: saved.skillToggles,
      onSkillsAccessChanged: (access) async {
        skillsAccess = access;
        await persistConfig();
      },
      onSkillTogglesChanged: () async => persistConfig(),
      // Shift+Enter in the TUI: HID polling when the startup gate allows
      // it (issue #355) — null over SSH, under FA_TUI_SHIFT_HID=0, after
      // a probe timeout, and on non-macOS hosts.
      isShiftPressed: hidShiftPressed,
      // Mouse capture is ON by default (wheel scrolls the session view —
      // in the alternate screen the terminal has no native scrollback, so
      // without capture two-finger scroll does nothing). FA_TUI_MOUSE=0
      // opts out for always-on native select-to-copy.
      tuiMouseCapture: _envNotFalsy('FA_TUI_MOUSE'),
      // DEC 2026 synchronized output: auto-detect by default; FA_TUI_SYNC
      // forces it on (terminals without DECRQM answers) or off (fallback).
      tuiSyncOutput: _envTristate('FA_TUI_SYNC'),
      // The omp band composer (#806): on unless `tui.classic: true` pins
      // the legacy chrome byte-identically.
      tuiClassic: saved.tuiClassic,
      statusLine: saved.statusLine,
      agentLoadMode: saved.agentLoadMode,
    ),
    io: io,
  );
  if (redactorAttached) attachSecretRedactor(cli.agent, redactor);

  // Issue #823: boot builds the queue runtime before the CLI (and its
  // quota service) exist — rebind once so depletion hints steer the
  // resolver from the first turn. No-op without a configured queue.
  await cli.attachProviderQueueQuotaFeed();

  persistConfig = () async {
    await saveCliConfig(
      home,
      CliConfig(
        // The provider/model triple is per-folder now (folder_model_state):
        // keep the LOADED seed in the global config so a `/model` or
        // `/provider` switch in one workspace never leaks into the others
        // across restarts — the switch persists through the folder's state
        // file instead, and explicit --model/--provider/--base-url still
        // win per launch.
        providerKind: saved.providerKind,
        modelId: saved.modelId,
        baseUrl: saved.baseUrl,
        mode: cli.currentMode.name,
        approvalMode: cli.approval.mode.label,
        allowedTools: cli.approval.alwaysAllowedTools,
        // Prompt overrides are static per session; keep the loaded raw map
        // so saving doesn't drop the section.
        promptOverrides: saved.promptOverrides,
        // Roles: the live resolver's config (a `/model` switch re-pins the
        // default chain, the settings-hub agent-models flow pins the
        // smol/subagent chains — possibly creating the resolver on demand).
        modelRoles: cli.config.modelRolesResolver?.config ?? saved.modelRoles,
        // TTSR rules are static per session; keep the loaded config so
        // saving doesn't drop the section.
        ttsr: saved.ttsr,
        // Saved custom providers (the live registry the CLI mutates).
        customProviders:
            cli.config.customProviders?.entries ?? saved.customProviders,
        // Models config (the live instance `/models set`/`remove` mutates).
        models: cli.config.modelsConfig ?? saved.models,
        // MCP servers (the live config — re-read on `/mcp reload`).
        mcp: cli.config.mcpConfig?.config ?? saved.mcp,
        // Third-party skills consent (mutable via the startup dialog and
        // `/skills access`); shell-execution policy is static per session.
        skillsAccess: skillsAccess,
        skillsDisableShellExecution: saved.skillsDisableShellExecution,
        // The live global `skills:` toggles (read from the loaded config,
        // updated by `/skills <name> global`); null before the first
        // resolution, in which case the loaded section is kept as-is.
        skillToggles: cli.globalSkillToggles ?? saved.skillToggles,
        // The saved cube default (the live value the Cube sandbox flow
        // rewrites; `saved.cube` keeps the section when nothing changed).
        cube: cli.config.cubeSettings ?? saved.cube,
        // The live global `tools:` scope (read at boot, updated by
        // `/tools <id> global`); null until the first availability
        // rebuild, in which case the loaded section is kept as-is
        // (project/runtime scopes stay live and are never persisted).
        tools: cli.globalTools ?? saved.tools,
        // The remaining static sections are carried through the save so
        // the whole-file rewrite cannot drop them (issue #288 audit); a
        // forgetful caller is additionally backstopped by saveCliConfig's
        // disk-block preservation. The compaction engine is deliberately
        // NOT carried: the settings-hub Compaction flow's session scope
        // promises "no file change", and its project/global scopes write
        // the yaml through the targeted upsert themselves — persisting
        // the live override here would leak a session (or project) pick
        // into ~/.fah/config.yaml on the next boot or change hook. The
        // on-disk `compaction:` block survives via the preservation
        // backstop instead.
        memory: saved.memory,
        redact: saved.redact,
        a2a: saved.a2a,
        providerTimeouts: saved.providerTimeouts,
        images: saved.images,
        fabric: saved.fabric,
        // Static per session: keep the loaded `power:` section so a save
        // never drops the user's sleep-prevention level.
        powerSleepPrevention: saved.powerSleepPrevention,
      ),
    );
  };

  try {
    await persistConfig();
  } on ConfigException catch (error) {
    // Issue #221 E3: an unparseable config.yaml makes the save refuse
    // loudly instead of clobbering the file with defaults. Keep running
    // with the in-memory config; the user's file stays untouched.
    stderr.writeln('warning: config not saved: $error');
  }

  Future<void> resetTerminalForShell() async {
    if (!stdin.hasTerminal) return;
    stdout.write('\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l');
    stdout.write('\x1b[?1004l\x1b[?2004l');
    stdout.write('\x1b[?25h\x1b[?1049l');
    await stdout.flush();
    // Drain any pending terminal query/mouse responses so they don't echo
    // as garbage at the shell prompt.
    try {
      final drain = stdin.listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await drain.cancel();
    } on Object {
      // Nothing to drain.
    }
  }

  // Double-press Ctrl+C exit, interactive arm (issue #830): SIGINT-parity
  // teardown the TUI's ctrl+c press 2 also triggers via
  // [AgentCli.onCtrlCExitRequest] — abort-if-running bounded, session
  // resume hint, exit 130. The exit code is guaranteed: teardown steps
  // may not throw the caller into an unhandled-error death, so the whole
  // body runs under finally (the old single-press path's safety net).
  Future<void> exitInteractive130() async {
    try {
      terminalIo.resetRawMode();
      stdout.writeln();
      // Restore terminal modes (mouse tracking off, alt-screen exit,
      // cursor show) BEFORE exit(130) — otherwise the shell prompt
      // inherits mouse reporting and wheel scrolls print escapes.
      await resetTerminalForShell();
      if (cli.isBusy) {
        terminalIo.fireInterrupt();
        await cli.waitForIdle();
      }
      await cli.deleteSessionIfEmpty();
      // Real stdout, not io: the TUI is being torn down by this very
      // exit — an io-routed line would land in a dead transcript. A
      // session with nothing persisted prints the honest no-op line —
      // "resume this session with ..." would point at a deleted file.
      final hint = await cli.sessionResumeHint();
      stdout.writeln(hint ?? kNothingToResumeHint);
      await stdout.flush();
    } finally {
      exit(130);
    }
  }

  cli.onCtrlCExitRequest = () => unawaited(exitInteractive130());

  final sigintSub = ProcessSignal.sigint.watch().listen((_) {
    final wasBusy = cli.isBusy;
    switch (cli.sigintPolicy.press(
      headless: headlessPrompt != null || wireServe.wireServe,
    )) {
      case SigintAction.interruptAndStay:
        // Press 1 (issue #830): abort the in-flight run (bounded) and
        // STAY ALIVE — the next press inside the window exits. The TUI
        // gets the footer hint + idle-composer clear via the model; line
        // mode prints a dim stderr line.
        if (wasBusy) terminalIo.fireInterrupt();
        final tui = cli.tuiController;
        if (tui != null) {
          tui.armInterruptHint();
        } else {
          stderr.writeln(
            dimCtrlCExitHint(supportsAnsiEscapes: stdout.supportsAnsiEscapes),
          );
        }
      case SigintAction.exitInteractive:
        unawaited(exitInteractive130());
      case SigintAction.exitHeadless:
        // Headless graceful abort (issue #155): fire the interrupt, then
        // let the RUN settle — [AgentCli.waitForIdle] tracks the REPL's
        // settle future, which headless never starts, so the run future
        // itself is the honest wait: abort lands, the partial transcript
        // persists, the HEP writer emits `cancelled`, THEN exit 130.
        _gracefulHeadlessExit(terminalIo.fireInterrupt);
    }
  });
  // Backend supervisors send SIGTERM (issue #155): route it through the
  // same graceful abort as SIGINT — partial persist + `cancelled` frame +
  // exit 130 — instead of dying mid-write. A second SIGTERM escalates
  // (graceful → forced), the usual supervisor contract. [stdout.flush]
  // matters: exit() drops the async write buffer, taking the just-written
  // `cancelled` frame with it.
  if (headlessPrompt != null) {
    ProcessSignal.sigterm.watch().listen((_) {
      if (_sigtermSeen) exit(143);
      _sigtermSeen = true;
      _gracefulHeadlessExit(terminalIo.fireInterrupt);
    });
  }

  // `fa wire-serve` (issue #1103): headless Agent Wire Protocol v1
  // server. SIGINT/SIGTERM: both route through _gracefulHeadlessExit,
  // whose fireInterrupt aborts any in-flight run and whose
  // _wireServeSettle call ends the transport — runWireServe's finally
  // persists, and this branch's `exit(code)` continuation (registered
  // before _gracefulHeadlessExit's) wins the race: a graceful server
  // shutdown is a success, exit 0 (143 on a second SIGTERM, the usual
  // supervisor escalation).
  if (wireServe.wireServe) {
    var sigtermSeen = false;
    final sigtermSub = ProcessSignal.sigterm.watch().listen((_) {
      if (sigtermSeen) exit(143);
      sigtermSeen = true;
      _gracefulHeadlessExit(terminalIo.fireInterrupt);
    });
    final int code;
    try {
      code = await (_headlessRun = _runWireServeHost(
        cli: cli,
        wireServe: wireServe,
        terminalIo: terminalIo,
      ));
    } finally {
      await sigtermSub.cancel();
      await sigintSub.cancel();
      await stdout.flush();
      logTeeFile?.closeSync();
    }
    exit(code);
  }

  if (headlessPrompt != null) {
    _headlessRun = cli.runHeadless(
      attachReferences.isEmpty
          ? headlessPrompt
          // Non-image --attach files pass through as path references
          // appended to the prompt (issue #196).
          : '$headlessPrompt\n\n${attachReferences.join('\n\n')}',
      images: attachedImages,
      hep: hep,
      streamJson: streamJson,
      waitForJobs: effective.waitForJobs,
    );
    final int code;
    try {
      code = (await _headlessRun)!;
    } finally {
      await sigintSub.cancel();
      await stdout.flush();
      logTeeFile?.closeSync();
    }
    exit(code);
  }

  try {
    await cli.run();
  } finally {
    await sigintSub.cancel();
    logTeeFile?.closeSync();
  }

  // dart_tui's shutdown writes the reset sequences (?25h ?1049l ?1002l etc.)
  // and flushes stdout, but on some terminals the mouse-tracking disable
  // (?1002l ?1006l) arrives too late or is lost. Write them again here with
  await resetTerminalForShell();
  exit(0);
}

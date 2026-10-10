// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

part of 'agent_service.dart';

/// Backend wiring of [AgentService]: the stream-function picker, the
/// redaction + approval attachment, the skills/tools consent setters,
/// the system-prompt composition, and the secret-request host
/// handlers. The private state they drive stays on the class in
/// `agent_service.dart` (extensions hold no instance state; same
/// library, so private members resolve).
extension AgentServiceWiring on AgentService {
  /// Picks the stream function for [config]'s backend: the on-device
  /// bridges for `webllm`/`gemma`/`transformers_js`, the HTTP adapters
  /// otherwise. HTTP adapters get the live session id as the prompt-cache
  /// affinity key (resolved lazily — the session is created after this).
  StreamFunction _streamFunctionFor(AgentConfig config) {
    if (config.providerKind == webLlmProviderKind) {
      return webLlmStreamFunction(createWebLlmService());
    }
    if (config.providerKind == gemmaProviderKind) {
      return gemmaStreamFunction(createGemmaService());
    }
    if (config.providerKind == transformersJsProviderKind) {
      return transformersJsStreamFunction(createTransformersJsService());
    }
    // CodeMie: the cookie rides in model.headers (set by toModel); pass an
    // empty key so the adapter skips `Authorization: Bearer`.
    final apiKey = isCodeMieProvider(config.baseUrl) ? '' : config.apiKey;
    // Issue #327: provider auth failures surface the owning row's name —
    // a bare `401: No cookie auth credentials found` gives the user no
    // idea WHICH provider row to fix. On-device bridges keep raw errors.
    return decorateAuthErrors(
      providerStreamFunction(
        config.providerKind,
        apiKey,
        sessionId: () => _session?.cachedId,
      ),
      () => _connectionDisplayName(
        _providerRegistry,
        config.baseUrl,
      ), // null = pass-through, no registry row to name.
    );
  }

  /// Composes redaction hooks onto the agent so secret values never reach
  /// the model, the transcript, or the session files. Attached even for an
  /// empty redactor: `request_secret` grants register values at runtime and
  /// must be masked from that point on (an empty redactor's hooks are a
  /// cheap pass-through).
  void _attachRedactor(
    SecretRedactor? redactor, [
    Map<String, String> bootSecrets = const {},
  ]) {
    // Seed for the live re-enable ([AgentServiceAppConfig]).
    if (bootSecrets.isNotEmpty) _bootSecrets = bootSecrets;
    if (redactor == null) return;
    attachSecretRedactor(_agent, redactor);
    // The layered pipeline (issue #24), now config-driven (AC4); a
    // yaml-disabled one stays null, exactly like the CLI.
    if (_yamlRedactConfig is RedactionConfig && !_yamlRedactConfig!.enabled) {
      return;
    }
    _redactionPipeline ??= RedactionPipeline(
      registeredSecrets: [
        for (final value in bootSecrets.values)
          if (value.length >= SecretRedactor.minValueLength) value,
      ],
      config: _yamlRedactConfig ?? const RedactionConfig(),
    );
    attachRedactionPipeline(_agent, _redactionPipeline!);
  }

  /// Registers a secret into both masking systems (legacy exact redactor
  /// + the layered pipeline's registered layer).
  void _registerRedactionSecret(String name, String value) {
    _redactor?.register(name, value);
    _redactionPipeline?.registerSecret(value);
  }

  /// Attaches the approval gate. The prompt surface is [approvalPromptHandler]
  /// — installed by the chat screen, which owns a [BuildContext]; until then
  /// (and whenever it is unset) prompt-policy calls are denied, the safe
  /// default for a sandbox.
  void _attachApproval() {
    approval.prompt = (request) {
      final handler = approvalPromptHandler;
      if (handler == null) return ApprovalDecision.deny;
      return handler(request);
    };
    attachApproval(_agent, approval);
  }

  /// The composed registry's tool names, in registration order (issue
  /// #692 AC1 tests): pins the per-host availability floor — surfaces the
  /// sandbox cannot run (LSP, MCP servers, DAP, checkpoints, the sqlite
  /// engine) must be ABSENT from the app registry, not merely error at
  /// call time.
  @visibleForTesting
  List<String> get registeredToolNamesForTest => [
    for (final tool in _agent.state.tools) tool.name,
  ];

  /// Exposes the agent's registered tools to tests (ask-tool wiring checks).
  @visibleForTesting
  List<Tool> get toolsForTest => _agent.state.tools;

  /// Exposes the live system prompt to tests (memory-section checks).
  @visibleForTesting
  String get systemPromptForTest => _agent.state.systemPrompt;

  /// Exposes the live secrets env to tests (`request_secret` grant checks).
  @visibleForTesting
  SecretsExecutionEnv? get secretsEnvForTest => _secretsEnv;

  /// Exposes the redactor to tests (runtime secret registration checks).
  @visibleForTesting
  SecretRedactor? get redactorForTest => _redactor;

  /// The current consent for third-party skill discovery (`.claude`,
  /// `.github/skills`, `.codex`). Default: [SkillsAccess.granted].
  SkillsAccess get skillsAccess => _skillsAccess;

  /// Switches the third-party skills consent (the settings "Skills access"
  /// section, the boot dialog), persists it when a
  /// store is wired (fire-and-forget), then re-discovers skills under the
  /// new consent and recomposes the system prompt — like
  /// [_refreshMemorySection], no [reconfigure] needed. Services built from
  /// a pre-constructed [Agent] (tests) have no config: they record the
  /// choice but skip the re-discovery.
  Future<void> setSkillsAccess(SkillsAccess access) async {
    if (access == _skillsAccess) return;
    _skillsAccess = access;
    _notify();
    final store = _skillsAccessStore;
    if (store != null) unawaited(store.save(access));
    final config = _config;
    if (config == null) return;
    final (suffix, pinSkills) = await _discoverPromptSuffix(
      env,
      access,
      homeDir: _skillsHomeDir ?? desktopHomeDir(),
    );
    // A newer choice made while discovery ran wins — don't clobber it.
    if (access != _skillsAccess) return;
    _promptSuffix = suffix;
    // gh-1409: republish the operative-pin source set (derived state, P2).
    _agent.operativeSkills = pinSkills;
    _agent.state.systemPrompt = _composeSystemPrompt(config);
  }

  /// The base system prompt plus the skills/context suffix (kept as one
  /// place so model/provider switches preserve the sections).
  String _composeSystemPrompt(AgentConfig config) {
    final base = _effectiveAgentSystemPrompt(config, _redactor);
    final parts = [
      base,
      ?_projectMountNote(),
      if (_promptSuffix.isNotEmpty) _promptSuffix,
      if (_memorySection.isNotEmpty) _memorySection,
      if (_messagingSection().isNotEmpty) _messagingSection(),
    ];
    return parts.join('\n\n');
  }

  /// The `## Agent messaging` prompt section: the agent's own mailbox in
  /// the fabric + how discovery/addressing work. Empty until the session
  /// (and thus the mailbox prefix) exists.
  String _messagingSection() {
    final manager = _subagentManager;
    if (manager == null ||
        manager.messaging == null ||
        manager.mailboxPrefix.isEmpty) {
      return '';
    }
    return appMessagingSectionPrompt.replaceAll(
      '{{mailbox}}',
      manager.mailboxOf(manager.selfId),
    );
  }

  /// Re-reads the `<memory>` section from the memory stores and recomposes
  /// the prompt when it changed.
  Future<void> _refreshMemorySection() async {
    final controller = _memoryController;
    final config = _config;
    if (controller == null || config == null) return;
    final section = await controller.formatPromptSection();
    if (section == _memorySection) return;
    _memorySection = section;
    _agent.state.systemPrompt = _composeSystemPrompt(config);
  }

  /// The project-folder mount note for the system prompt (macOS): tells the
  /// model where the mounted project lives for file tools and the shell.
  String? _projectMountNote() {
    // [AgentService.create] always wraps the shared env in
    // [SecretsExecutionEnv]; look through it for the mount env.
    var env = this.env;
    if (env is SecretsExecutionEnv) env = env.delegate;
    if (env is! ProjectMountEnv) return null;
    final root = env.mountedRoot;
    if (root == null) return null;
    return 'A project folder is mounted at $projectMountSegment '
        '(host: $root). File tools take $projectMountSegment/... paths; '
        'shell commands work on the host path directly (cd $root).';
  }

  /// Recomposes the system prompt after the project-folder mount changes
  /// (the file browser's open/unmount flow).
  void refreshProjectMountPrompt() {
    final config = _config;
    if (config != null) {
      _agent.state.systemPrompt = _composeSystemPrompt(config);
    }
  }

  /// The memory LLM slot, resolved per call: the `smol` task-model override
  /// when one is set (settings change mid-session), else the main model.
  HarnessLlmSlot? _resolveMemoryLlmSlot() {
    final role = _taskRolesResolver?.resolveRole(smolModelRole);
    if (role != null) return role;
    return (model: _agent.state.model, stream: _agent.streamFunction);
  }

  /// UI hook that opens a JS app for the user — the chat screen installs it
  /// and pushes the app's `JsAppView`. Setting a non-null launcher registers
  /// the `open_app` tool (see `open_app_tool.dart`); setting `null`
  /// unregisters it, the safe headless default.
  AppLauncher? get appLauncher => _appLauncher;

  set appLauncher(AppLauncher? launcher) {
    if (launcher == _appLauncher) return;
    _appLauncher = launcher;
    final registry = _toolRegistry;
    if (registry != null) {
      if (launcher == null) {
        registry.unregister(openAppToolName);
      } else {
        registry.register(openAppTool(env, launcher: launcher));
      }
      _agent.state.tools = registry.tools;
    } else {
      // Pre-constructed agent (tests): mirror the registration on the
      // advertised tool list — the tool's execute callback is self-contained.
      final tools = _agent.state.tools
          .where((tool) => tool.name != openAppToolName)
          .toList();
      if (launcher != null) {
        tools.add(openAppTool(env, launcher: launcher));
      }
      _agent.state.tools = tools;
    }
  }

  /// Routes the ask tool's questions to the installed [askHandler].
  Future<List<AskAnswer>?> _answerAskQuestions(
    List<AskQuestion> questions,
  ) async {
    final handler = askHandler;
    if (handler == null) return null;
    return handler(questions);
  }

  /// Routes the `request_secret` tool to the installed
  /// [secretRequestHandler] and makes a grant live: persisted into the Keys
  /// store, injected into the running shell environment, and registered with
  /// the redactor — so the next run's system-prompt name list, bash `$NAME`
  /// expansion, and transcript redaction all pick it up.
  Future<RequestSecretResult?> _handleSecretRequest(
    String name,
    String reason,
  ) async {
    final handler = secretRequestHandler;
    if (handler == null) return null;
    final result = await handler(name, reason);
    if (result == null) return null;
    return acceptSecretGrant(result);
  }

  /// The merged host secrets the agent runs with (dotenv + saved keys +
  /// `request_secret` grants) — the read surface behind the JS apps'
  /// `jsr.fa.keys.list/get` bridge. Empty for services built around a
  /// pre-constructed [Agent].
  Map<String, String> hostSecrets() =>
      _secretsEnv?.secretsSnapshot() ?? const {};

  /// The Keys settings section is the production revocation path
  /// (gh-1444 E3): the store's ChangeNotifier fires on every save/delete
  /// and this reconcile mirrors the delta into the live env — a deleted
  /// name has its value revoked ([SecretsExecutionEnv.revokeSecret] keeps
  /// the NAME on the roster so `env` renders `NAME: ABSENT`), a saved name
  /// is (re-)injected. Names the store never carried (dotenv entries,
  /// `request_secret` grants) are never revoked by a store edit.
  void _reconcileSessionKeySecrets() {
    final env = _secretsEnv;
    final store = _sessionKeys;
    if (env == null || store == null) return;
    final savedNames = store.names.toSet();
    for (final name in _storeSecretNames.difference(savedNames).toList()) {
      env.revokeSecret(name);
      _storeSecretNames.remove(name);
    }
    for (final name in savedNames) {
      final value = store.valueOf(name);
      if (value == null || value.isEmpty) continue;
      if (env.secretsSnapshot()[name] == value) continue;
      env.addSecrets({name: value});
      _registerRedactionSecret(name, value);
      _storeSecretNames.add(name);
    }
  }

  /// Persists and activates a credential the user granted through a
  /// host-rendered prompt: saved into the Keys store, injected into the
  /// running shell environment, and registered with the redactor — the
  /// post-grant half of the `request_secret` flow, reused by the JS apps'
  /// `jsr.fa.keys.request` bridge (the app view renders the same prompt
  /// sheet itself).
  Future<RequestSecretResult> acceptSecretGrant(
    RequestSecretResult result,
  ) async {
    // Services built around a pre-constructed Agent (tests) may have none of
    // these; the grant still applies for the caller, it just is not
    // persisted or injected — [RequestSecretResult.persisted] reflects that.
    await _sessionKeys?.set(result.name, result.value);
    _secretsEnv?.addSecrets({result.name: result.value});
    _registerRedactionSecret(result.name, result.value);
    return RequestSecretResult(
      name: result.name,
      value: result.value,
      persisted: _sessionKeys != null,
    );
  }

  /// The user's per-tool availability choices (the app twin of the CLI
  /// `tools:` section; persisted via [ToolsAvailabilityStore]).
  ToolsConfig get toolsConfig => _toolsAvailability.config;

  /// Model id of the active backend, read live from the agent's model state;
  /// the settings Task models section uses it as the editor's placeholder.
  String get agentModelId => _agent.state.model.id;

  /// The agent's opt-in hub membership (issue #402) — surfaces read the
  /// live state and toggle the join from here.
  AgentNetworkController get agentNetwork =>
      _agentNetwork ?? (throw StateError('agentNetwork before initialize()'));
}

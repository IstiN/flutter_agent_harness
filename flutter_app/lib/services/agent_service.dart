import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:fa_ui/fa_ui.dart'
    show
        FaApprovalModeController,
        FaChatConnection,
        FaChatMessage,
        FaChatService,
        TrajectoryServiceFeed;
import 'package:fa_ui/fa_ui.dart' as fa_ui show emptyResponsePlaceholder;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'memory_config_loader.dart';
import 'agent_tool_availability.dart';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/apps/open_app_tool.dart';
import 'package:fa/sandbox/env_factory.dart';
import 'package:fa/services/approval_mode_store.dart';
import 'package:fa/services/platform_http_client.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/services/asr_tool.dart';
import 'package:fa/services/background_execution.dart';
import 'package:fa/services/calendar_service.dart';
import 'package:fa/services/calendar_tool.dart';
import 'package:fa/services/contact_service.dart';
import 'package:fa/services/contact_tool.dart';
import 'package:fa/services/apps_catalog_tool.dart';
import 'package:fa/services/health_service.dart';
import 'package:fa/services/health_tool.dart';
import 'package:fa/services/home_service.dart';
import 'package:fa/services/home_tool.dart';
import 'package:fa/services/icloud_sync_service.dart';
import 'package:fa/services/icloud_sync_tool.dart';
import 'package:fa/services/live_activity.dart';
import 'package:fa/services/media_models_store.dart';
import 'package:fa/services/media_tools.dart';
import 'package:fa/services/notify_service.dart';
import 'package:fa/services/notify_tool.dart';
import 'package:fa/services/task_models_store.dart';
import 'package:fa/services/video_service.dart';
import 'package:fa/services/video_tool.dart';
import 'package:fa/services/tools_availability_store.dart';
import 'package:fa/gemma/gemma_service.dart';
import 'package:fa/gemma/gemma_stream_function.dart';
import 'package:fa/gemma/gemma_types.dart';
import 'package:fa/services/project_mount_env.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/sessions_root.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/skills_access_store.dart';
import 'package:fa/prompts.g.dart';
import 'package:fa/sandbox/sandbox_registry.dart';
import 'package:fa/services/secrets_store.dart';
import 'package:fa/transformers_js/transformers_js_service.dart';
import 'package:fa/transformers_js/transformers_js_stream_function.dart';
import 'package:fa/transformers_js/transformers_js_types.dart';
import 'package:fa/services/upload.dart';
import 'package:fa/webllm/webllm_service.dart';
import 'package:fa/webllm/webllm_stream_function.dart';
import 'package:fa/webllm/webllm_types.dart';

part 'agent_service_compaction.dart';

/// A UI-facing chat message.
/// the adapter skips `Authorization: Bearer` when the key is empty.
bool isCodeMieProvider(String baseUrl) =>
    baseUrl.contains('/code-assistant-api/');

/// Shown in place of an assistant bubble when a completed turn produced
/// neither text nor tool calls — a small on-device model occasionally
/// returns an empty completion, and a blank bubble looks like a UI bug.
/// UI-only: the persisted session message keeps its real (empty) content.
/// Alias of the shared fa_ui constant.
const emptyResponsePlaceholder = fa_ui.emptyResponsePlaceholder;

/// A chat attachment already staged in the sandbox (see
/// [AgentService.stageAttachment]): [path] is the env-relative path the
/// outgoing message references; raster image attachments (see
/// [isInlineImageMimeType] — PNG/JPEG/GIF/WebP, never SVG) additionally
/// ride along inline for hosted providers.
typedef StagedAttachment = ({String path, Uint8List bytes, String mimeType});

/// Wraps an [Agent] for the Flutter chat UI.
///
/// Persists sessions to [sessionsRoot] via [JsonlSessionRepo] and translates
/// agent lifecycle events into a list of [FahChatMessage].
class AgentService extends ChangeNotifier
    implements FaChatConnection, FaApprovalModeController, FaChatService {
  AgentService({
    required this._agent,
    required this.env,
    required this.sessionsRoot,
    JsonlSessionRepo? repo,
    SecretRedactor? redactor,
    this._config,
    this._promptSuffix = '',
    Duration? responseTimeout,
    ApprovalMode? initialApprovalMode,
    @visibleForTesting bool watchExternalSessions = true,
  }) : _resolveSecretName = null,
       // ignore: prefer_initializing_formals
       _watchExternalSessions = watchExternalSessions,
       _secretsEnv = null,
       _sessionKeys = null,
       _taskModelsStore = null,
       _approvalModeStore = null,
       _skillsAccessStore = null,
       _skillsHomeDir = null,
       _skillsAccess = SkillsAccess.granted,
       _toolsAvailabilityStore = null,
       approval = ApprovalManager(
         mode: initialApprovalMode ?? ApprovalMode.write,
       ),
       _repo = repo ?? JsonlSessionRepo(fs: env, sessionsRoot: sessionsRoot) {
    _responseTimeout = responseTimeout ?? const Duration(seconds: 90);
    _providerKind = _agent.state.model.provider;
    // Seed the active endpoint from the model (reconfigure overwrites it) so
    // endpoint-aware UI never reads an uninitialized late field.
    _activeBaseUrl = _agent.state.model.baseUrl;
    _activeApiKey = '';
    _redactor = redactor;
    _attachRedactor(redactor);
    _attachApproval();
    _agent.subscribe(_onAgentEvent);
    // Pre-constructed-Agent path (tests): the caller owns the registry, so
    // availability still resolves (capabilities from the agent's own tools)
    // but the registry is not re-synced on toggle.
    _toolsAvailability = AgentToolAvailability(
      agent: _agent,
      tools: _agent.state.tools,
      onDevice: _isOnDeviceKind(_agent.state.model.provider),
      registry: null,
      rebuildPrompt: () {},
    );
  }

  /// Convenience factory that creates the right [ExecutionEnv] for the
  /// platform and wires up the agent.
  ///
  /// [env] overrides the platform env — the app passes its shared instance
  /// so the provider registry and the agent (and, on web, the IndexedDB
  /// snapshot persistence) all operate on one filesystem.
  ///
  /// [sessionKeys] / [providerRegistry] widen the named-secret resolution
  /// (media slot `apiKeyName` references) beyond the `.env` secrets store:
  /// user-saved keys (Keychain / `session_keys.json`) and custom-provider
  /// session keys resolve too.
  static Future<AgentService> create({
    required AgentConfig config,
    ExecutionEnv? env,
    SessionKeysStore? sessionKeys,
    ProviderRegistry? providerRegistry,
    TaskModelsStore? taskModelsStore,
    @visibleForTesting StreamFunction? streamFunction,
    @visibleForTesting bool watchExternalSessions = true,
    String? sessionsRoot,
  }) async {
    final resolvedEnv =
        env ?? await createPlatformEnv(httpClient: createPlatformHttpClient());
    final secretsStore = createSecretsStore();
    final secrets = mergeSecrets(await secretsStore.readAll(), sessionKeys);
    final approvalModeStore = ApprovalModeStore(resolvedEnv);
    final savedApprovalMode = await approvalModeStore.load();
    final skillsAccessStore = SkillsAccessStore(resolvedEnv);
    final savedSkillsAccess = await skillsAccessStore.load();
    final toolsAvailabilityStore = ToolsAvailabilityStore(resolvedEnv);
    final savedToolsConfig = await toolsAvailabilityStore.load();
    final redactor = SecretRedactor.fromSecrets(secrets);
    // Agent skills + project context files (AGENTS.md & friends) ride the
    // same ExecutionEnv, so they work on every platform (web sandbox too):
    // progressive disclosure — metadata in the prompt, bodies via `read`.
    // The timeout is not decorative: rootBundle.loadString of a > ~50 KB
    // asset never completes inside flutter_test's FakeAsync zone (its
    // real-IO completion never reaches the fake zone), and the contract
    // above says seeding must NEVER block session creation.
    try {
      await _seedBundledSkills(resolvedEnv).timeout(const Duration(seconds: 5));
    } on Object {
      // Best-effort seeding — continue without it.
    }
    final promptSuffix = await _discoverPromptSuffix(
      resolvedEnv,
      savedSkillsAccess ?? SkillsAccess.granted,
      homeDir: desktopHomeDir(),
    );
    // Always wrap: the `request_secret` tool injects user-granted keys into
    // the LIVE env at runtime (see [_handleSecretRequest]), so the wrapper
    // must be in place even when the boot-time secret set is empty.
    final secretsEnv = SecretsExecutionEnv(resolvedEnv, secrets);
    final resolvedSessionsRoot =
        sessionsRoot ?? defaultSessionsRoot(resolvedEnv.sessionCwd);
    return AgentService._withEnv(
      env: secretsEnv,
      secretsEnv: secretsEnv,
      sessionKeys: sessionKeys,
      config: config,
      redactor: redactor,
      bootSecrets: secrets,
      streamFunction: streamFunction,
      watchExternalSessions: watchExternalSessions,
      taskModelsStore: taskModelsStore,
      sessionsRoot: resolvedSessionsRoot,
      webSearchConfig: WebSearchConfig(secrets: secretsStore),
      initialApprovalMode: savedApprovalMode,
      approvalModeStore: approvalModeStore,
      initialSkillsAccess: savedSkillsAccess ?? SkillsAccess.granted,
      skillsAccessStore: skillsAccessStore,
      initialToolsConfig: savedToolsConfig,
      toolsAvailabilityStore: toolsAvailabilityStore,
      skillsHomeDir: desktopHomeDir(),
      // Live stores FIRST: a key edited in Settings must win over the
      // boot-time snapshot (the keychain write updates the registry, not
      // this map — boot map last so edited provider keys apply
      // immediately). The boot map still covers dotenv entries and
      // request_secret grants (it is runtime-mutable for those).
      resolveSecretName: (name) async =>
          providerRegistry?.keyValueForName(name) ??
          sessionKeys?.valueOf(name) ??
          secrets[name],
      promptSuffix: promptSuffix,
    );
  }

  /// Merges the named secrets the agent runs with: [dotenv] (the `.env`
  /// secrets store) first, then the user-saved [sessionKeys] entries
  /// OVERRIDE on conflict — an explicit save in the settings Keys section
  /// wins over the dev `.env`. The merged map feeds the bash environment
  /// ([SecretsExecutionEnv]), the [SecretRedactor], and the system prompt's
  /// "Available secret env vars" name list.
  @visibleForTesting
  static Map<String, String> mergeSecrets(
    Map<String, String> dotenv,
    SessionKeysStore? sessionKeys,
  ) {
    final merged = Map<String, String>.of(dotenv);
    if (sessionKeys != null) {
      for (final name in sessionKeys.names) {
        final value = sessionKeys.valueOf(name);
        if (value != null && value.isNotEmpty) merged[name] = value;
      }
    }
    return merged;
  }

  /// Writes bundled agent skills (see `assets/skills/`) into the env's
  /// project skill root so [discoverSkills] picks them up. Files are
  /// refreshed when the bundled content changed (the skills are ours, not
  /// user data). Best-effort: a missing asset or unwritable env must not
  /// block session creation.
  static Future<void> _seedBundledSkills(ExecutionEnv env) async {
    const bundled = {'js-apps': 'assets/skills/js-apps/SKILL.md'};
    for (final entry in bundled.entries) {
      try {
        final target = '.fah/skills/${entry.key}/SKILL.md';
        final bundledBody = await rootBundle.loadString(entry.value);
        final body = filterPlatformInstructions(
          bundledBody,
          platform: currentFaPlatform,
        );
        final existing = await env.readTextFile(target);
        if (existing.valueOrNull == body) continue;
        await env.writeFile(target, body);
      } on Object {
        // skip this skill
      }
    }
  }

  /// Discovers agent skills + project context files (AGENTS.md & friends)
  /// and renders the system-prompt suffix. Third-party skill roots
  /// (`.claude`, `.github/skills`, `.codex`) are read unless [access] is
  /// [SkillsAccess.denied] (or an explicit `ask` still awaiting its startup
  /// prompt) — discovery is on by default; only those restrict discovery to
  /// the first-party roots (`.fah/skills`, `.agents/skills`).
  static Future<String> _discoverPromptSuffix(
    ExecutionEnv env,
    SkillsAccess access, {
    String? homeDir,
  }) async {
    // User-level roots (~/.claude/skills, ~/.copilot/skills, ...) need the
    // real home directory - without it the desktop app only ever saw
    // project-local skills no matter what the consent said.
    final roots = defaultSkillRoots(
      cwd: env.cwd,
      homeDir: homeDir ?? desktopHomeDir(),
    );
    final skills = await discoverSkills(
      env,
      projectRoots: roots.projectRoots,
      userRoots: roots.userRoots,
      allowedSources: skillsAccessAllowsDiscovery(access, interactive: false)
          ? null
          : const {SkillSource.fah, SkillSource.agents},
    );
    final contextFiles = await loadProjectContextFiles(env);
    return [
      if (formatProjectContext(contextFiles).isNotEmpty)
        formatProjectContext(contextFiles),
      if (formatSkillsForPrompt(skills).isNotEmpty)
        formatSkillsForPrompt(skills),
    ].join('\n\n');
  }

  AgentService._withEnv({
    Map<String, String> bootSecrets = const {},
    required this.env,
    required AgentConfig config,
    required String sessionsRoot,
    SecretRedactor? redactor,
    WebSearchConfig? webSearchConfig,
    StreamFunction? streamFunction,
    bool watchExternalSessions = true,
    MediaKeyResolver? resolveSecretName,
    this._secretsEnv,
    this._sessionKeys,
    this._taskModelsStore,
    this._promptSuffix = '',
    ApprovalMode? initialApprovalMode,
    this._approvalModeStore,
    SkillsAccess? initialSkillsAccess,
    this._skillsAccessStore,
    ToolsConfig? initialToolsConfig,
    this._toolsAvailabilityStore,
    String? skillsHomeDir,
  }) // ignore: prefer_initializing_formals — private fields, public params
    // ignore: prefer_initializing_formals
    : _skillsHomeDir = skillsHomeDir,
       // ignore: prefer_initializing_formals
       _watchExternalSessions = watchExternalSessions,
       _config = config,
       _skillsAccess = initialSkillsAccess ?? SkillsAccess.granted,
       _resolveSecretName = resolveSecretName,
       approval = ApprovalManager(
         mode: initialApprovalMode ?? ApprovalMode.write,
       ),
       sessionsRoot = sessionsRoot,
       _repo = JsonlSessionRepo(fs: env, sessionsRoot: sessionsRoot) {
    _providerKind = config.providerKind;
    _activeBaseUrl = config.baseUrl;
    _activeApiKey = config.apiKey;
    _redactor = redactor;
    // CodeMie can be slow to start (long first-token latency); give it
    // more room than the standard 90s. On-device gets 10 min for shader
    // compilation / weight loading.
    _responseTimeout = _isOnDeviceKind(config.providerKind)
        ? const Duration(minutes: 10)
        : isCodeMieProvider(config.baseUrl)
        ? const Duration(minutes: 5)
        : const Duration(seconds: 90);
    // On-device backends have small context windows; keep only the core
    // coding tools so the tool-instruction block stays small.
    final isOnDevice = _isOnDeviceKind(config.providerKind);
    // Media generation gateway: resolves per-modality endpoints from
    // media_models.json with the ACTIVE connection as fallback (the closure
    // reads the mutable provider fields, so `reconfigure` is picked up).
    _mediaGateway = MediaGateway(
      env: env,
      fallback: () => MediaFallback(
        providerKind: _providerKind,
        baseUrl: _activeBaseUrl,
        modelId: _agent.state.model.id,
        apiKey: _activeApiKey,
      ),
      resolveKey: resolveSecretName,
    );
    // Video reading: frames via the `fah/video` channel, described by the
    // media_models.json `vision` slot (falling back to the main connection
    // when its model accepts images — the settings checkbox wins over the
    // id heuristic).
    _videoReader = VideoReader(
      video: createVideoService(),
      gateway: _mediaGateway!,
      mainSupportsImages: () =>
          _config?.supportsImages ??
          modelIdSuggestsVision(_agent.state.model.id),
    );
    // Session-correlation env vars (FAH_SESSION_ID/FILE/PROVIDER/MODEL) for
    // the bash tool, resolved live per exec; sits OUTSIDE the secrets
    // wrapper so neither layer can shadow the other (disjoint FAH_ names).
    final toolEnv = SessionVarsExecutionEnv(env, _sessionEnvVars);
    // Subagent + memory infrastructure (Phase 3a-3c): the task tool spawns
    // children, monitoring tools let the model query/steer them, memory tools
    // persist facts across sessions. The messaging fabric gives every agent
    // (main + children) a file inbox colocated with the sessions — any Fa
    // instance sharing this root can exchange messages with them.
    final messagesRoot =
        '$sessionsRoot/${encodeSessionCwd(env.sessionCwd)}/messages';
    final fabricRepo = FileMessagingRepository(
      env: env,
      root: messagesRoot,
      decodeSessionCwd: decodeSessionCwd,
      homeDir: null,
    );
    _scheduledMessages = ScheduledMessageQueue(
      env: env,
      repo: () => fabricRepo,
      root: () => messagesRoot,
    );
    // Arm the delivery timer; best-effort (an unwritable root keeps the
    // app booting, the tools just report unavailable).
    unawaited(_scheduledMessages.start());
    _subagentManager = SubagentManager(
      parentSessionId: '',
      messaging: fabricRepo,
      selfId: 'main',
    );
    // Real JSONL child sessions at completion (fast register keeps the
    // steering race away; transcript lands when the child finishes).
    Future<Session> childSessionFactory(String parentId, String childId) async {
      return _repo.create(
        JsonlSessionCreateOptions(
          cwd: env.sessionCwd,
          metadata: {
            'agent': 'subagent',
            'id': childId,
            'parent': parentId,
            'model': config.toModel().id,
          },
        ),
      );
    }

    _childSessionFactory = childSessionFactory;
    // Project-level .fah/config.yaml memory: wins over the user one.
    final memoryConfig = loadAppMemoryConfig(env.sessionCwd);
    _memoryController = MemoryController(
      env: env,
      // `memory:` section of ~/.fah/config.yaml — the same git-backed
      // memory path overrides the CLI honors (null = .fah/memory default).
      projectStoragePath: memoryConfig?.projectPath,
      userStoragePath: memoryConfig?.userPath,
      // Semantic search + consolidate() need an LLM: per call the smol
      // task-model override (resolver is built below — the closure reads it
      // lazily), else the main model.
      llmProvider: HarnessLlmProvider(resolve: () => _resolveMemoryLlmSlot()),
    );
    // Model-roles resolver backed by the TaskModelsStore: `smol` (compaction
    // + explore) and `subagent` (delegation) overrides resolve through it;
    // the Map reads the store lazily, so settings changes apply on the next
    // spawn without rebuilding the agent.
    final taskModelsStore = _taskModelsStore;
    if (taskModelsStore != null) {
      _taskRolesResolver = ModelRolesResolver(
        config: ModelRolesConfig(roles: _StoreBackedRolesMap(taskModelsStore)),
        secrets: _secretsEnv?.secretsSnapshot() ?? const {},
      );
    }
    // Task tool config: childTools is set after the full registry is built
    // (children inherit the core surface minus `task` itself). ONE shared
    // job manager across both configs (placeholder + final) so task_cancel
    // and the tool always see the same jobs.
    final taskJobManager = TaskJobManager();
    _taskConfig = TaskToolConfig(
      childTools: const [],
      streamFunction: streamFunction ?? _streamFunctionFor(config),
      model: config.toModel(),
      subagentManager: _subagentManager,
      jobManager: taskJobManager,
    );
    // Background shell jobs (bash background: true / steer-yielded commands).
    // Sandboxed environments without the BackgroundShell capability answer a
    // clean "not supported" note; completions re-enter via sendText (steer
    // mid-run, fresh turn while idle).
    _shellJobs = ShellJobRegistry(env: toolEnv, onSettled: _onShellJobSettled);
    final registry = ToolRegistry([
      ...builtinTools(
        toolEnv,
        webSearch: isOnDevice ? null : webSearchConfig,
        model: () => _agent.state.model,
        shellJobs: _shellJobs,
      ),
      ...memoryTools(
        _memoryController,
        onChanged: () => unawaited(_refreshMemorySection()),
      ),
      // schedule_message: self-addressed delayed notes, delivered by the
      // fabric's idle-wake (shared with the CLI).
      scheduleMessageTool(_scheduledMessages),
      ...subagentMonitoringTools(
        manager: _subagentManager,
        jobs: taskJobManager,
      ),
      // taskTool is registered AFTER the child surface is built (below).
      askTool(callback: _answerAskQuestions),
      // Secret requests: the agent asks the user for a missing credential
      // through the chat screen's bottom sheet; a grant is persisted into
      // the Keys store and made live (see [_handleSecretRequest]).
      requestSecretTool(callback: _handleSecretRequest),
      // System-calendar access (macOS/iOS via the `fah/calendar` channel;
      // the tools themselves report a clean note where unsupported).
      if (calendarPlatformSupported) ...[
        calendarEventsTool(createCalendarService()),
        calendarCalendarsTool(createCalendarService()),
        calendarAddTool(createCalendarService()),
        calendarUpdateTool(createCalendarService()),
        calendarDeleteTool(createCalendarService()),
      ],
      // System-contacts access (macOS/iOS via the `fah/contacts` channel;
      // the tools themselves report a clean note where unsupported).
      if (contactsPlatformSupported) ...[
        contactsSearchTool(createContactService()),
        contactsAddTool(createContactService()),
        contactsCallTool(createContactService()),
        contactsSmsTool(createContactService()),
      ],
      // Health data (iOS-only HealthKit via the `fah/health` channel; the
      // tool itself reports a clean note where unsupported).
      if (healthPlatformSupported) ...[
        healthSummaryTool(createHealthService()),
      ],
      // Home control (iOS-only HomeKit via the `fah/home` channel; the
      // tools themselves report a clean note where unsupported).
      if (homePlatformSupported) ...[
        homeDevicesTool(createHomeService()),
        homePowerTool(createHomeService(), turnOn: true),
        homePowerTool(createHomeService(), turnOn: false),
        homeSetTool(createHomeService()),
      ],
      // Microphone recording (macOS/iOS via the `fah/mic` channel; the
      // tool itself reports a clean note where unsupported). Pairs with
      // transcribe_audio below.
      if (asrPlatformSupported) micRecordTool(createAsrService(), env),
      // Local notifications (macOS/iOS via the `fah/notify` channel; the
      // tool itself reports a clean note where unsupported).
      if (notifyPlatformSupported) notifyTool(createNotifyService()),
      // iCloud Drive sync of the sandbox sessions/apps trees (macOS/iOS
      // via the `fah/icloud` channel; manual trigger, last-write-wins by
      // file mtime — the tool reports guidance when the container is
      // unavailable).
      if (icloudSyncSupported) icloudSyncTool(createICloudSyncService(env)),
      // Audio transcription via the media_models.json `transcription` slot
      // when configured, otherwise the active provider (Whisper
      // /audio/transcriptions) — resolved per call, so slot edits and
      // provider switches are picked up. Transcribes mic_record takes and
      // any audio file in the sandbox.
      if (!isOnDevice)
        transcriptionTool(
          env,
          () => whisperTranscriberForGateway(_mediaGateway!),
        ),
      // Media generation (image / TTS / music / video) against the
      // per-modality endpoints in media_models.json, falling back to the
      // main connection; the tools report an actionable error when the slot
      // has no usable endpoint. Skipped for the on-device backends, which
      // keep only the core coding tools (small tool-instruction block).
      if (!isOnDevice) ...[
        generateImageTool(_mediaGateway!),
        speakTool(_mediaGateway!),
        generateMusicTool(_mediaGateway!),
        generateVideoTool(_mediaGateway!),
        // Video reading through the `vision` slot (or the main connection
        // when its model accepts images); frames come from the `fah/video`
        // channel — the tool reports a clean note where unsupported.
        readVideoTool(env, _videoReader!),
      ],
      // The widgets catalog: browse / search read-tier; the write twin
      // (install / remove / get-source) rides the same surface gated by
      // the approval mode.
      appsCatalogTool(env: env),
      appsCatalogWriteTool(env: env),
    ]);
    _toolRegistry = registry;
    // Wire the task tool's child surface: all tools except `task` itself.
    final childSurface = registry.tools
        .where((t) => t.name != taskToolName)
        .cast<AgentTool>()
        .toList();
    _taskConfig = TaskToolConfig(
      childTools: childSurface,
      streamFunction: streamFunction ?? _streamFunctionFor(config),
      model: config.toModel(),
      rolesResolver: _taskRolesResolver,
      subagentManager: _subagentManager,
      childSessionFactory: _childSessionFactory,
      jobManager: taskJobManager,
    );
    // Re-register the task tool with the real child surface.
    registry.register(taskTool(config: _taskConfig!));
    _agent = Agent(
      model: config.toModel(),
      systemPrompt: _composeSystemPrompt(config),
      streamFunction: streamFunction ?? _streamFunctionFor(config),
      toolRegistry: registry,
    );
    // The main agent's inbox: messages from children (agent_message to
    // "main") and from other Fa instances arrive at turn boundaries.
    _agent.externalSteeringSource = _mainInboxMessages;
    // Non-draining probe for the same inbox: mid-run mail also triggers the
    // tool phase's soft-yield so a long bash/task call does not delay it.
    _agent.externalSteeringProbe = () async {
      final manager = _subagentManager;
      if (manager == null) return false;
      return await manager.pendingInboxCount(manager.selfId) > 0;
    };
    _attachRedactor(redactor, bootSecrets);
    _attachApproval();
    _agent.subscribe(_onAgentEvent);
    // Capability-gated tool availability (issue #19): capabilities follow
    // the actual wiring above, the gate hides/restores per config, and the
    // seeded store choices apply before the first run.
    _toolsAvailability = AgentToolAvailability(
      agent: _agent,
      tools: registry.tools,
      onDevice: isOnDevice,
      registry: registry,
      initialConfig: initialToolsConfig ?? const ToolsConfig(),
      rebuildPrompt: () {
        _agent.state.systemPrompt = _composeSystemPrompt(config);
      },
    );
    // Durable facts from past sessions join the prompt asynchronously
    // (memory stores initialize lazily; recompose on arrival).
    unawaited(_refreshMemorySection());
  }

  /// Whether [providerKind] is an on-device backend (WebLLM, Gemma, or
  /// transformers.js), which needs the relaxed response timeout.
  static bool _isOnDeviceKind(String providerKind) =>
      providerKind == webLlmProviderKind ||
      providerKind == gemmaProviderKind ||
      providerKind == transformersJsProviderKind;

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
    return providerStreamFunction(
      config.providerKind,
      apiKey,
      sessionId: () => _session?.cachedId,
    );
  }

  /// The system prompt plus a secret-name hint (names only, never values).
  ///
  /// The `{{commands}}` placeholder is filled from the central sandbox
  /// registry ([formatSandboxCommandSection]) for the current platform, so
  /// the model sees exactly the shell commands that exist here.
  static String _effectiveSystemPrompt(
    AgentConfig config,
    SecretRedactor? redactor,
  ) {
    final platform = _sandboxPlatform;
    final commandSection = formatSandboxCommandSection(platform);
    debugPrint(
      '[Fa] system prompt platform=$platform, '
      'commands section ${commandSection.length} chars',
    );
    final base = (config.systemPrompt ?? sandboxSystemPrompt).replaceAll(
      '{{commands}}',
      commandSection,
    );
    final names = redactor?.names ?? const <String>[];
    final now = DateTime.now();
    final offset = now.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final hh = offset.inHours.abs().toString().padLeft(2, '0');
    final mm = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    final dated =
        '$base\n\nCurrent date and time: ${now.toIso8601String()} '
        '(local device time, UTC$sign$hh:$mm). Use this for any date- or '
        'time-relative reasoning ("today", "tomorrow", "this week").';
    if (names.isEmpty) return dated;
    return '$dated\n\nAvailable secret env vars: ${names.join(', ')} — '
        'reference them as \$NAME in shell commands; never ask the user for '
        'their values and never print them.';
  }

  /// The platform whose commands the system prompt advertises, decided with
  /// the same signal [createPlatformEnv] uses to pick the [ExecutionEnv]:
  /// web → android / ios → desktop.
  static SandboxPlatform get _sandboxPlatform => isWebPlatform
      ? SandboxPlatform.web
      : isAndroidPlatform
      ? SandboxPlatform.android
      : isIosPlatform
      ? SandboxPlatform.ios
      : SandboxPlatform.desktop;

  /// Exposes [_effectiveSystemPrompt] to tests.
  @visibleForTesting
  static String effectiveSystemPromptForTest(
    AgentConfig config,
    SecretRedactor? redactor,
  ) => _effectiveSystemPrompt(config, redactor);

  /// Composes redaction hooks onto the agent so secret values never reach
  /// the model, the transcript, or the session files. Attached even for an
  /// empty redactor: `request_secret` grants register values at runtime and
  /// must be masked from that point on (an empty redactor's hooks are a
  /// cheap pass-through).
  void _attachRedactor(
    SecretRedactor? redactor, [
    Map<String, String> bootSecrets = const {},
  ]) {
    if (redactor == null) return;
    attachSecretRedactor(_agent, redactor);
    // The layered pipeline (issue #24) rides the same lifecycle: default
    // config (mask mode) — the app has no `redact:` yaml section yet. Its
    // registered layer starts from the boot secret values and grows with
    // every `request_secret` grant via [_registerRedactionSecret].
    _redactionPipeline ??= RedactionPipeline(
      registeredSecrets: [
        for (final value in bootSecrets.values)
          if (value.length >= SecretRedactor.minValueLength) value,
      ],
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

  /// The approval gate attached to the agent. Default mode is
  /// [ApprovalMode.write] — read-only tools run freely, mutating and shell
  /// tools prompt — switchable at runtime via [setApprovalMode] (settings
  /// dialog). Services built by [AgentService.create] seed it from the
  /// persisted choice (see [ApprovalModeStore]) and write every change
  /// through; the pre-constructed-Agent path (tests) keeps the default.
  @override
  final ApprovalManager approval;

  /// The persisted approval-mode store ([AgentService.create] path only);
  /// [setApprovalMode] writes through fire-and-forget.
  final ApprovalModeStore? _approvalModeStore;

  /// The current third-party skills consent ([AgentService.create] seeds it
  /// from [SkillsAccessStore], default [SkillsAccess.granted]).
  SkillsAccess _skillsAccess;

  /// The persisted skills-access store ([AgentService.create] path only);
  /// [setSkillsAccess] writes through fire-and-forget.
  final SkillsAccessStore? _skillsAccessStore;

  /// The tool-availability wiring (issue #19): capability floor + gate +
  /// live config, extracted to [AgentToolAvailability]. Built in both
  /// constructors, right after the agent exists.
  late final AgentToolAvailability _toolsAvailability;

  /// The persisted tools store ([AgentService.create] path only);
  /// [setToolEnabled] writes through fire-and-forget.
  final ToolsAvailabilityStore? _toolsAvailabilityStore;

  /// Home directory for user-level skill roots (desktop only; null on
  /// mobile/web). Null in tests keeps discovery deterministic.
  final String? _skillsHomeDir;

  /// UI hook rendering the approval prompt (the chat screen installs a
  /// Material dialog). `null` → prompt-policy calls are denied.
  @override
  ApprovalPrompt? approvalPromptHandler;

  /// UI hook rendering the ask tool's questions (the chat screen installs a
  /// Material bottom sheet). `null` → ask calls resolve as cancelled, the
  /// safe headless default.
  @override
  AskCallback? askHandler;

  /// UI hook rendering the `request_secret` prompt (the chat screen installs
  /// a Material bottom sheet). `null` → the request resolves as declined,
  /// the safe headless default.
  @override
  RequestSecretCallback? secretRequestHandler;

  /// The live secrets wrapper around [env] ([AgentService.create] path);
  /// `request_secret` grants are injected here so later bash calls see them.
  /// `null` for services built around a pre-constructed [Agent] (tests) or
  /// when [env] was not wrapped — the tool still works, the value just is
  /// not injected into the shell environment.
  final SecretsExecutionEnv? _secretsEnv;

  /// The user-saved keys store ([AgentService.create] path); `request_secret`
  /// grants persist here. `null` for the pre-constructed-[Agent] path — the
  /// tool still works, the value just is not persisted (the result text
  /// reflects that via [RequestSecretResult.persisted]).
  final SessionKeysStore? _sessionKeys;

  /// Per-task-role model overrides (`task_models.json`); `null` for services
  /// built around a pre-constructed [Agent] (tests). When the `smol` role
  /// carries an override, compaction uses that model instead of the main
  /// connection.
  final TaskModelsStore? _taskModelsStore;

  /// The registry built in [_withEnv]; `null` for services constructed
  /// around a pre-constructed [Agent] (tests), where the registry is owned
  /// by the caller.
  ToolRegistry? _toolRegistry;

  /// Subagent manager (Phase 3a): tracks spawned children for the task tool.
  SubagentManager? _subagentManager;

  /// The session's retained-subagent registry (null before the agent is
  /// built). The settings Agents section renders the live tree from it.
  SubagentManager? get subagentManager => _subagentManager;

  /// Task tool config (child surface set after registry is built).
  TaskToolConfig? _taskConfig;

  /// The memory LLM slot, resolved per call: the `smol` task-model override
  /// when one is set (settings change mid-session), else the main model.
  HarnessLlmSlot? _resolveMemoryLlmSlot() {
    final role = _taskRolesResolver?.resolveRole(smolModelRole);
    if (role != null) return role;
    return (model: _agent.state.model, stream: _agent.streamFunction);
  }

  /// The session's background shell jobs (bash background / steer-yield);
  /// null before the agent is built.
  ShellJobRegistry? _shellJobs;

  /// Model-roles resolver over the [TaskModelsStore] (`smol` + `subagent`
  /// overrides), lazily reflecting settings edits (Phase 3d).
  ModelRolesResolver? _taskRolesResolver;

  /// The completion-time child-session factory wired into the task tool
  /// (real JSONL sessions for `/agents open <id>` and the Agents panel).
  late Future<Session> Function(String, String) _childSessionFactory;

  /// Memory controller (Phase 1): durable cross-session memory.
  MemoryController? _memoryController;

  /// UI hook that opens a JS app for the user — the chat screen installs it
  /// and pushes the app's `JsAppView`. Setting a non-null launcher registers
  /// the `open_app` tool (see `open_app_tool.dart`); setting `null`
  /// unregisters it, the safe headless default.
  AppLauncher? get appLauncher => _appLauncher;
  AppLauncher? _appLauncher;

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

  /// Switches the approval mode (settings dialog's mode selector) and
  /// persists the choice when a store is wired (fire-and-forget — the UI
  /// never blocks on the write).
  @override
  void setApprovalMode(ApprovalMode mode) {
    if (approval.mode == mode) return;
    approval.mode = mode;
    notifyListeners();
    final store = _approvalModeStore;
    if (store != null) unawaited(store.save(mode));
  }

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
    notifyListeners();
    final store = _skillsAccessStore;
    if (store != null) unawaited(store.save(access));
    final config = _config;
    if (config == null) return;
    final suffix = await _discoverPromptSuffix(
      env,
      access,
      homeDir: _skillsHomeDir ?? desktopHomeDir(),
    );
    // A newer choice made while discovery ran wins — don't clobber it.
    if (access != _skillsAccess) return;
    _promptSuffix = suffix;
    _agent.state.systemPrompt = _composeSystemPrompt(config);
  }

  /// The user's per-tool availability choices (the app twin of the CLI
  /// `tools:` section; persisted via [ToolsAvailabilityStore]).
  ToolsConfig get toolsConfig => _toolsAvailability.config;

  /// The availability decision per known tool id (capabilities + config).
  Map<String, ResolvedToolAvailability> get toolAvailability =>
      _toolsAvailability.availability;

  /// Switches one tool's availability (the settings Tools section): the
  /// helper re-applies the resolution to the live registry (tool list and
  /// prompt update without a restart; an absent capability stays off),
  /// then this persists the choice when a store is wired (fire-and-forget).
  Future<void> setToolEnabled(String id, bool enabled) async {
    if (!_toolsAvailability.setEnabled(id, enabled)) return;
    notifyListeners();
    final store = _toolsAvailabilityStore;
    if (store != null) unawaited(store.save(_toolsAvailability.config));
  }

  late final Agent _agent;

  /// Persisted scheduled messages (`schedule_message` tool): delivered as
  /// idle mail by a timer; survives restarts (JSON under the messages
  /// root). Started best-effort after the service wires up.
  late final ScheduledMessageQueue _scheduledMessages;

  /// Response deadline for one agent run; 10 minutes for the on-device
  /// providers (WebLLM's and transformers.js's first run compiles WebGPU
  /// shaders; Gemma loads multi-GB weights), 90 s otherwise.
  /// Reassigned by [reconfigure] when the backend kind changes.
  late Duration _responseTimeout;
  final JsonlSessionRepo _repo;
  final String sessionsRoot;

  /// Provider adapter kind of the active backend (`openai-completions`,
  /// `webllm`, ...). Updated by [reconfigure].
  @override
  String get providerKind => _providerKind;
  late String _providerKind;

  /// Base URL of the active backend, tracked alongside [_providerKind] and
  /// updated by [reconfigure]; empty for the on-device providers. The
  /// settings Media models section uses it as the editor's
  /// placeholder/default.
  @override
  String get activeBaseUrl => _activeBaseUrl;

  /// Model id of the active backend, read live from the agent's model state;
  /// the settings Task models section uses it as the editor's placeholder.
  String get agentModelId => _agent.state.model.id;

  /// Reads the last [tail] messages of subagent [id]'s session as
  /// `(role, text)` pairs (settings Agents section → observe). Empty when
  /// the child session is unavailable or the id is unknown.
  Future<List<(String, String)>> observeSubagent(
    String id, {
    int tail = 20,
  }) async {
    final handle = _subagentManager?[id];
    if (handle == null) return const [];
    try {
      final metadata = SessionMetadata(
        id: handle.sessionId,
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
        cwd: env.sessionCwd,
        path: handle.sessionId,
      );
      final exists = await env.fileInfo(handle.sessionId);
      if (exists.valueOrNull == null) return const [];
      final session = await _repo.open(metadata);
      final messages = await session.buildContextMessages();
      final last = messages.length > tail
          ? messages.sublist(messages.length - tail)
          : messages;
      return [
        for (final message in last)
          (message.role, _previewMessageText(message)),
      ];
    } on Object {
      return const [];
    }
  }

  /// Sends a follow-up message to subagent [id] (settings Agents section →
  /// send): appends to the child session and marks it resumed. Falls back to
  /// the sibling pending-queue when the session is unavailable.
  Future<void> sendToSubagent(String id, String message) async {
    final handle = _subagentManager?[id];
    if (handle == null) {
      throw StateError('no subagent "$id"');
    }
    if (handle.status == SubagentStatus.failed ||
        handle.status == SubagentStatus.aborted) {
      throw StateError('cannot send to ${handle.status.name} subagent "$id"');
    }
    try {
      final metadata = SessionMetadata(
        id: handle.sessionId,
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
        cwd: env.sessionCwd,
        path: handle.sessionId,
      );
      final session = await _repo.open(metadata);
      await session.appendMessage(UserMessage.text(message));
    } on Object {
      // Fall back to the sibling pending queue when the session is gone.
      await _subagentManager!.enqueueMessage(
        id,
        SubagentMessage(
          fromId: 'parent',
          text: message,
          sentAt: DateTime.now().toUtc().toIso8601String(),
        ),
      );
      return;
    }
    await _subagentManager!.update(id, status: SubagentStatus.running);
  }

  static String _previewMessageText(Message message) {
    final Object raw = switch (message) {
      UserMessage(:final content) => content,
      AssistantMessage(:final content) =>
        content.whereType<TextContent>().map((b) => b.text).join('\n'),
      _ => '',
    };
    return raw is String ? raw.trim() : '$raw';
  }

  /// Fa does not track provider ids in the connection — the provider UI
  /// falls back to base-URL matching for the "current" mark.
  @override
  String? get activeProviderId => null;

  /// Base URL and API key of the active backend, tracked alongside
  /// [_providerKind] so the media gateway's fallback follows [reconfigure].
  late String _activeBaseUrl;
  late String _activeApiKey;

  /// Resolver for named secrets (media slot `apiKeyName` references);
  /// `AgentService.create` wires it to the `.env` secrets store, the
  /// saved-keys store, and the provider registry's session keys.
  final MediaKeyResolver? _resolveSecretName;

  /// Media generation gateway shared by the `generate_image` / `speak` /
  /// `generate_music` / `generate_video` tools and exposed for the
  /// `jsr.fa.media.*` bridge.
  /// `null` for services constructed around a pre-constructed [Agent]
  /// (tests).
  MediaGateway? get mediaGateway => _mediaGateway;
  MediaGateway? _mediaGateway;

  /// Video reader behind the `read_video` tool, exposed for the
  /// `jsr.fa.media.readVideo` bridge. `null` for services constructed
  /// around a pre-constructed [Agent] (tests).
  VideoReader? get videoReader => _videoReader;
  VideoReader? _videoReader;

  /// Model id of the active backend (shorthand for the agent's current
  /// model; updated by [reconfigure]).
  @override
  String get modelId => _agent.state.model.id;

  /// Redactor captured at construction so [reconfigure] can rebuild the
  /// system prompt's secret-name hint.
  SecretRedactor? _redactor;

  /// The layered redaction pipeline (issue #24), default config; built
  /// lazily on first attach from the redactor's registered values.
  RedactionPipeline? _redactionPipeline;

  /// Rendered skills + project-context sections appended to the composed
  /// system prompt (discovered in [AgentService.create]; re-discovered by
  /// [setSkillsAccess] when the third-party consent changes).
  String _promptSuffix;

  /// The base system prompt plus the skills/context suffix (kept as one
  /// place so model/provider switches preserve the sections).
  String _composeSystemPrompt(AgentConfig config) {
    final base = _effectiveSystemPrompt(config, _redactor);
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

  /// The cached `<memory>` prompt section (durable facts from past
  /// sessions), refreshed asynchronously after create and on every
  /// `memory_add` — the prompt composition itself stays synchronous.
  String _memorySection = '';

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

  /// The config this service was created with, kept so a new session can be
  /// cloned from it (see [clone]). `null` when the service was built from a
  /// pre-constructed [Agent] (tests).
  AgentConfig? get configForClone => _config;
  final AgentConfig? _config;

  /// The execution environment the agent's tools (and session storage) run
  /// against. Exposed so UI affordances — the file browser — show the exact
  /// filesystem the agent works in. Typed as the [ExecutionEnv] abstraction,
  /// never a concrete env, so alternative backends (in-memory web FS, cloud
  /// drives) drop in without UI changes.
  final ExecutionEnv env;

  @override
  ExecutionEnv get sandboxEnv => env;

  @override
  final List<FahChatMessage> messages = [];

  /// User messages typed while the agent is still streaming. They are queued
  /// via [Agent.steer] and injected at the next turn boundary; the UI shows
  /// them above the composer as "pending" until the run picks them up.
  @override
  final List<String> pendingSteerTexts = [];

  /// Tracks [TurnStartEvent]s within the current run so pending steering
  /// messages can be cleared right when a continuation turn begins.
  int _turnStartCount = 0;

  /// True while a run is streaming. Flipping it also manages the iOS
  /// extended-background-execution task (see [BackgroundExecution]) and the
  /// Live Activity (see [LiveActivity]): a run asks the OS for extra time
  /// and shows its status on the Dynamic Island / lock screen when the app
  /// is backgrounded mid-stream.
  @override
  bool get isStreaming => _isStreaming;
  set isStreaming(bool value) {
    if (value == _isStreaming) return;
    _isStreaming = value;
    if (value) {
      // A new run supersedes the previous run's pending Live Activity end.
      _liveActivityEndTimer?.cancel();
      _liveActivityEndTimer = null;
      unawaited(_beginBackgroundTask());
      // Keep the screen awake for the whole run — the OS must not lock the
      // phone mid-stream.
      unawaited(BackgroundExecution.setScreenAwake(true));
      unawaited(
        LiveActivity.start(
          sessionTitle: 'Fa agent run',
          statusText: _liveActivityStatusText(),
        ),
      );
    } else {
      unawaited(BackgroundExecution.setScreenAwake(false));
      final id = _backgroundTaskId;
      _backgroundTaskId = null;
      unawaited(BackgroundExecution.end(id));
      unawaited(_finishLiveActivity());
    }
  }

  bool _isStreaming = false;
  int? _backgroundTaskId;
  Timer? _liveActivityEndTimer;

  Future<void> _beginBackgroundTask() async {
    _backgroundTaskId = await BackgroundExecution.begin('agent-run');
  }

  /// Shows the final run state on the Live Activity briefly, then ends it.
  /// The microtask hop (NOT a zero-delay timer — it would linger as a
  /// pending FakeTimer in tests) lets the error paths assign [error]
  /// first — they flip [isStreaming] and set the message right after,
  /// synchronously. The end timer is tracked so [dispose] can cancel it
  /// (and skipped entirely under widget tests, where a pending 4 s timer
  /// fails the binding).
  Future<void> _finishLiveActivity() async {
    await Future<void>.microtask(() {});
    final failed = error != null;
    await LiveActivity.update(
      statusText: failed ? 'run failed' : 'done',
      isError: failed,
      isDone: true,
    );
    if (_inWidgetTest) {
      await LiveActivity.end();
      return;
    }
    _liveActivityEndTimer?.cancel();
    _liveActivityEndTimer = Timer(const Duration(seconds: 4), () {
      unawaited(LiveActivity.end());
    });
  }

  /// True under `flutter test` (binding class name; web-safe). False when
  /// no binding exists (plain dart tests — there the real event loop just
  /// runs the end timer out).
  static bool get _inWidgetTest {
    try {
      return WidgetsBinding.instance.runtimeType.toString().contains(
        'TestWidgetsFlutterBinding',
      );
    } on Object {
      return false;
    }
  }

  /// The Live Activity status line — mirrors the FaWorkBar derivation
  /// (current tool call, thinking, writing) so both surfaces agree.
  String _liveActivityStatusText() {
    for (final message in messages.reversed) {
      switch (message.role) {
        case 'system':
          return message.content.split('\n').first;
        case 'tool':
          return '[${message.toolName}] ✓';
        case 'thinking':
          return 'thinking…';
        case 'assistant':
          return 'writing…';
      }
    }
    return 'working…';
  }

  /// Pushes the current status line to the Live Activity; cheap no-op when
  /// no activity is live (and always off iOS).
  void _pushLiveActivityStatus() {
    if (!_isStreaming) return;
    unawaited(LiveActivity.update(statusText: _liveActivityStatusText()));
  }

  @override
  String? error;

  /// Builtin tools whose completion may mean the sandbox filesystem changed
  /// (the actual tool names in `builtinTools`: `write`, `edit`, `bash`).
  /// `bash` is included because a shell command can touch arbitrary files;
  /// failed results still bump — a partially-run command may have mutated
  /// files before failing.
  static const _kMutatingToolNames = {'write', 'edit', 'bash'};

  /// Filesystem revision: bumped whenever a mutating tool
  /// ([_kMutatingToolNames]) finishes, so UI watching the sandbox (the file
  /// browser) can auto-refresh instead of polling. Listeners must tolerate
  /// false positives — a bump does not prove a specific file changed.
  final ValueNotifier<int> fsRevision = ValueNotifier<int>(0);

  /// Fires when the OPEN session's JSONL changed from OUTSIDE this
  /// service (a running `fa` CLI appending to the same session): the
  /// transcript view reloads and shows the new rows. Not the same as
  /// [fsRevision] (sandbox files touched by OUR tools).
  final ValueNotifier<int> externalSessionRevision = ValueNotifier<int>(0);

  /// The external-append watcher (poll: the env abstraction has no file
  /// events). Null while idle or on platforms without file info. Disabled
  /// in widget tests (a pending periodic timer fails the test binding).
  Timer? _sessionWatchTimer;
  int _sessionWatchBytes = -1;
  final bool _watchExternalSessions;

  void _startSessionWatch() {
    _stopSessionWatch();
    if (!_watchExternalSessions) return;
    final file = _sessionFile;
    if (file == null) return;
    _sessionWatchBytes = -1;
    _sessionWatchTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_checkSessionFileGrew());
    });
  }

  Future<void> _checkSessionFileGrew() async {
    final file = _sessionFile;
    if (file == null || _disposed) return;
    final info = (await env.fileInfo(file)).valueOrNull;
    if (info == null) return;
    if (_sessionWatchBytes < 0) {
      _sessionWatchBytes = info.size;
      return;
    }
    if (info.size > _sessionWatchBytes) {
      _sessionWatchBytes = info.size;
      await _reloadExternalMessages();
      externalSessionRevision.value++;
    }
  }

  /// Pulls externally-appended rows into the visible transcript. Only
  /// while IDLE: mid-run the agent owns the state machine (streaming,
  /// tool calls) and a concurrent reload would corrupt it. The session
  /// storage parses the file ONCE at open — an external reload re-opens
  /// it fresh (cheap: header + tree index).
  Future<void> _reloadExternalMessages() async {
    final session = _session;
    if (session == null || isStreaming) return;
    try {
      final metadata = await session.getMetadata();
      final fresh = await _repo.open(metadata);
      final context = await fresh.buildContext();
      _session = fresh;
      _agent.state.messages = context.messages;
      _persistedCount = context.messages.length;
      messages
        ..clear()
        ..addAll(context.messages.map(_toChatMessage));
      await _rebuildTrajectory();
      notifyListeners();
    } on Object {
      // A torn read (the CLI mid-append): the next poll retries.
    }
  }

  void _stopSessionWatch() {
    _sessionWatchTimer?.cancel();
    _sessionWatchTimer = null;
  }

  Session? _session;
  String? _sessionId;
  String? _sessionFile;
  int _persistedCount = 0;

  /// The producer behind [trajectory]: rebuilt from the active branch on
  /// session open/switch, mirrored live from agent events, and fed the
  /// finalized records on every persist.
  final TrajectoryServiceFeed _trajectory = TrajectoryServiceFeed();
  FahChatMessage? _currentAssistantMessage;
  FahChatMessage? _currentThinkingMessage;

  /// Id of the session new messages persist to (`null` until [initialize]).
  String? get currentSessionId => _sessionId;

  /// The cwd of the OPEN session (from its on-disk metadata): the folder
  /// that conversation belongs to, regardless of the app's current mount
  /// (the env is shared across sessions; the session's own folder is not).
  /// Null until a session materializes.
  String? get currentSessionCwd => _sessionCwd;
  String? _sessionCwd;

  /// Session-correlation env vars injected into bash tool executions (see
  /// [SessionVarsExecutionEnv]). Read live per exec, so a session (re)load
  /// or a provider/model switch is picked up by later commands. Never
  /// secret values — ids, paths, provider kinds, model ids.
  Map<String, String> _sessionEnvVars() => {
    sessionIdEnvVar: ?_sessionId,
    sessionFileEnvVar: ?_sessionFile,
    providerEnvVar: _providerKind,
    modelEnvVar: _agent.state.model.id,
  };

  /// Initializes session persistence — WITHOUT creating an empty JSONL file.
  ///
  /// The session file (and the agent's mailbox address in the messaging
  /// fabric) are materialised lazily on the first [_persist] run; a service
  /// that is initialised but never receives a user message leaves no file
  /// behind. [loadSession] still creates an OS-backed [_session] for the
  /// restored session.
  Future<void> initialize() async {
    // The session FILE materialises lazily on the first persist (an
    // untouched session never hits the disk), but the id is allocated
    // eagerly: hosts (FlutterSessionManager) key sessions by id from the
    // moment the service exists, and the prompt's messaging section needs
    // the real mailbox address before the first message.
    if (_session == null && _sessionId == null) {
      final id = createSessionId();
      _sessionId = id;
      _subagentManager?.mailboxPrefix = id;
    }
    // Compose the system prompt eagerly — messaging address defaults to the
    // host's local id (`main`) until the session materialises (so a brand
    // new, no-message service doesn't crash on prompt render).
    final config = _config;
    if (config != null) {
      _agent.state.systemPrompt = _composeSystemPrompt(config);
    }
    // Best-effort cleanup of legacy empty sessions (no transcript — only the
    // JSONL header). Runs in the background so it never slows startup.
    unawaited(_cleanupLegacyEmptySessions());
    // The watcher only exists with a messaging fabric (production ctor);
    // lightweight test services never start a timer.
    if (_subagentManager != null) _startInboxWatcher();
  }

  /// Removes every legacy empty `.jsonl` (only header) left on disk by the
  /// previous eager session-creation code paths. Idempotent and silently
  /// best-effort.
  Future<void> _cleanupLegacyEmptySessions() async {
    try {
      await _repo.cleanupEmptySessions();
    } on Object {
      // Never propagate — cleanup is best-effort, the next launch will
      // retry.
    }
  }

  /// Materialises the JSONL session file the first time persistence is
  /// required — no-op when the session is already open (e.g. loadSession).
  /// All callers that may produce a transcript ([_persist], subagent
  /// follow-up messages) must go through here.
  Future<void> _materialiseSessionIfNeeded() async {
    if (_session != null) return;
    final session = await _repo.create(
      JsonlSessionCreateOptions(
        cwd: env.sessionCwd,
        // Allocated eagerly in [initialize] — the file adopts it so the
        // id the host already keyed this session by stays stable.
        id: _sessionId,
        metadata: {'agent': 'fa', 'model': _agent.state.model.id},
      ),
    );
    _session = session;
    final sessionMetadata = await session.getMetadata();
    _sessionId = sessionMetadata.id;
    _sessionFile = sessionMetadata.path;
    _sessionCwd = sessionMetadata.cwd;
    _subagentManager?.mailboxPrefix = sessionMetadata.id;
    // Follow external appends (a running fa CLI on the same session).
    _startSessionWatch();
    // The messaging section now carries the real mailbox address.
    final config = _config;
    if (config != null) {
      _agent.state.systemPrompt = _composeSystemPrompt(config);
    }
    // Presence in the messaging fabric once an id is available.
    unawaited(
      _subagentManager?.messaging?.register(
        _subagentManager!.mailboxOf(_subagentManager!.selfId),
      ),
    );
  }

  /// The inbox watcher: incoming inter-agent mail while IDLE wakes the
  /// agent into a turn (mid-run mail is already delivered by the steering
  /// poll). This is what makes two Fa instances chat live.
  Timer? _inboxWatchTimer;
  var _inboxWakeRunning = false;
  var _disposed = false;

  /// Opt-in for the real app bootstrap (main.dart): the periodic watcher
  /// never starts in tests (a pending periodic Timer fails flutter_test's
  /// invariants), so it is off by default.
  static bool enableInboxWatcher = false;

  /// Consecutive inbox-triggered runs without any user input — capped so
  /// two chatty instances cannot ping-pong forever (mail still accumulates
  /// and is delivered at the next real turn).
  var _inboxWakeStreak = 0;
  static const _maxInboxWakeStreak = 10;

  var _fabricHeartbeatTick = 0;

  /// Whether the over-window guard's one-shot auto-continuation was used
  /// for the current user text (reset on every real [sendText] entry).
  var _overWindowAutoResumed = false;

  /// Delivered to the model when the over-window guard stopped a run and
  /// the post-run compaction freed the window: names what happened and
  /// how to avoid re-filling the context.
  static const String _overWindowContinuationNotice =
      '<system-notice>\n'
      'The previous run was stopped by the context-window guard: the '
      'outgoing request exceeded the model window and was NOT sent. The '
      'transcript was auto-compacted just now (most of it is preserved as '
      'a summary; the session file keeps the full history). Continue the '
      'interrupted task from where it stopped. Avoid re-reading whatever '
      'filled the window (huge tool outputs, whole files) — use targeted '
      'reads (offset/limit or :A-B selectors) instead.\n'
      '</system-notice>';

  void _startInboxWatcher() {
    if (!enableInboxWatcher) return;
    _inboxWatchTimer ??= Timer.periodic(const Duration(seconds: 3), (_) {
      // Every other tick (≈6s): refresh the messaging-fabric heartbeat so
      // agent_directory reports this instance as live between mails.
      if (_fabricHeartbeatTick++ % 2 == 0) _touchFabricHeartbeat();
      unawaited(_wakeOnInboxMail());
    });
  }

  /// Best-effort fabric heartbeat; a broken fabric never breaks the watch
  /// loop.
  void _touchFabricHeartbeat() {
    final manager = _subagentManager;
    final fabric = manager?.messaging;
    if (fabric == null) return;
    unawaited(fabric.touch(manager!.mailboxOf(manager.selfId)));
  }

  /// Called when a background shell job settles: the completion re-enters
  /// the conversation as a system notice (sendText steers mid-run and
  /// starts a fresh turn while idle — the same flow as inbox mail).
  void _onShellJobSettled(ShellJobEntry job) {
    if (_disposed) return;
    unawaited(
      sendText(
        '<system-notice>\n'
        'Background shell job ${job.id} finished with exit code '
        '${job.exitCode}.\n'
        'Command: ${job.command}\n'
        'Log: ${job.logPath}\n'
        'Check the result with bash_job (action: output) or by reading the '
        'log file, and act on it when the result was awaited.\n'
        '</system-notice>',
      ),
    );
  }

  Future<void> _wakeOnInboxMail() async {
    final manager = _subagentManager;
    if (manager == null || _inboxWakeRunning || _disposed) return;
    if (isStreaming || _agent.state.isStreaming) return;
    if (_inboxWakeStreak >= _maxInboxWakeStreak) return;
    final count = await manager.pendingInboxCount(manager.selfId);
    if (count == 0) return;
    _inboxWakeStreak++;
    _inboxWakeRunning = true;
    try {
      await sendText(
        '<system-notice>New inter-agent mail arrived ($count message(s)) — '
        'the messages follow below as user messages. Read them and act: '
        'reply with the agent_message tool to the sender address when a '
        'response is expected, or just incorporate the information.'
        '</system-notice>',
      );
    } finally {
      _inboxWakeRunning = false;
    }
  }

  /// The main agent's inbox as steering messages: each pending fabric
  /// message becomes a user message attributed to its sender, so the
  /// transcript reads like a chat between agents.
  Future<List<Message>> _mainInboxMessages() async {
    final manager = _subagentManager;
    if (manager == null) return const [];
    final queued = await manager.drainMessages(manager.selfId);
    return [
      for (final message in queued)
        UserMessage.text('from ${message.fromId}: ${message.text.trim()}'),
    ];
  }

  /// Sends a plain-text user message. While the agent is already running the
  /// message is queued as a steering message and the UI shows it as pending
  /// until the next turn picks it up.
  @override
  Future<void> sendText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    // Real user input resets the inbox wake streak (the ping-pong guard);
    // the watcher itself calls sendText with the flag set.
    if (!_inboxWakeRunning) _inboxWakeStreak = 0;
    // A fresh user text gets a fresh over-window auto-continuation budget.
    _overWindowAutoResumed = false;
    _clearError();
    if (_agent.state.isStreaming) {
      _agent.steer(UserMessage.text(trimmed));
      pendingSteerTexts.add(trimmed);
      notifyListeners();
      return;
    }
    _runWithTimeout(() => _agent.prompt(trimmed));
  }

  /// Directory (relative to [env]'s working directory) where chat
  /// attachments are staged before the outgoing message references them.
  static const String uploadsDir = 'uploads';

  /// Whether the active provider accepts inline image content: hosted
  /// providers do; the on-device text-only backends (WebLLM, Gemma,
  /// transformers.js) get file paths only, never [ImageContent].
  bool get inlinesImageAttachments => !_isOnDeviceKind(providerKind);

  /// Stages a chat attachment into [uploadsDir] inside the sandbox,
  /// creating the directory and de-duplicating the file name on collision
  /// (`report.pdf` → `report-1.pdf` → …). Returns the env-relative path
  /// (`uploads/report.pdf`) the outgoing message should reference.
  ///
  /// Throws [StateError] with a readable message when nothing was written —
  /// callers must surface it (a snackbar), never fail silently.
  @override
  Future<String> stageAttachment({
    required String name,
    required Uint8List bytes,
  }) async {
    // A picked name can carry browser-supplied subdirectories
    // (webkitRelativePath); chat attachments flatten into uploads/.
    final base = sanitizeUploadName(name).split('/').last;
    if (base.isEmpty) {
      throw StateError('"$name" has no usable file name.');
    }
    final dirResult = await env.createDir(uploadsDir);
    if (dirResult.isErr) {
      throw StateError(
        'Could not create $uploadsDir: ${dirResult.errorOrNull!.message}',
      );
    }
    var candidate = '$uploadsDir/$base';
    for (var n = 1; (await env.exists(candidate)).valueOrNull ?? false; n++) {
      candidate = '$uploadsDir/${_dedupeName(base, n)}';
    }
    final writeResult = await env.writeBinaryFile(candidate, bytes);
    if (writeResult.isErr) {
      throw StateError(
        'Could not store $base: ${writeResult.errorOrNull!.message}',
      );
    }
    return candidate;
  }

  /// `name.ext` → `name-1.ext` for n = 1; names without an extension get
  /// the suffix appended whole.
  static String _dedupeName(String name, int n) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return '$name-$n';
    return '${name.substring(0, dot)}-$n${name.substring(dot)}';
  }

  /// Best-effort delete of a file staged via [stageAttachment] — used when
  /// a pending attachment chip is removed before sending. Only paths inside
  /// [uploadsDir] qualify; failures are ignored (the file is small and the
  /// sandbox is ephemeral).
  @override
  Future<void> discardStagedAttachment(String path) async {
    if (!path.startsWith('$uploadsDir/')) return;
    try {
      await env.remove(path);
    } on Object {
      // Best effort: a leftover file in uploads/ is harmless.
    }
  }

  /// Sends a user message referencing files staged via [stageAttachment]:
  /// the text names each sandbox path so the agent reads the file with its
  /// tools, followed by the user's typed text. Raster image attachments
  /// ([isInlineImageMimeType]) are additionally inlined as [ImageContent]
  /// when the active provider is a hosted one ([inlinesImageAttachments]);
  /// SVG and other non-decodable types always travel as path references
  /// only, and on-device text-only backends receive the paths only.
  @override
  Future<void> sendAttachments({
    required List<StagedAttachment> attachments,
    String text = '',
  }) async {
    if (attachments.isEmpty) return sendText(text);
    final fullText = [
      for (final attachment in attachments)
        '[attached file: ${attachment.path} — read it with your tools]',
      if (text.trim().isNotEmpty) text.trim(),
    ].join('\n');
    final images = [
      for (final attachment in attachments)
        if (isInlineImageMimeType(attachment.mimeType)) attachment,
    ];
    final inline = images.isNotEmpty && inlinesImageAttachments;
    _clearError();
    // Gemini's inlineData limit is ~4 MB of raw image bytes — base64
    // inflates by ~4/3, so a 3 MB PNG becomes a 4 MB payload. Cap at
    // 3 MB so the backend never sees an oversized inlineData (its
    // 'Unable to process input image' 400 is unhelpful).
    const maxInlineBytes = 3 * 1024 * 1024;
    final oversized = images.where((a) => a.bytes.length > maxInlineBytes);
    if (oversized.isNotEmpty) {
      error =
          'Image is too large to send inline (max ~3 MB). '
          'Resize it or attach as a file instead.';
      notifyListeners();
      return;
    }
    final message = inline
        ? UserMessage(
            content: [
              TextContent(text: fullText),
              for (final image in images)
                ImageContent(
                  data: base64Encode(image.bytes),
                  mimeType: image.mimeType,
                ),
            ],
            timestamp: DateTime.now(),
          )
        : UserMessage.text(fullText);
    if (_agent.state.isStreaming) {
      _agent.steer(message);
      pendingSteerTexts.add(fullText);
      notifyListeners();
      return;
    }
    _runWithTimeout(() => _agent.promptMessage(message));
  }

  /// Sends a user message with an attached image.
  Future<void> sendImage({
    required Uint8List bytes,
    required String mimeType,
    String text = '',
  }) async {
    _clearError();
    final content = <ContentBlock>[
      if (text.isNotEmpty) TextContent(text: text),
      ImageContent(data: base64Encode(bytes), mimeType: mimeType),
    ];
    final message = UserMessage(content: content, timestamp: DateTime.now());
    if (_agent.state.isStreaming) {
      _agent.steer(message);
      pendingSteerTexts.add(text.isEmpty ? '[image]' : text);
      notifyListeners();
      return;
    }
    _runWithTimeout(() => _agent.promptMessage(message));
  }

  /// LLM completion for host features (the `jsr.fa.llm*` bridge in JS apps).
  /// Runs on a throwaway agent with no tools, so it never touches the session
  /// transcript. `system` messages are folded into the system prompt; `user`
  /// and `assistant` messages become the conversation, which should end with
  /// a user message. When [onDelta] is given, streamed text deltas are
  /// forwarded as they arrive.
  Future<String> completeOnce(
    List<FaLlmMessage> messages, {
    void Function(String delta)? onDelta,
  }) async {
    final model = _agent.state.model;
    final agent = Agent(
      model: model,
      systemPrompt: [
        'You are a tiny assistant embedded inside a host '
            'application. Answer briefly and plainly; no markdown fences unless '
            'the caller asks for code.',
        for (final message in messages)
          if (message.role == 'system') message.content,
      ].join('\n\n'),
      streamFunction: _agent.streamFunction,
      toolRegistry: ToolRegistry(const []),
    );
    if (onDelta != null) {
      agent.subscribe((event, cancelToken) async {
        if (event case MessageUpdateEvent(
          assistantMessageEvent: TextDeltaEvent(:final delta),
        )) {
          onDelta(delta);
        }
      });
    }
    final conversation = [
      for (final message in messages)
        if (message.role == 'assistant')
          AssistantMessage(
            content: [TextContent(text: message.content)],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage.zero,
            stopReason: StopReason.stop,
            timestamp: DateTime.now(),
          )
        else if (message.role == 'user')
          UserMessage.text(message.content),
    ];
    if (conversation.isEmpty) {
      throw StateError('messages must include at least one user message');
    }
    await agent.promptMessages(conversation);
    final last = agent.state.messages.lastOrNull;
    if (last is AssistantMessage) {
      final text = last.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      if (text.isNotEmpty) return text;
      if (last.errorMessage != null) throw StateError(last.errorMessage!);
    }
    throw StateError('no completion returned');
  }

  /// Starts one agent run and settles the UI state no matter how it ends.
  ///
  /// [startRun] is invoked LAZILY inside a try/catch: `Agent.prompt*` throws
  /// synchronously when a run is already active, and the composer calls the
  /// send methods unawaited — a synchronous escape would surface as an
  /// unhandled async error in the console (the "Uncaught Error" storm after
  /// a provider failure) instead of the error banner. Timeouts and async
  /// failures land in `catchError`, which always re-enables the UI.
  void _runWithTimeout(Future<void> Function() startRun) {
    final Future<void> run;
    try {
      // Multi-day sessions: re-compose the prompt so the model sees
      // TODAY's date, not the session creation date.
      final config = _config;
      if (config != null) {
        _agent.state.systemPrompt = _composeSystemPrompt(config);
      }
      _armIdleWatchdog();
      run = startRun();
    } on Object catch (e) {
      _idleWatchdog?.cancel();
      isStreaming = false;
      error = e is StateError ? e.message : e.toString();
      notifyListeners();
      return;
    }
    run.catchError((Object e) {
      _idleWatchdog?.cancel();
      isStreaming = false;
      error = e.toString();
      // dispose() aborts an in-flight run — its error lands here after the
      // service is gone; notifying a disposed ChangeNotifier throws.
      if (_disposed) return;
      notifyListeners();
    });
  }

  /// Idle watchdog: the run aborts only when NOTHING comes back for
  /// [_responseTimeout] — any event (tokens, tool calls) proves the model is
  /// alive and rearms it. Replaces the previous whole-run timeout, which
  /// killed long coding tasks ("Request was aborted" after 90 s of healthy
  /// streaming). Long tool calls suppress it via [_activeToolCalls].
  Timer? _idleWatchdog;
  int _activeToolCalls = 0;

  void _armIdleWatchdog() {
    _idleWatchdog?.cancel();
    _idleWatchdog = Timer(_responseTimeout, () {
      if (_activeToolCalls > 0) return; // a long tool is still running
      if (!isStreaming) return; // run already completed — no false positive
      abort();
      isStreaming = false;
      error =
          'The model stopped responding for '
          '${_responseTimeout.inSeconds} seconds.';
      notifyListeners();
    });
  }

  /// Aborts the current run, if any.
  @override
  void abort() => _agent.abort();

  /// Serializes `_persist` runs so concurrent triggers never double-append
  /// the same message.
  Future<void> _persistChain = Future<void>.value();

  /// Crash-safe persistence: append finished messages/tool results to the
  /// session file AS THEY LAND (serialized through [_persistChain]), so a
  /// crash mid-run loses nothing the agent already produced — persisting
  /// only on AgentEnd (the old behavior) lost the whole turn, tool calls
  /// included, when the app died mid-run. Torn trailing writes from a crash
  /// mid-append self-heal on the next load (the JSONL storage truncates
  /// them).
  void _persistSoon() {
    // Our own appends grow the file — re-arm the external watcher's
    // baseline so our writes don't trigger an external reload.
    unawaited(() async {
      final file = _sessionFile;
      if (file == null) return;
      final info = (await env.fileInfo(file)).valueOrNull;
      if (info != null) _sessionWatchBytes = info.size;
    }());
    _persistChain = _persistChain.then((_) => _persist()).catchError((
      Object _,
    ) {
      // Best effort: the transcript stays in memory; the next trigger
      // retries the missed appends (see _persistedCount).
    });
  }

  @override
  void dispose() {
    _disposed = true;
    // Disposing the service cancels an in-flight run: the agent's idle
    // watchdog would otherwise outlive the host by minutes (and wedge
    // widget tests' fake_async invariants on a pending timer).
    _agent.abort();
    _inboxWatchTimer?.cancel();
    _idleWatchdog?.cancel();
    _liveActivityEndTimer?.cancel();
    _sessionWatchTimer?.cancel();
    fsRevision.dispose();
    externalSessionRevision.dispose();
    _trajectory.dispose();
    super.dispose();
  }

  /// Waits until the agent becomes idle.
  Future<void> waitForIdle() => _agent.waitForIdle();

  /// Clears the in-memory transcript and starts a new session.
  Future<void> reset() async {
    await deleteSessionIfEmpty();
    // Detach the old session so [initialize] allocates a fresh id — the
    // old file (when it has content) stays on disk for the session list.
    _session = null;
    _sessionId = null;
    _sessionFile = null;
    _agent.reset();
    messages.clear();
    error = null;
    _persistedCount = 0;
    _trajectory.reset();
    _currentAssistantMessage = null;
    await initialize();
    notifyListeners();
  }

  /// Deletes the session file when nothing was ever said in it: a session
  /// the user never typed into must not litter the session list. Called on
  /// close/reset; best-effort — never throws.
  Future<void> deleteSessionIfEmpty() async {
    if (_agent.state.messages.isNotEmpty) return;
    final session = _session;
    if (session == null) return;
    try {
      await _repo.delete(await session.getMetadata());
      _session = null;
      _sessionId = null;
      _sessionFile = null;
    } on Object {
      // Best-effort cleanup.
    }
  }

  /// Switches the backend (provider/model/key) for subsequent messages while
  /// keeping the visible transcript and the current session.
  ///
  /// Any in-flight run is aborted first and awaited, so no zombie stream
  /// survives the switch; the deliberate abort's error banner is cleared.
  /// The [Agent] itself is reused — only its model, system prompt, and
  /// stream function are swapped — so tool wiring and the transcript live
  /// on. For WebLLM the settings form has already run `loadModel` (the
  /// engine is a singleton), so the new stream function reuses the warm
  /// instance. The switch is recorded as a `model_change` session record.
  Future<void> reconfigure(AgentConfig config) async {
    abort();
    await waitForIdle();
    final newModel = config.toModel();
    debugPrint(
      '[Fa] reconfigure: baseUrl=${config.baseUrl}, '
      'apiKey.len=${config.apiKey.length}, '
      'isCodeMie=${isCodeMieProvider(config.baseUrl)}, '
      'model.headers=${newModel.headers?.keys.toList()}, '
      'streamApiKey.len=${isCodeMieProvider(config.baseUrl) ? 0 : config.apiKey.length}',
    );
    _agent.state.model = newModel;
    _agent.state.systemPrompt = _composeSystemPrompt(config);
    _agent.streamFunction = _streamFunctionFor(config);
    _providerKind = config.providerKind;
    _activeBaseUrl = config.baseUrl;
    _activeApiKey = config.apiKey;
    _responseTimeout = _isOnDeviceKind(config.providerKind)
        ? const Duration(minutes: 10)
        : isCodeMieProvider(config.baseUrl)
        ? const Duration(minutes: 5)
        : const Duration(seconds: 90);
    error = null;
    notifyListeners();
    // Best effort: a failed marker write must not break the switch.
    try {
      await _session?.appendModelChange(
        provider: config.providerKind,
        modelId: config.modelId,
      );
    } on Object {
      // Session persistence is best effort here.
    }
  }

  /// Creates a new [AgentService] with the same config and env, for a fresh
  /// session. The clone shares the [env] and the session repository but owns
  /// its own [Agent], transcript, and session persistence.
  AgentService clone() {
    final config = _config;
    if (config == null) {
      throw StateError(
        'Cannot clone an AgentService built from a pre-constructed Agent',
      );
    }
    // Reuse the current stream function so test doubles keep working; a real
    // service would recreate it from the provider kind.
    return AgentService._withEnv(
      env: env,
      config: config,
      sessionsRoot: sessionsRoot,
      redactor: _redactor,
      streamFunction: _agent.streamFunction,
      // Clones inherit the external-watch setting (tests disable it).
      watchExternalSessions: _watchExternalSessions,
      resolveSecretName: _resolveSecretName,
      // Clones share the live secrets env and the Keys store, so a
      // `request_secret` grant in one session is live and persisted for all.
      secretsEnv: _secretsEnv,
      sessionKeys: _sessionKeys,
      taskModelsStore: _taskModelsStore,
      // Clones inherit the CURRENT approval mode (not a fresh disk read) and
      // share the store so their mode changes persist too.
      initialApprovalMode: approval.mode,
      approvalModeStore: _approvalModeStore,
      // Same for the skills-access consent: the live choice + shared store.
      initialSkillsAccess: _skillsAccess,
      skillsAccessStore: _skillsAccessStore,
      // Same for the per-tool availability: the live config + shared store.
      initialToolsConfig: _toolsAvailability.config,
      toolsAvailabilityStore: _toolsAvailabilityStore,
    );
  }

  /// Lists persisted sessions, newest first (across all provider dirs under
  /// [sessionsRoot]). Cheap: reads only the JSONL headers.
  Future<List<SessionMetadata>> listSessions() async {
    try {
      final roots = allSessionRoots(sessionsRoot);
      if (roots.length <= 1) {
        return await _repo.list();
      }
      final seen = <String>{};
      final merged = <SessionMetadata>[];
      for (final root in roots) {
        try {
          final repo = root == sessionsRoot
              ? _repo
              : JsonlSessionRepo(fs: env, sessionsRoot: root);
          final list = await repo.list();
          for (final item in list) {
            if (seen.add(item.id)) {
              merged.add(item);
            }
          }
        } on Object {
          // Secondary root list failure is non-fatal.
        }
      }
      merged.sort((a, b) {
        final aTime = a.lastUpdatedAt ?? a.createdAt;
        final bTime = b.lastUpdatedAt ?? b.createdAt;
        final result = bTime.compareTo(aTime);
        if (result != 0) return result;
        return b.createdAt.compareTo(a.createdAt);
      });
      return merged;
    } on Object {
      return _repo.list();
    }
  }

  /// Loads a persisted session into the chat: the agent's context and the
  /// visible transcript are replaced by the session's active branch, and new
  /// messages append to that session. The session's effective model (the
  /// last `model_change` record at the leaf — every provider/model switch
  /// in the CLI and the app appends one) is restored: the DEFAULT chat
  /// model only applies to NEW sessions, not to reopening an old one.
  Future<void> loadSession(SessionMetadata metadata) async {
    abort();
    await waitForIdle();
    final session = await _repo.open(metadata);
    final context = await session.buildContext();
    final contextMessages = context.messages;
    _agent.reset();
    _agent.state.messages = contextMessages;
    _session = session;
    _sessionId = metadata.id;
    _sessionFile = metadata.path;
    _sessionCwd = metadata.cwd;
    _subagentManager?.mailboxPrefix = metadata.id;
    // Follow external appends (a running fa CLI on the same session).
    _startSessionWatch();
    // The ledger re-projects the active branch (records carry richer
    // structure than the rebuilt message list).
    await _rebuildTrajectory();
    // Restore the session's own model: same wire kind → modelId override;
    // the provider itself stays the configured connection (its key lives
    // in the Keychain, not in the session). An unresolvable or
    // cross-kind mismatch keeps the current model — reopening a session
    // must never hard-fail on this. Works with a config-less service
    // too (pre-constructed agents): the kind check then compares against
    // the agent's live model.
    final config = _config;
    final sessionModel = context.model;
    final activeApi = _agent.state.model.api;
    if (sessionModel != null &&
        sessionModel.modelId.isNotEmpty &&
        sessionModel.modelId != _agent.state.model.id &&
        (config == null
            ? sessionModel.provider == activeApi
            : (sessionModel.provider == config.providerKind ||
                  sessionModel.provider == config.toModel().api))) {
      if (config != null) {
        reconfigure(config.withModelId(sessionModel.modelId));
      } else {
        final model = _agent.state.model;
        _agent.state.model = Model(
          id: sessionModel.modelId,
          name: sessionModel.modelId,
          api: model.api,
          provider: model.provider,
          baseUrl: model.baseUrl,
          reasoning: model.reasoning,
          input: inputModalitiesFor(sessionModel.modelId),
          cost: model.cost,
          contextWindow: model.contextWindow,
          maxTokens: model.maxTokens,
          headers: model.headers,
          compat: model.compat,
        );
      }
      debugPrint(
        '[Fa] session model restored: ${sessionModel.provider}/'
        '${sessionModel.modelId}',
      );
    }
    // The prompt's messaging section carries the live mailbox address.
    final activeConfig = _config;
    if (activeConfig != null) {
      _agent.state.systemPrompt = _composeSystemPrompt(activeConfig);
    }
    unawaited(
      _subagentManager?.messaging?.register(
        _subagentManager!.mailboxOf(_subagentManager!.selfId),
      ),
    );
    _persistedCount = contextMessages.length;
    _currentAssistantMessage = null;
    error = null;
    messages
      ..clear()
      ..addAll(contextMessages.map(_toChatMessage));
    notifyListeners();
  }

  /// Deletes a persisted session. Deleting the ACTIVE session starts a new
  /// empty one, so the chat never points at a removed file.
  Future<void> deleteSession(SessionMetadata metadata) async {
    final isActive = metadata.id == _sessionId;
    if (isActive) {
      // Stop any in-flight run and let its persistence settle before the
      // session file disappears underneath it.
      abort();
      await waitForIdle();
    }
    await _repo.delete(metadata);
    if (isActive) await reset();
  }

  /// Projects a persisted context [Message] back into the UI transcript.
  static FahChatMessage _toChatMessage(Message message) {
    switch (message) {
      case UserMessage(:final content):
        if (content is String) {
          return FahChatMessage(role: 'user', content: content);
        }
        final blocks = content as List<ContentBlock>;
        Uint8List? imageBytes;
        for (final block in blocks.whereType<ImageContent>()) {
          imageBytes = base64Decode(block.data);
          break;
        }
        // Strip the '[attached file: uploads/… — read it with your tools]'
        // prefix from the visible text — the image already carries the
        // content, and the path reference is agent-facing only.
        final visibleText = blocks
            .whereType<TextContent>()
            .map((b) => b.text)
            .join('\n')
            .replaceAll(RegExp(r'\[attached file: uploads/[^\]]+\]\s*\n?'), '')
            .trim();
        return FahChatMessage(
          role: 'user',
          content: visibleText,
          imageBytes: imageBytes,
        );
      case AssistantMessage(:final content):
        return FahChatMessage(
          role: 'assistant',
          content: content.whereType<TextContent>().map((b) => b.text).join(),
        );
      case ToolResultMessage(:final content, :final toolName, :final isError):
        return FahChatMessage(
          role: 'tool',
          content: content
              .whereType<TextContent>()
              .map((b) => b.text)
              .join('\n'),
          toolName: toolName,
          isError: isError,
        );
      default:
        return FahChatMessage(role: 'system', content: message.toString());
    }
  }

  void _clearError() {
    if (error != null) {
      error = null;
      notifyListeners();
    }
  }

  Future<void> _onAgentEvent(AgentEvent event, CancelToken cancelToken) async {
    // Any event proves the run is alive — rearm the idle watchdog.
    if (event is! AgentEndEvent) _armIdleWatchdog();
    _trajectory.applyEvent(event);
    switch (event) {
      case AgentStartEvent():
        isStreaming = true;
        _currentAssistantMessage = null;
        _turnStartCount = 0;
        pendingSteerTexts.clear();
        notifyListeners();
      case TurnStartEvent():
        // Continuation turns (steering injected mid-run) start with a second
        // TurnStartEvent; clear the pending banner now so it doesn't outlive
        // the injected user messages.
        if (_turnStartCount > 0 && pendingSteerTexts.isNotEmpty) {
          pendingSteerTexts.clear();
          notifyListeners();
        }
        _turnStartCount++;
      case MessageUpdateEvent(:final assistantMessageEvent):
        if (assistantMessageEvent is TextDeltaEvent) {
          _appendAssistantDelta(assistantMessageEvent.delta);
        } else if (assistantMessageEvent is ThinkingDeltaEvent) {
          _appendThinkingDelta(assistantMessageEvent.delta);
        }
      case MessageEndEvent(:final message):
        if (message is UserMessage) {
          // User messages (initial prompts and injected steering) reach the
          // transcript through the agent loop so ordering matches the context.
          messages.add(_toChatMessage(message));
          // If this text was shown as pending while the agent was busy, drop
          // it from the banner now that it is in the live transcript.
          final text = _userMessageText(message);
          if (text != null) pendingSteerTexts.remove(text);
          notifyListeners();
        } else if (message is AssistantMessage) {
          _finalizeAssistant(message);
        }
        _persistSoon();
      case ToolExecutionStartEvent(:final toolName, :final args):
        // Tool calls can run long (builds, installs) without producing agent
        // events — the idle watchdog must not fire during them.
        _activeToolCalls++;
        messages.add(
          FahChatMessage(
            role: 'system',
            content: '[$toolName] ${_shortArgs(args)}',
          ),
        );
        _pushLiveActivityStatus();
        notifyListeners();
      case ToolExecutionEndEvent(
        :final toolName,
        :final result,
        :final isError,
      ):
        _activeToolCalls--;
        _armIdleWatchdog();
        if (_kMutatingToolNames.contains(toolName)) {
          // "Hook" for file-watching UI: the agent may have changed files.
          fsRevision.value++;
        }
        _persistSoon();
        final text = result.content
            .whereType<TextContent>()
            .map((b) => b.text)
            .join('\n');
        messages.add(
          FahChatMessage(
            role: 'tool',
            content: text,
            toolName: toolName,
            isError: isError,
          ),
        );
        _pushLiveActivityStatus();
        notifyListeners();
      case AgentEndEvent():
        _idleWatchdog?.cancel();
        isStreaming = false;
        _currentAssistantMessage = null;
        notifyListeners();
        // Session persistence is best effort: a failed append must not
        // propagate back into the agent's event plumbing (a throwing
        // listener re-enters the loop's failure path, duplicates the
        // failure events, and escapes the run as an unhandled error).
        //
        // Through the SAME `_persistChain` as `_persistSoon` — a direct
        // call races the queued passes: both read `_persistedCount == 0`
        // before either finishes, and every message is appended twice
        // (duplicate JSONL records, duplicated transcripts on reload).
        // Session persistence is best effort: a failed append must not
        // propagate back into the agent's event plumbing (a throwing
        // listener re-enters the loop's failure path, duplicates the
        // failure events, and escapes the run as an unhandled error).
        try {
          await _persist();
        } on Object {
          // The transcript stays in memory; the next run retries the
          // missed appends (see _persistedCount).
        }
        final compacted = await _maybeAutoCompact();
        // The loop's over-window guard stopped the run: once the
        // post-run compaction freed the window, continue the interrupted
        // turn on its own (once per user text) instead of idling with an
        // error — a live session that hit the guard mid-task (200676/200k
        // on glm) used to sit dead until a manual "continue".
        final lastMessage = _agent.state.messages.lastOrNull;
        if (!_overWindowAutoResumed &&
            compacted &&
            lastMessage is AssistantMessage &&
            isContextWindowExhaustedError(lastMessage.errorMessage)) {
          _overWindowAutoResumed = true;
          Future(
            () => _runWithTimeout(
              () => _agent.prompt(_overWindowContinuationNotice),
            ),
          );
        }
        // Steering/follow-up messages queued during the run get their own
        // run once this lifecycle fully finished — also after a manual
        // stop, so a queued message never silently dies in the transcript.
        if (_agent.hasQueuedMessages()) {
          Future(() => _runWithTimeout(() => _agent.continueRun()));
        }
      default:
    }
  }

  /// Extracts the textual content of a [UserMessage] for matching against
  /// [pendingSteerTexts]. Returns `null` for empty or non-text messages.
  String? _userMessageText(UserMessage message) {
    final content = message.content;
    if (content is String) {
      return content.isEmpty ? null : content;
    }
    final text = (content as List<ContentBlock>)
        .whereType<TextContent>()
        .map((b) => b.text)
        .join('\n');
    return text.isEmpty ? null : text;
  }

  void _appendAssistantDelta(String delta) {
    var target = _currentAssistantMessage;
    if (target == null) {
      target = FahChatMessage(role: 'assistant', content: '');
      _currentAssistantMessage = target;
      messages.add(target);
      // The status line flips to "writing…" — update the Live Activity.
      _pushLiveActivityStatus();
    }
    target.content += delta;
    notifyListeners();
  }

  void _appendThinkingDelta(String delta) {
    var target = _currentThinkingMessage;
    if (target == null) {
      target = FahChatMessage(role: 'thinking', content: '');
      _currentThinkingMessage = target;
      messages.add(target);
      // The status line flips to "thinking…" — update the Live Activity.
      _pushLiveActivityStatus();
    }
    target.content += delta;
    notifyListeners();
  }

  void _finalizeAssistant(AssistantMessage message) {
    debugPrint(
      '[Fa] finalizeAssistant: stopReason=${message.stopReason}, '
      'contentBlocks=${message.content.length}, '
      'errorMessage=${message.errorMessage}',
    );
    var text = message.content
        .whereType<TextContent>()
        .map((b) => b.text)
        .join();
    final thinking = message.content
        .whereType<ThinkingContent>()
        .map((b) => b.thinking)
        .join();
    final hasToolCalls = message.content.any((block) => block is ToolCall);
    if (text.trim().isEmpty &&
        !hasToolCalls &&
        message.stopReason != StopReason.error &&
        message.stopReason != StopReason.aborted) {
      // A completed turn with neither text nor tool calls (small on-device
      // models do this) must not render as a blank bubble.
      text = emptyResponsePlaceholder;
      // An empty completion right after an image-bearing prompt usually
      // means the model silently ignored/rejected image input - say so
      // instead of a bare retry suggestion.
      // UserMessage.content is Object: a plain String or a block list.
      final lastUserContent = _agent.state.messages.reversed
          .whereType<UserMessage>()
          .firstOrNull
          ?.content;
      final lastUserBlocks = switch (lastUserContent) {
        final List blocks => blocks,
        _ => const <Object>[],
      };
      final hadImage = lastUserBlocks.any((b) => b is ImageContent);
      if (hadImage) {
        text =
            '$text\n\nThe model returned nothing for a message with '
            'an image attachment - it likely does not support image input. '
            'Try a vision-capable model or resend without the attachment.';
      }
    }
    final target = _currentAssistantMessage;
    if (target == null) {
      messages.add(FahChatMessage(role: 'assistant', content: text));
    } else {
      target.content = text;
    }
    _currentAssistantMessage = null;
    final thinkingTarget = _currentThinkingMessage;
    if (thinkingTarget == null) {
      if (thinking.isNotEmpty) {
        messages.add(FahChatMessage(role: 'thinking', content: thinking));
      }
    } else {
      thinkingTarget.content = thinking.isNotEmpty
          ? thinking
          : thinkingTarget.content;
    }
    _currentThinkingMessage = null;
    if (message.stopReason == StopReason.error) {
      // A failed run must be VISIBLE: an error tile in the transcript
      // (the shared renderer styles it), not just the banner field —
      // otherwise a dead key silently looks like "no answer".
      final text =
          message.errorMessage ?? 'Run failed (${StopReason.error.name})';
      error = text;
      messages.add(
        FahChatMessage(
          role: 'tool',
          content: text,
          toolName: 'error',
          isError: true,
        ),
      );
    } else if (message.stopReason == StopReason.aborted) {
      error = message.errorMessage ?? 'Run aborted';
    }
    notifyListeners();
  }

  /// The visible transcript as Markdown (`## You` / `## Fa` / `## tool`
  /// sections) — shared by the chat screen's and the sheet's "Copy session"
  /// actions so both copy the exact same text.
  @override
  String transcriptMarkdown() {
    final buffer = StringBuffer();
    for (final m in messages) {
      final header = switch (m.role) {
        'user' => '## You',
        'assistant' => '## Fa',
        'tool' => '## tool (${m.toolName ?? 'call'})',
        _ => '## ${m.role}',
      };
      buffer.writeln(header);
      if (m.imageBytes != null) buffer.writeln('[image attached]');
      if (m.content.isNotEmpty) buffer.writeln(m.content);
      buffer.writeln();
    }
    return buffer.toString();
  }

  String _shortArgs(Map<String, dynamic> args) {
    final encoded = jsonEncode(args);
    if (encoded.length <= 80) return encoded;
    return '${encoded.substring(0, 80)}...';
  }

  /// Whether a [_persist] pass is currently draining the transcript.
  /// Concurrent triggers (a `_persistSoon` pass racing the run
  /// finalizer's direct call) must not both iterate
  /// `_agent.state.messages`: both would read the same
  /// `_persistedCount == 0` before either finishes and append every
  /// message twice (duplicate JSONL rows, duplicated chat on reload).
  /// The skip is safe — the live pass iterates the live list and
  /// advances `_persistedCount` for everything it saw.
  bool _persistRunning = false;

  Future<void> _persist() async {
    if (_persistRunning) return;
    _persistRunning = true;
    try {
      await _persistUnchecked();
    } finally {
      _persistRunning = false;
    }
  }

  Future<void> _persistUnchecked() async {
    // The session is created lazily on the first persisted message — no
    // JSONL file appears until the user actually writes something.
    await _materialiseSessionIfNeeded();
    final session = _session;
    if (session == null) return;
    final all = _agent.state.messages;
    for (final message in all.skip(_persistedCount)) {
      final id = await session.appendMessage(message);
      // The finalized record replaces the streamed synthetic rows in the
      // trajectory ledger (builder keys them by turn/step).
      final record = await session.getEntry(id);
      if (record != null) _trajectory.append(record);
    }
    _persistedCount = all.length;
  }

  /// Rebuilds the trajectory ledger from the active session branch
  /// (session open/switch/external reload).
  Future<void> _rebuildTrajectory() async {
    final session = _session;
    if (session == null) return;
    _trajectory.reset();
    for (final record in await session.getBranch()) {
      _trajectory.append(record);
    }
  }

  @override
  Stream<TrajectorySnapshot> get trajectory => _trajectory.stream;

  /// Compaction thresholds for the active model, scaled by
  /// [CompactionSettings.forWindow] to the conversation window (the model's
  /// context window minus the system-prompt overhead). pi's fixed defaults
  /// exceed the whole window of an on-device model, so the same settings
  /// cannot serve hosted 128k models and 8k WebLLM presets.
  CompactionSettings get compactionSettings =>
      CompactionSettings.forWindow(_conversationWindow);

  /// The window left for the conversation after [_systemOverheadTokens];
  /// `0` when the prompt alone exhausts the model window (compaction then
  /// has nothing sensible to plan against).
  int get _conversationWindow {
    final window = _agent.state.model.contextWindow - _systemOverheadTokens;
    return window > 0 ? window : 0;
  }

  /// Estimated tokens the provider counts against the context window on top
  /// of the transcript: the rendered system prompt plus — for the chat-only
  /// on-device backends (WebLLM, transformers.js), whose stream functions
  /// run through the prompt-tools wrapper — the tool instructions appended
  /// to that prompt. The wrapper's instruction block outweighs the base
  /// system prompt several times over, so ignoring it would size compaction
  /// against a window the engine does not actually have.
  int get _systemOverheadTokens {
    var system = _agent.state.systemPrompt;
    if (_providerKind == webLlmProviderKind ||
        _providerKind == transformersJsProviderKind) {
      system = '$system\n\n${promptToolInstructions(_agent.state.tools)}';
    }
    return estimateTokens(UserMessage.text(system));
  }

  /// Auto-compaction after each completed run (CLI parity): the shared
  /// [AutoCompactor] in core drives the multi-pass loop + smol→main
  /// fallback + transient retry. This wrapper only builds the per-host
  /// smol/main summarizers and the [AutoCompactorHooks] that mirrors the
  /// compacted transcript into the chat list.
  Future<bool> _maybeAutoCompact() async {
    final conversationWindow = _conversationWindow;
    if (_session == null || conversationWindow <= 0) return false;
    final settings = compactionSettings;
    final transcriptTokens = estimateContextTokens(
      _agent.state.messages,
    ).tokens;
    if (!shouldCompact(transcriptTokens, conversationWindow, settings)) {
      return false;
    }
    // The whole transcript fits in the kept region: compaction could not
    // drop anything. (A single oversized message can still overflow the
    // engine — that surfaces as a readable run error, not a compaction
    // loop.)
    if (transcriptTokens <= settings.keepRecentTokens) return false;

    // Resolve the smol summarizer from the task-models store, or fall
    // back to the main stream. The harness core doesn't know about
    // TaskModelsStore — only the host does.
    final smolConfig = _taskModelsStore?.overrideFor(TaskRole.smol);
    StreamFunction? smolStream;
    Model? smolModel;
    if (smolConfig != null && smolConfig.modelId.isNotEmpty) {
      var apiKey = _activeApiKey;
      final keyName = smolConfig.apiKeyName;
      if (keyName != null && keyName.isNotEmpty) {
        final resolved = _secretsEnv != null
            ? _secretsEnv.secretsSnapshot()[keyName]
            : null;
        if (resolved != null && resolved.isNotEmpty) apiKey = resolved;
      }
      smolModel = Model(
        id: smolConfig.modelId,
        name: smolConfig.modelId,
        api: _agent.state.model.api,
        provider: _agent.state.model.provider,
        baseUrl: smolConfig.baseUrl,
        contextWindow: _agent.state.model.contextWindow,
        maxTokens: _agent.state.model.maxTokens,
        input: _agent.state.model.input,
      );
      smolStream = providerStreamFunction(smolConfig.providerKind, apiKey);
    }

    await AutoCompactorFactory(
      session: _session!,
      state: _agent.state,
      window: conversationWindow,
      settings: settings,
      sources: AutoCompactorSources(
        smolStream: smolStream,
        smolModel: smolModel,
        mainStream: _agent.streamFunction,
        mainModel: _agent.state.model,
      ),
      hooks: const _AutoCompactorFlutterHooks(),
      prompts: const CompactionPrompts(),
    ).run();

    // The AutoCompactor replaces `state.messages` on success; mirror
    // that into the chat list so the UI reflects the new transcript.
    _persistedCount = _agent.state.messages.length;
    messages
      ..clear()
      ..addAll(_agent.state.messages.map(_toChatMessage));
    notifyListeners();
    // Success signal for the over-window guard's auto-continuation: the
    // transcript actually shrank.
    final afterTokens = estimateContextTokens(_agent.state.messages).tokens;
    return afterTokens < transcriptTokens;
  }
}

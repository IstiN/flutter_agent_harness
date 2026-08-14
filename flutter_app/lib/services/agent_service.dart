import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:fa_ui/fa_ui.dart'
    show
        FaApprovalModeController,
        FaChatConnection,
        FaChatMessage,
        FaChatService;
import 'package:fa_ui/fa_ui.dart' as fa_ui show emptyResponsePlaceholder;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/apps/open_app_tool.dart';
import 'package:fa/sandbox/env_factory.dart';
import 'package:fa/services/approval_mode_store.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/services/asr_tool.dart';
import 'package:fa/services/background_execution.dart';
import 'package:fa/services/calendar_service.dart';
import 'package:fa/services/calendar_tool.dart';
import 'package:fa/services/contact_service.dart';
import 'package:fa/services/contact_tool.dart';
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
import 'package:fa/gemma/gemma_service.dart';
import 'package:fa/gemma/gemma_stream_function.dart';
import 'package:fa/gemma/gemma_types.dart';
import 'package:fa/services/project_mount_env.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/vision_models.dart';
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

/// A UI-facing chat message.
/// A UI-facing chat message: one of `user`, `assistant`, `thinking`,
/// `tool`, `system`. Alias of the shared fa_ui type — new code should use
/// [FaChatMessage] directly.
typedef FahChatMessage = FaChatMessage;

/// Whether [baseUrl] points at a CodeMie organization (SSO/cookie-based
/// auth). CodeMie providers authenticate via the full cookie string sent as
/// a `Cookie:` header (riding in [Model.headers]) instead of a Bearer key —
/// the adapter skips `Authorization: Bearer` when the key is empty.
bool isCodeMieProvider(String baseUrl) =>
    baseUrl.contains('/code-assistant-api/');

/// Configuration needed to talk to a provider.
final class AgentConfig {
  AgentConfig({
    required this.providerKind,
    required this.modelId,
    required this.baseUrl,
    required this.apiKey,
    this.systemPrompt,
    this.contextWindow = fallbackContextWindow,
    this.maxTokens = fallbackMaxTokens,
    this.supportsImages,
  });

  /// Provider adapter kind: `openai-completions`, `anthropic`, `google`,
  /// `webllm` (on-device, web — see `lib/webllm/`), `gemma` (on-device,
  /// iOS/Android — see `lib/gemma/`), or `transformers_js` (on-device, web —
  /// see `lib/transformers_js/`).
  final String providerKind;

  /// Model id passed to the provider.
  final String modelId;

  /// Provider base URL (e.g. OpenRouter `https://openrouter.ai/api/v1`).
  /// Empty for on-device providers.
  final String baseUrl;

  /// API key for the provider. Empty for on-device providers.
  final String apiKey;

  /// Optional system prompt override.
  final String? systemPrompt;

  /// Context window reported to the agent loop (drives overflow/compaction
  /// heuristics). Small for on-device models.
  final int contextWindow;

  /// Output-token cap reported to the agent loop.
  final int maxTokens;

  /// Whether the model accepts image input. When null (session restores,
  /// tests, programmatic configs) the vision heuristic
  /// [modelIdSuggestsVision] decides from [modelId]; the settings form
  /// passes the user's explicit checkbox value.
  final bool? supportsImages;

  Model toModel() => Model(
    id: modelId,
    name: modelId,
    api: providerKind,
    provider: providerKind,
    baseUrl: baseUrl,
    contextWindow: contextWindow,
    maxTokens: maxTokens,
    // CodeMie authenticates via cookies: the stored apiKey is the full
    // cookie string, which rides in model.headers as a `cookie` entry. The
    // openai-completions adapter skips `Authorization: Bearer` when the key
    // is empty, so the cookie is the sole auth credential.
    headers: isCodeMieProvider(baseUrl) && apiKey.isNotEmpty
        ? {'cookie': apiKey}
        : null,
    input: [
      'text',
      if (supportsImages ?? modelIdSuggestsVision(modelId)) 'image',
    ],
  );
}

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
    String promptSuffix = '',
    Duration? responseTimeout,
    ApprovalMode? initialApprovalMode,
  }) : _promptSuffix = promptSuffix,
       _resolveSecretName = null,
       _secretsEnv = null,
       _sessionKeys = null,
       _taskModelsStore = null,
       _approvalModeStore = null,
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
  }) async {
    final resolvedEnv = env ?? await createPlatformEnv();
    final secretsStore = createSecretsStore();
    final secrets = mergeSecrets(await secretsStore.readAll(), sessionKeys);
    final approvalModeStore = ApprovalModeStore(resolvedEnv);
    final savedApprovalMode = await approvalModeStore.load();
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
    final roots = defaultSkillRoots(cwd: resolvedEnv.cwd, homeDir: null);
    final skills = await discoverSkills(
      resolvedEnv,
      projectRoots: roots.projectRoots,
      userRoots: roots.userRoots,
    );
    final contextFiles = await loadProjectContextFiles(resolvedEnv);
    final promptSuffix = [
      if (formatProjectContext(contextFiles).isNotEmpty)
        formatProjectContext(contextFiles),
      if (formatSkillsForPrompt(skills).isNotEmpty)
        formatSkillsForPrompt(skills),
    ].join('\n\n');
    // Always wrap: the `request_secret` tool injects user-granted keys into
    // the LIVE env at runtime (see [_handleSecretRequest]), so the wrapper
    // must be in place even when the boot-time secret set is empty.
    final secretsEnv = SecretsExecutionEnv(resolvedEnv, secrets);
    return AgentService._withEnv(
      env: secretsEnv,
      secretsEnv: secretsEnv,
      sessionKeys: sessionKeys,
      config: config,
      redactor: redactor,
      streamFunction: streamFunction,
      taskModelsStore: taskModelsStore,
      webSearchConfig: WebSearchConfig(secrets: secretsStore),
      initialApprovalMode: savedApprovalMode,
      approvalModeStore: approvalModeStore,
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

  AgentService._withEnv({
    required this.env,
    required AgentConfig config,
    SecretRedactor? redactor,
    WebSearchConfig? webSearchConfig,
    StreamFunction? streamFunction,
    MediaKeyResolver? resolveSecretName,
    SecretsExecutionEnv? secretsEnv,
    SessionKeysStore? sessionKeys,
    TaskModelsStore? taskModelsStore,
    String promptSuffix = '',
    ApprovalMode? initialApprovalMode,
    ApprovalModeStore? approvalModeStore,
  }) : _config = config,
       _resolveSecretName = resolveSecretName,
       _secretsEnv = secretsEnv,
       _sessionKeys = sessionKeys,
       _taskModelsStore = taskModelsStore,
       _promptSuffix = promptSuffix,
       _approvalModeStore = approvalModeStore,
       approval = ApprovalManager(
         mode: initialApprovalMode ?? ApprovalMode.write,
       ),
       sessionsRoot = '${env.cwd}/sessions',
       _repo = JsonlSessionRepo(fs: env, sessionsRoot: '${env.cwd}/sessions') {
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
    // persist facts across sessions.
    _subagentManager = SubagentManager(parentSessionId: '');
    _memoryController = MemoryController(env: env);
    // Task tool config: childTools is set after the full registry is built
    // (children inherit the core surface minus `task` itself).
    _taskConfig = TaskToolConfig(
      childTools: const [],
      streamFunction: streamFunction ?? _streamFunctionFor(config),
      model: config.toModel(),
      subagentManager: _subagentManager,
    );
    final registry = ToolRegistry([
      ...builtinTools(
        toolEnv,
        webSearch: isOnDevice ? null : webSearchConfig,
        model: () => _agent.state.model,
      ),
      ...memoryTools(_memoryController),
      ...subagentMonitoringTools(manager: _subagentManager),
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
      subagentManager: _subagentManager,
    );
    // Re-register the task tool with the real child surface.
    registry.register(taskTool(config: _taskConfig!));
    _agent = Agent(
      model: config.toModel(),
      systemPrompt: _composeSystemPrompt(config),
      streamFunction: streamFunction ?? _streamFunctionFor(config),
      toolRegistry: registry,
    );
    _attachRedactor(redactor);
    _attachApproval();
    _agent.subscribe(_onAgentEvent);
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
  void _attachRedactor(SecretRedactor? redactor) {
    if (redactor == null) return;
    attachSecretRedactor(_agent, redactor);
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

  /// Task tool config (child surface set after registry is built).
  TaskToolConfig? _taskConfig;

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
    _redactor?.register(result.name, result.value);
    return RequestSecretResult(
      name: result.name,
      value: result.value,
      persisted: _sessionKeys != null,
    );
  }

  /// Exposes the agent's registered tools to tests (ask-tool wiring checks).
  @visibleForTesting
  List<Tool> get toolsForTest => _agent.state.tools;

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

  late final Agent _agent;

  /// Response deadline for one agent run; 10 minutes for the on-device
  /// providers (WebLLM's and transformers.js's first run compiles WebGPU
  /// shaders; Gemma loads multi-GB weights), 90 s otherwise.
  /// Reassigned by [reconfigure] when the backend kind changes.
  late Duration _responseTimeout;
  final JsonlSessionRepo _repo;
  final String sessionsRoot;

  /// Provider adapter kind of the active backend (`openai-completions`,
  /// `webllm`, ...). Updated by [reconfigure].
  String get providerKind => _providerKind;
  late String _providerKind;

  /// Base URL of the active backend, tracked alongside [_providerKind] and
  /// updated by [reconfigure]; empty for the on-device providers. The
  /// settings Media models section uses it as the editor's
  /// placeholder/default.
  String get activeBaseUrl => _activeBaseUrl;

  /// Model id of the active backend, read live from the agent's model state;
  /// the settings Task models section uses it as the editor's placeholder.
  String get agentModelId => _agent.state.model.id;

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
  String get modelId => _agent.state.model.id;

  /// Redactor captured at construction so [reconfigure] can rebuild the
  /// system prompt's secret-name hint.
  SecretRedactor? _redactor;

  /// Rendered skills + project-context sections appended to the composed
  /// system prompt (discovered in [AgentService.create]).
  final String _promptSuffix;

  /// The base system prompt plus the skills/context suffix (kept as one
  /// place so model/provider switches preserve the sections).
  String _composeSystemPrompt(AgentConfig config) {
    final base = _effectiveSystemPrompt(config, _redactor);
    final parts = [
      base,
      if (_projectMountNote() case final note?) note,
      if (_promptSuffix.isNotEmpty) _promptSuffix,
    ];
    return parts.join('\n\n');
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

  Session? _session;
  String? _sessionId;
  String? _sessionFile;
  int _persistedCount = 0;
  FahChatMessage? _currentAssistantMessage;
  FahChatMessage? _currentThinkingMessage;

  /// Id of the session new messages persist to (`null` until [initialize]).
  String? get currentSessionId => _sessionId;

  /// Session-correlation env vars injected into bash tool executions (see
  /// [SessionVarsExecutionEnv]). Read live per exec, so a session (re)load
  /// or a provider/model switch is picked up by later commands. Never
  /// secret values — ids, paths, provider kinds, model ids.
  Map<String, String> _sessionEnvVars() => {
    if (_sessionId case final id?) sessionIdEnvVar: id,
    if (_sessionFile case final path?) sessionFileEnvVar: path,
    providerEnvVar: _providerKind,
    modelEnvVar: _agent.state.model.id,
  };

  /// Initializes session persistence.
  Future<void> initialize() async {
    final session = await _repo.create(
      JsonlSessionCreateOptions(
        cwd: _agent.state.model.provider,
        metadata: {'agent': 'fa', 'model': _agent.state.model.id},
      ),
    );
    _session = session;
    final sessionMetadata = await session.getMetadata();
    _sessionId = sessionMetadata.id;
    _sessionFile = sessionMetadata.path;
  }

  /// Sends a plain-text user message. While the agent is already running the
  /// message is queued as a steering message and the UI shows it as pending
  /// until the next turn picks it up.
  @override
  Future<void> sendText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
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
    _persistChain = _persistChain.then((_) => _persist()).catchError((
      Object _,
    ) {
      // Best effort: the transcript stays in memory; the next trigger
      // retries the missed appends (see _persistedCount).
    });
  }

  @override
  void dispose() {
    _idleWatchdog?.cancel();
    _liveActivityEndTimer?.cancel();
    fsRevision.dispose();
    super.dispose();
  }

  /// Waits until the agent becomes idle.
  Future<void> waitForIdle() => _agent.waitForIdle();

  /// Clears the in-memory transcript and starts a new session.
  Future<void> reset() async {
    _agent.reset();
    messages.clear();
    error = null;
    _persistedCount = 0;
    _currentAssistantMessage = null;
    await initialize();
    notifyListeners();
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
      'model.headers=${newModel.headers?.keys.toList() ?? null}, '
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
      redactor: _redactor,
      streamFunction: _agent.streamFunction,
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
    );
  }

  /// Lists persisted sessions, newest first (across all provider dirs under
  /// [sessionsRoot]). Cheap: reads only the JSONL headers.
  Future<List<SessionMetadata>> listSessions() => _repo.list();

  /// Loads a persisted session into the chat: the agent's context and the
  /// visible transcript are replaced by the session's active branch, and new
  /// messages append to that session.
  Future<void> loadSession(SessionMetadata metadata) async {
    abort();
    await waitForIdle();
    final session = await _repo.open(metadata);
    final contextMessages = await session.buildContextMessages();
    _agent.reset();
    _agent.state.messages = contextMessages;
    _session = session;
    _sessionId = metadata.id;
    _sessionFile = metadata.path;
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
        return FahChatMessage(
          role: 'user',
          content: blocks
              .whereType<TextContent>()
              .map((b) => b.text)
              .join('\n'),
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
        try {
          await _persist();
        } on Object {
          // The transcript stays in memory; the next run retries the
          // missed appends (see _persistedCount).
        }
        await _maybeAutoCompact();
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

  Future<void> _persist() async {
    final session = _session;
    if (session == null) return;
    final all = _agent.state.messages;
    for (final message in all.skip(_persistedCount)) {
      await session.appendMessage(message);
    }
    _persistedCount = all.length;
  }

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

  /// Auto-compaction after each completed run (CLI parity): when the
  /// estimated transcript crosses the scaled threshold, the oldest history
  /// is summarized so the next engine call still fits the window. Best
  /// effort — a failure leaves the history untouched and a later turn
  /// retries.
  Future<void> _maybeAutoCompact() async {
    final conversationWindow = _conversationWindow;
    if (_session == null || conversationWindow <= 0) return;
    final settings = compactionSettings;
    final transcriptTokens = estimateContextTokens(
      _agent.state.messages,
    ).tokens;
    if (!shouldCompact(transcriptTokens, conversationWindow, settings)) {
      return;
    }
    // The whole transcript fits in the kept region: compaction could not
    // drop anything. (A single oversized message can still overflow the
    // engine — that surfaces as a readable run error, not a compaction
    // loop.)
    if (transcriptTokens <= settings.keepRecentTokens) return;
    await _compact(settings);
  }

  Future<void> _compact(CompactionSettings settings) async {
    final session = _session;
    if (session == null) return;
    try {
      final smolConfig = _taskModelsStore?.overrideFor(TaskRole.smol);
      final StreamFunction summarizeStream;
      final Model summarizeModel;
      if (smolConfig != null && smolConfig.modelId.isNotEmpty) {
        // Resolve the API key: the smol config's named key from the session
        // secrets, falling back to the main connection's active key.
        var apiKey = _activeApiKey;
        final keyName = smolConfig.apiKeyName;
        if (keyName != null && keyName.isNotEmpty) {
          final resolved = _secretsEnv != null
              ? _secretsEnv.secretsSnapshot()[keyName]
              : null;
          if (resolved != null && resolved.isNotEmpty) apiKey = resolved;
        }
        summarizeModel = Model(
          id: smolConfig.modelId,
          name: smolConfig.modelId,
          api: _agent.state.model.api,
          provider: _agent.state.model.provider,
          baseUrl: smolConfig.baseUrl,
          contextWindow: _agent.state.model.contextWindow,
          maxTokens: _agent.state.model.maxTokens,
          input: _agent.state.model.input,
        );
        summarizeStream = providerStreamFunction(
          smolConfig.providerKind,
          apiKey,
        );
      } else {
        summarizeStream = _agent.streamFunction;
        summarizeModel = _agent.state.model;
      }
      final manager = CompactionManager(
        summarize: streamFunctionSummarizer(summarizeStream, summarizeModel),
        settings: settings,
      );
      final record = await manager.compactSession(session);
      if (record == null) return;
      // Replace the in-memory transcript (and its UI projection) with the
      // session's compacted context, mirroring loadSession.
      _agent.state.messages = await session.buildContextMessages();
      _persistedCount = _agent.state.messages.length;
      messages
        ..clear()
        ..addAll(_agent.state.messages.map(_toChatMessage));
      notifyListeners();
    } on Object {
      // Best effort, like persistence: a failed compaction must not leak
      // into the agent's event plumbing; the next turn retries.
    }
  }
}

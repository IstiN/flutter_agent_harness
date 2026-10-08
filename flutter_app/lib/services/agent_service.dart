import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:fa_ui/fa_ui.dart'
    show
        FaApprovalModeController,
        FaChatAttachment,
        FaChatConnection,
        FaChatMessage,
        FaChatService,
        ProviderPreset,
        TrajectoryServiceFeed,
        hostedProviderKeyName,
        hostedProviderPresets,
        providerForBaseUrl;
import 'package:fa_ui/fa_ui.dart' as fa_ui show emptyResponsePlaceholder;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'power_guard.dart';

import 'app_log.dart';
import 'app_config_loader.dart';
import 'image_registry_loader.dart';
import 'memory_config_loader.dart';
import 'compaction_engine_loader.dart';
import 'agent_tool_availability.dart';
import 'relay/ext_runtime.dart';
import 'session_names_store.dart';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/app_preflight.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/apps/js_app_error_channel.dart';
import 'package:fa/apps/dynamic_messages.dart';
import 'package:fa/apps/open_app_tool.dart';
import 'package:fa/l10n/l10n_ext.dart';
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
import 'package:fa/services/mobile/mobile_services.dart';
import 'package:fa/services/notify_service.dart';
import 'package:fa/services/notify_tool.dart';
import 'package:fa/services/office/office_boot.dart';
import 'package:fa/services/agent_network_controller.dart';
import 'package:fa/services/task_models_store.dart';
import 'package:fa/services/video_service.dart';
import 'package:fa/services/video_tool.dart';
import 'package:fa/services/tools_availability_store.dart';
import 'package:fa/gemma/gemma_service.dart';
import 'package:fa/gemma/gemma_stream_function.dart';
import 'package:fa/gemma/gemma_types.dart';
import 'package:fa/services/project_mount_env.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_parse_factory.dart';
import 'package:fa/services/session_listing.dart';
import 'package:fa/services/sessions_root.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/skills_access_store.dart';
import 'package:fa/services/skills_toggles_store.dart';
import 'package:fa/prompts.g.dart';
import 'package:fa/sandbox/sandbox_registry.dart';
import 'package:fa/services/secrets_store.dart';
import 'package:fa/transformers_js/transformers_js_service.dart';
import 'package:fa/transformers_js/transformers_js_stream_function.dart';
import 'package:fa/transformers_js/transformers_js_types.dart';
import 'package:fa/services/upload.dart';
import 'package:fa/webllm/webllm_service.dart';
import 'package:fa/webllm/webllm_stream_function.dart';
import 'package:fa_office_agent/fa_office_agent.dart'
    show OfficeApi, officeToolApprovalOverrides, outlookTools;
import 'package:fa/webllm/webllm_types.dart';

part 'agent_service_compaction.dart';
part 'agent_service_config.dart';
part 'agent_service_prompt.dart';
part 'agent_service_assistant.dart';
part 'agent_service_events.dart';
part 'agent_service_sessions.dart';
part 'agent_service_skills.dart';
part 'agent_service_runs.dart';
part 'agent_service_connection_guard.dart';
part 'agent_service_persistence.dart';
part 'agent_service_transcript.dart';
part 'agent_service_inbox.dart';
part 'agent_service_history.dart';
part 'agent_service_wiring.dart';
part 'agent_service_media.dart';
part 'agent_service_background.dart';
part 'agent_service_subagents.dart';
part 'agent_service_lifecycle.dart';

/// A UI-facing chat message.

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

/// Platforms whose agent runs without host-process spawning: MCP stdio
/// servers are "not applicable" there (the `config` tool refuses them —
/// issue #29 AC11); remote (`url`) MCP servers stay configurable.
const _noProcessPlatforms = {'web', 'android', 'ios'};

/// Wraps an [Agent] for the Flutter chat UI.
///
/// Persists sessions to [sessionsRoot] via [JsonlSessionRepo] and translates
/// agent lifecycle events into a list of [FahChatMessage].
class AgentService extends ChangeNotifier
    implements FaChatConnection, FaApprovalModeController, FaChatService {
  /// The app's live service, when one exists (cleared on dispose).
  /// Settings surfaces that need agent-scoped state (the DAP page's
  /// agent-network row, issue #402) read it here instead of threading the
  /// service through widget trees. Null in widget tests.
  static AgentService? maybeCurrent;

  /// A hosted service (the SW relay) overrides this with a session-names
  /// store whose renames round-trip through the hosting backend so every
  /// surface sees them; `null` keeps the env-file store.
  SessionNamesStore? get namesStoreOverride => null;

  /// The agent's opt-in hub membership (issue #402) — surfaces read the
  /// live state and toggle the join from here.
  AgentNetworkController get agentNetwork =>
      _agentNetwork ?? (throw StateError('agentNetwork before initialize()'));

  /// The sleep-prevention guard (issue #325): acquired on `initialize`,
  /// released on `dispose`. Null (tests, web, `off` config) runs the
  /// session unguarded; failures only log.
  final PowerAssertionController? powerAssertion;

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
    @visibleForTesting bool includeSharedSessionRoots = true,
    this.powerAssertion,

    /// Per-task-role model overrides for tests (gh-1077): when given, the
    /// store-backed roles resolver is built exactly like [_withEnv]'s, so
    /// the IT suite can exercise the smol summarizer chain end to end.
    @visibleForTesting TaskModelsStore? taskModelsStore,

    /// Boot secrets for the roles resolver (and the redactor) on this
    /// constructor — the [SecretsExecutionEnv] snapshot equivalent.
    @visibleForTesting Map<String, String> bootSecrets = const {},

    /// The owner context-window cap (`agent.contextWindowCap`, gh-1077):
    /// drives the compaction wiring and the loop's over-window guard.
    @visibleForTesting int? contextWindowCap,

    /// Test seam for the roles resolver's stream factory (gh-1077 IT-1):
    /// lets the IT suite fake the smol summarizer's provider adapter
    /// instead of building a real HTTP one. Null = the default.
    @visibleForTesting
    StreamFunction Function(String kind, String apiKey)? rolesStreamFactory,
  }) : _resolveSecretName = null,
       _providerRegistry = null,
       // ignore: prefer_initializing_formals
       _watchExternalSessions = watchExternalSessions,
       // ignore: prefer_initializing_formals
       _includeSharedSessionRoots = includeSharedSessionRoots,
       _secretsEnv = null,
       _sessionKeys = null,
       // ignore: prefer_initializing_formals
       _taskModelsStore = taskModelsStore,
       _approvalModeStore = null,
       _skillsAccessStore = null,
       _skillsHomeDir = null,
       _skillsAccess = SkillsAccess.granted,
       _skillTogglesStore = null,
       _toolsAvailabilityStore = null,
       // ignore: prefer_initializing_formals
       _contextWindowCap = contextWindowCap,
       approval = ApprovalManager(
         mode: initialApprovalMode ?? ApprovalMode.write,
       ),
       _repo =
           repo ??
           // Issue #522: the deletion gate reads the shared live-session
           // heartbeats — the app must not delete a session a CLI owns.
           JsonlSessionRepo(
             fs: env,
             sessionsRoot: sessionsRoot,
             // Resume diagnostics: session-open timings as `resume_timing`
             // lines in the app debug log (logs/app.log).
             timingLog: (line) => AppLog.i('resume', line),
             presenceStore: FileSessionPresenceStore(
               env: env,
               root: sessionsRoot,
             ),
           ) {
    maybeCurrent = this;
    _responseTimeout = responseTimeout ?? const Duration(seconds: 90);
    _providerKind = _agent.state.model.provider;
    // Seed the active endpoint from the model (reconfigure overwrites it) so
    // endpoint-aware UI never reads an uninitialized late field.
    _activeBaseUrl = _agent.state.model.baseUrl;
    _activeApiKey = '';
    _wireImageDropNotice();
    _wireTextOnlyImageDropNotice();
    _wireDeliverySloNotice();
    _redactor = redactor;
    _attachRedactor(redactor, bootSecrets);
    // gh-1077: the store-backed roles resolver — identical construction
    // to [_withEnv]'s, so tests drive the real smol resolution path.
    if (taskModelsStore != null) {
      _taskRolesResolver = ModelRolesResolver(
        config: ModelRolesConfig(roles: StoreBackedRolesMap(taskModelsStore)),
        secrets: bootSecrets,
        streamFactory: rolesStreamFactory,
      );
    }
    // gh-1077 AC4: the loop's over-window guard relief — one synchronous
    // compaction before the guard refuses (mutable knob: the agent
    // arrives pre-built here).
    _agent.overWindowRelief = (overWindow) => _relieveOverWindow(overWindow);
    _attachApproval();
    _agent.subscribe(_onAgentEvent);
    // Chat surfaces (the ✦ dynamic-messages list, inline widget tiles)
    // must never hit an uninitialized field on this path either.
    dynamicMessages = _buildDynamicMessages();
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

  /// F4: cap drops must never be silent — same rule as the CLI's dim
  /// line, surfaced through the app debug log (logs/app.log). Armed from
  /// every constructor (public, `_withEnv`, relay base delegates here).
  static void _wireImageDropNotice() {
    imageDropNotice = (index, keyPreview) {
      AppLog.i(
        'images',
        'dropping [Image $index] (key $keyPreview…) '
            '— per-request cap reached',
      );
    };
  }

  /// Text-only model image drops must never be silent either (issue #638):
  /// same AppLog surface as the cap-drop notice above.
  static void _wireTextOnlyImageDropNotice() {
    textOnlyImageDropNotice = (dropped) {
      AppLog.i(
        'images',
        '$dropped image(s) dropped — model declared text-only',
      );
    };
  }

  /// Delivery SLO stages must never be silent (issue #647 AC6): the app
  /// surface is AppLog (`logs/app.log`), same rule as the drop notices
  /// above. Armed from every constructor (public, `_withEnv`, relay base
  /// delegates here).
  static void _wireDeliverySloNotice() {
    deliverySloSink = (line) => AppLog.i('slo', line);
  }

  /// Relay-mode base construction (issue #34 item 1): builds the shell the
  /// [RelayAgentService] extends — an idle local agent that never runs (its
  /// stream function throws if it ever were), a memory env, and no external
  /// session watching. Every chat surface member is overridden by the
  /// subclass; the local loop below stays untouched.
  AgentService.relayBase()
    : this(
        agent: Agent(
          streamFunction: _idleRelayStreamFunction,
          toolRegistry: ToolRegistry(const []),
        ),
        env: MemoryExecutionEnv(),
        sessionsRoot: 'memory://relay',
        watchExternalSessions: false,
      );

  /// The idle loop behind [relayBase]: proof it never runs.
  static AssistantMessageEventStream _idleRelayStreamFunction(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    throw UnsupportedError('relay mode: the local agent loop never runs');
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
    OfficeApi? officeApi,

    /// Overrides the platform session-parse executor (issue #199). Tests
    /// inject a fake to keep parsing deterministic; production passes
    /// `createSessionParseExecutor()` (null on web → inline parsing).
    @visibleForTesting SessionParseExecutor? parseExecutor,

    /// Overrides the `~/.fah` home the yaml loader reads (issue #1078).
    String? configHomeDir,
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
    final skillTogglesStore = SkillsTogglesStore(resolvedEnv);
    final savedSkillToggles = await skillTogglesStore.load();
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
      skillToggles: savedSkillToggles,
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
      providerRegistry: providerRegistry,
      redactor: redactor,
      bootSecrets: secrets,
      streamFunction: streamFunction,
      watchExternalSessions: watchExternalSessions,
      taskModelsStore: taskModelsStore,
      parseExecutor: parseExecutor ?? createSessionParseExecutor(),
      sessionsRoot: resolvedSessionsRoot,
      officeApi: officeApi ?? bootOfficeApi(),
      webSearchConfig: WebSearchConfig(secrets: secretsStore),
      initialApprovalMode: savedApprovalMode,
      approvalModeStore: approvalModeStore,
      initialSkillsAccess: savedSkillsAccess ?? SkillsAccess.granted,
      skillsAccessStore: skillsAccessStore,
      initialSkillToggles: savedSkillToggles,
      skillTogglesStore: skillTogglesStore,
      initialToolsConfig: savedToolsConfig,
      toolsAvailabilityStore: toolsAvailabilityStore,
      // Sleep prevention (issue #325): one assertion for the app
      // session's lifetime; null on web / off / unreadable config.
      powerAssertion: createAppPowerAssertion(),
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
      configHomeDir: configHomeDir,
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

  AgentService._withEnv({
    Map<String, String> bootSecrets = const {},
    required this.env,
    required AgentConfig config,
    required String sessionsRoot,
    SecretRedactor? redactor,
    WebSearchConfig? webSearchConfig,
    StreamFunction? streamFunction,
    bool watchExternalSessions = true,
    bool includeSharedSessionRoots = true,
    MediaKeyResolver? resolveSecretName,
    OfficeApi? officeApi,
    // The session-parse executor (issue #199): non-null routes ALL record
    // parsing through it (background isolates in production); null keeps
    // inline parsing (tests stay deterministic).
    SessionParseExecutor? parseExecutor,
    this._secretsEnv,
    this._sessionKeys,
    this._taskModelsStore,
    ProviderRegistry? providerRegistry,
    this._promptSuffix = '',
    ApprovalMode? initialApprovalMode,
    this._approvalModeStore,
    SkillsAccess? initialSkillsAccess,
    this._skillsAccessStore,
    Map<String, bool> initialSkillToggles = const {},
    this._skillTogglesStore,
    ToolsConfig? initialToolsConfig,
    this._toolsAvailabilityStore,
    String? skillsHomeDir,
    this.powerAssertion,

    /// The `~/.fah` home the yaml loader reads (issue #1078).
    String? configHomeDir,
  }) // ignore: prefer_initializing_formals — private fields, public params
    // ignore: prefer_initializing_formals
    : _skillsHomeDir = skillsHomeDir,
       // ignore: prefer_initializing_formals
       _watchExternalSessions = watchExternalSessions,
       // ignore: prefer_initializing_formals
       _includeSharedSessionRoots = includeSharedSessionRoots,
       _config = config,
       _skillsAccess = initialSkillsAccess ?? SkillsAccess.granted,
       _skillToggles = initialSkillToggles,
       _resolveSecretName = resolveSecretName,
       // ignore: prefer_initializing_formals
       _providerRegistry = providerRegistry,
       approval = ApprovalManager(
         mode: initialApprovalMode ?? ApprovalMode.write,
         // Outlook taskpane (issue #182): read_attachment streams
         // attacker-controlled bytes and insert_draft_body rewrites the
         // user's draft — both prompt on EVERY call in EVERY session mode
         // (the override outranks mode, turn grants and always-allow).
         overrides: officeApi == null
             ? const {}
             : officeToolApprovalOverrides(),
         overrideOrigins: officeApi == null
             ? const {}
             : {
                 for (final name in officeToolApprovalOverrides().keys)
                   name: 'Outlook always-prompt guard',
               },
       ),
       sessionsRoot = sessionsRoot,
       _repo = JsonlSessionRepo(
         fs: env,
         sessionsRoot: sessionsRoot,
         parseExecutor: parseExecutor,
         // Issue #522: deletions refuse sessions with a live CLI heartbeat.
         presenceStore: FileSessionPresenceStore(env: env, root: sessionsRoot),
       ) {
    maybeCurrent = this;
    _wireImageDropNotice();
    _wireTextOnlyImageDropNotice();
    _wireDeliverySloNotice();
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
    final fileFabricRepo = FileMessagingRepository(
      env: env,
      root: messagesRoot,
      decodeSessionCwd: decodeSessionCwd,
      homeDir: null,
    );
    // The fabric behind the agent is swappable: opting into the hub
    // network (issue #402) swaps the hub-primary composite in without
    // touching any holder of the reference.
    final fabricRepo = SwappableMessagingRepository(fileFabricRepo);
    // gh-1180 AC4: the persisted receipt trail for scheduled mail —
    // scheduled / delivered / delivery_failed / scan_failed — so a
    // post-mortem can tell "timer never fired" from "wake refused"
    // without reading source. Best-effort: a failing trail logs only.
    // Held on the service (see [_scheduledReceipts]): the app host's
    // wake path appends its events to the same trail.
    _scheduledReceipts = ScheduledReceiptLog(
      env: env,
      path: () => '$messagesRoot/_scheduled/receipts.jsonl',
      onError: (text) => AppLog.i('sched', text),
    );
    _scheduledMessages = ScheduledMessageQueue(
      env: env,
      repo: () => fabricRepo,
      root: () => messagesRoot,
      // Self-reminders must target the session's real mailbox — the legacy
      // literal 'self' leaked them into a phantom mailbox (the fired mail
      // itself is already visible in chat as a user message, so no extra
      // UI notice channel here; the CLI prints [sched] lines).
      selfMailbox: () => _subagentManager?.mailboxOf('main') ?? 'main',
      // Ownership tag for schedule records: a sweeper re-addresses a
      // self-addressed record only when the stored prefix matches this
      // session — another instance's record stays with its owner (#59).
      ownerPrefix: () => _subagentManager?.mailboxPrefix ?? '',
      // Failure isolation (issue #270): a failed delivery lands in the
      // app log, never kills the delivery heartbeat — the record stays
      // for the next sweep.
      onError: (text) => AppLog.i('sched', text),
      receipts: _scheduledReceipts,
    );
    // Arm the delivery timer; best-effort (an unwritable root keeps the
    // app booting, the tools just report unavailable).
    unawaited(_scheduledMessages.start());
    _subagentManager = SubagentManager(
      parentSessionId: '',
      messaging: fabricRepo,
      selfId: 'main',
    );
    // The app agent's opt-in hub membership (issue #402 AC3): the
    // controller owns the settings store and swaps the hub-primary
    // composite over the file fabric when enabled.
    final network = AgentNetworkController(
      env: env,
      fileLayer: fileFabricRepo,
      fileFabric: fabricRepo,
    );
    _agentNetwork = network;
    unawaited(network.start());
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
    // The yaml sections the app honors (issue #1078): the CLI's own
    // parsers; warnings surface once here, boot never blocks (E2/AC7).
    final appConfig = loadAppFahConfig(
      projectDir: env.sessionCwd,
      homeDir: configHomeDir,
    );
    for (final warning in appConfig?.warnings ?? const <String>[]) {
      AppLog.i('config', warning);
    }
    // AC5: the SAME global the CLI publishes — re-set every creation so
    // a config edit applies to the next session; AC4's pipeline config.
    // FA_PROVIDER_TIMEOUT_SECONDS folds in over the yaml section (issue
    // #1036, review round 1): the same env-wins precedence the CLI boot
    // applies, so both hosts resolve identical watchdog budgets.
    try {
      providerTimeoutsOverride = applyProviderTimeoutEnvOverride(
        appConfig?.providerTimeouts,
        faProviderTimeoutSecondsEnv(),
      );
    } on ConfigException catch (error) {
      // Degrade like every other config problem here (E2): warn and keep
      // the yaml section — boot never blocks on a malformed env override.
      AppLog.i('config', error.message);
      providerTimeoutsOverride = appConfig?.providerTimeouts;
    }
    _yamlRedactConfig = appConfig?.redact;
    // Session image registry (`images:` section, issue #171): process-wide
    // like in the CLI; core default is on, user config honored where the
    // config is readable.
    imageRegistryConfig =
        loadAppImageRegistryConfig() ?? const ImageRegistryConfig();
    _memoryController = MemoryController(
      env: env,
      // User-scope memory root (gh-1276): without it every user-scope
      // add is a silent no-op that still reports "saved". Desktop → the
      // real home (CLI parity, ~/.fah/memory); sandboxed platforms
      // (iOS/Android/web, no OS home) → a sandbox-local root next to the
      // project store.
      userRoot: appMemoryUserRoot(
        configHomeDir: configHomeDir,
        desktopHome: desktopHomeDir(),
        envCwd: env.cwd,
      ),
      // `memory:` section of ~/.fah/config.yaml — the same git-backed
      // memory path overrides the CLI honors (null = .fah/memory default).
      projectStoragePath: memoryConfig?.projectPath,
      userStoragePath: memoryConfig?.userPath,
      // Semantic search + consolidate() need an LLM: per call the smol
      // task-model override (resolver is built below — the closure reads it
      // lazily), else the main model.
      llmProvider: HarnessLlmProvider(resolve: () => _resolveMemoryLlmSlot()),
      // gh-1393: the degrade swallows (LLM search → keywords, plain-store
      // add fallback) leave a breadcrumb in the app log — the iOS
      // "Invalid core" family becomes diagnosable in the field.
      onDegrade: (message) => AppLog.i('memory', message),
    );
    // Model-roles resolver backed by the TaskModelsStore: `smol` (compaction
    // + explore) and `subagent` (delegation) overrides resolve through it;
    // the Map reads the store lazily, so settings changes apply on the next
    // spawn without rebuilding the agent. yaml `roles:` fills the gaps
    // (AC1, E1: store wins per role); the MAIN model is never re-pointed
    // from config — unlike the CLI, it stays the explicit UI choice.
    final taskModelsStore = _taskModelsStore;
    final yamlRoles = appConfig?.roles;
    if (taskModelsStore != null || yamlRoles != null) {
      _taskRolesResolver = ModelRolesResolver(
        config: ModelRolesConfig(
          // gh-1077 AC5: StoreBackedRolesMap is the public, parity-tested
          // app-stores → roles mapping; #1078 layers the yaml fallback.
          roles: StoreBackedRolesMap(
            taskModelsStore,
            fallback: yamlRoles?.roles,
          ),
          pathOverrides: yamlRoles?.pathOverrides ?? const [],
          retry: yamlRoles?.retry ?? const ModelRolesRetryPolicy(),
        ),
        secrets: _secretsEnv?.secretsSnapshot() ?? const {},
      );
      // 429 rotation notices surface in the log (CLI parity).
      _taskRolesResolver!.onNotice = (notice) =>
          AppLog.i('roles', notice.describe());
      _taskRolesResolver!.sessionId = () => _session?.cachedId;
    }
    // Task tool config: childTools is set after the full registry is built
    // (children inherit the core surface minus `task` itself). ONE shared
    // job manager across both configs (placeholder + final) so task_cancel
    // and the tool always see the same jobs.
    final taskJobManager = TaskJobManager();
    _taskConfig = TaskToolConfig(
      childTools: const [],
      // Live accessors (resolved per spawn): a provider switch or SSO
      // re-auth re-points `_agent.streamFunction`, and children spawned
      // afterwards must inherit the live credential — a wiring frozen at
      // boot would send the stale key (401).
      streamFunction: () => _agent.streamFunction,
      model: () => _agent.state.model,
      subagentManager: _subagentManager,
      jobManager: taskJobManager,
    );
    // Background shell jobs (bash background: true / steer-yielded commands).
    // Sandboxed environments without the BackgroundShell capability answer a
    // clean "not supported" note; completions re-enter via sendText (steer
    // mid-run, fresh turn while idle).
    _shellJobs = ShellJobRegistry(env: toolEnv, onSettled: _onShellJobSettled);
    // Background `task` jobs settle the same way (issue #958): the settled
    // child's async-result re-enters the conversation — steered mid-run,
    // a fresh turn while idle. Without this the orchestrator sits idle
    // until the user pings.
    _taskCompletionsSub = taskJobManager.completions.listen(
      _onTaskJobCompleted,
    );
    // gh-1164 Part B: JS app render/runtime/load errors ride the shared
    // error channel — a gated notice re-enters the conversation the same
    // way (steered mid-run, a fresh system-notice turn while idle).
    _jsAppErrorSub = JsAppErrorChannel.instance.onDeliver.listen(
      _onJsAppError,
    );
    // Interactive dynamic messages (issue #102): the host machinery behind
    // the `dynamic_message` tool — session-scoped JS widgets rendered
    // inline in the transcript with the full installed-app engine surface.
    dynamicMessages = _buildDynamicMessages();
    final registry = ToolRegistry([
      ...builtinTools(
        toolEnv,
        webSearch: isOnDevice ? null : webSearchConfig,
        shellJobs: _shellJobs,
        onPasswordPrompt: (prompt) async => passwordPromptHandler?.call(prompt),
        // Self-configuration on every host (issue #29 S5/AC10/AC11): the
        // same core the `fa config` CLI verbs wrap, over THIS host's env —
        // desktop container, browser storage, or mobile sandbox. Hosts
        // without host-process spawning answer "not applicable" for
        // stdio-only config keys instead of writing dead config.
        config: ConfigService(
          env: toolEnv,
          homeDir: desktopHomeDir(),
          supportsProcesses: !_noProcessPlatforms.contains(currentFaPlatform),
        ),
      ),
      ...memoryTools(
        _memoryController,
        onChanged: () => unawaited(_refreshMemorySection()),
      ),
      // schedule_message: self-addressed delayed notes, delivered by the
      // fabric's idle-wake (shared with the CLI). gh-970: inside a subagent
      // run "your own mailbox" is the CHILD's — the queue's selfMailbox
      // always resolves main.
      scheduleMessageTool(
        _scheduledMessages,
        senderMailbox: () {
          final id = activeSubagentId();
          final manager = _subagentManager;
          if (id == null || manager == null) return null;
          return manager.mailboxOf(id);
        },
      ),
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
      // Interactive dynamic messages (issue #102): the agent renders a
      // session-scoped JS widget as a chat message; the tool resolves when
      // the host presents it. Hosts without a chat surface never register
      // a callback, so the tool stays absent there (the CLI).
      dynamicMessageTool(
        callback: (request) => dynamicMessages.present(request),
      ),
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
      // On-device automation (issue #622): mobile.* over the Android
      // accessibility/projection/shizuku channels. The store flavor
      // registers launch/logs only — the capability floor gates the rest
      // with the honest sideload reason.
      if (mobilePlatformSupported) ...mobileToolsForFlavor(),
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
      // Outlook taskpane (issue #182): the outlook.* mail surface over the
      // OfficeHostBridge — present only in the office-hosted web build
      // (FA_HOST=office) or when a test injects an api. Bodies enter
      // context only through the quarantine fence (see outlook_tools);
      // approval overrides for the always-prompting pair are seeded into
      // the gate in the initializer above.
      if (officeApi != null) ...outlookTools(officeApi),
    ]);
    _toolRegistry = registry;
    // Boot beacon for the office pane e2e (issue #182): proves the app
    // booted WITH the mail surface when running as the Outlook taskpane.
    if (officeApi != null) {
      debugPrint('[fah] office: outlook.* tools registered (office host)');
    }
    // Wire the task tool's child surface: all tools except `task` itself
    // and the child-only pair the executor injects per spawn — passing them
    // through registers `reply` twice and every child dies with
    // "Duplicate tool name" (the CLI passes coreTools, which never
    // contains them).
    final childSurface = registry.tools
        .where(
          (t) =>
              t.name != taskToolName &&
              !childInjectedToolNames.contains(t.name),
        )
        .cast<AgentTool>()
        .toList();
    _taskConfig = TaskToolConfig(
      childTools: childSurface,
      streamFunction: () => _agent.streamFunction,
      model: () => _agent.state.model,
      rolesResolver: _taskRolesResolver,
      subagentManager: _subagentManager,
      childSessionFactory: _childSessionFactory,
      jobManager: taskJobManager,
    );
    // Re-register the task tool with the real child surface.
    registry.register(taskTool(config: _taskConfig!));
    // Owner context-window cap (gh-1077): `agent.contextWindowCap`, the
    // same project < user config chain the CLI honors. Null = uncapped.
    _contextWindowCap = loadAppContextWindowCap(env.sessionCwd);
    _agent = Agent(
      model: config.toModel(),
      systemPrompt: _composeSystemPrompt(config),
      streamFunction: streamFunction ?? _streamFunctionFor(config),
      toolRegistry: registry,
      // The loop's over-window guard measures against the effective
      // (capped) window, and issue #387 relief gives a hard overflow ONE
      // synchronous compaction before the turn dies — CLI parity.
      contextWindowCap: _contextWindowCap,
      overWindowRelief: (overWindow) => _relieveOverWindow(overWindow),
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
    // ttsr: rules (AC3) — the CLI's controller/manager pair.
    attachAppConfigTtsr(appConfig);
    // Structured compaction recall (issue #148 D3): `compact_expand`
    // resolves numeric marker ids against the LIVE session; the per-turn
    // expand budget resets on every new user message through the agent
    // subscription. Registered after agent construction (the controller
    // needs the agent), mirroring the CLI host.
    final compactExpand = CompactExpandController(
      agent: _agent,
      session: () => _session,
    );
    _compactExpand = compactExpand;
    registry.register(compactExpand.tool);
    _agent.state.tools = registry.tools;
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
      // yaml `tools:` scopes under the runtime store (AC2/E1).
      configScopes: [
        if (appConfig case final s?) (ToolScope.global, s.userTools),
        if (appConfig case final s?) (ToolScope.project, s.projectTools),
      ],
      loadMode: appConfig?.loadMode ?? AgentLoadMode.defaultMode,
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


  /// The system prompt composition lives in the
  /// `agent_service_prompt.dart` part (issue #692 B): `{{commands}}` is
  /// filled from the central sandbox registry for the current platform,
  /// sandboxed hosts additionally get the host-profile section, and the
  /// desktop prompt stays byte-identical. Exposed to tests with an
  /// optional platform override (host tests otherwise always resolve the
  /// desktop profile).
  @visibleForTesting
  static String effectiveSystemPromptForTest(
    AgentConfig config,
    SecretRedactor? redactor, [
    SandboxPlatform? platformOverride,
  ]) => _effectiveAgentSystemPrompt(config, redactor, platformOverride);

  /// The composed registry's tool names, in registration order (issue
  /// #692 AC1 tests): pins the per-host availability floor — surfaces the
  /// sandbox cannot run (LSP, MCP servers, DAP, checkpoints, the sqlite
  /// engine) must be ABSENT from the app registry, not merely error at
  /// call time.
  @visibleForTesting
  List<String> get registeredToolNamesForTest => [
    for (final tool in _agent.state.tools) tool.name,
  ];




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

  /// The user's per-skill on/off wishes (issue #1151 — the app twin of the
  /// CLI `skills:` entries; persisted via [SkillsTogglesStore]). Names
  /// absent from the map are default-on.
  Map<String, bool> _skillToggles = const {};

  /// Generation guard for [setSkillToggle]'s async re-discovery: a newer
  /// toggle change wins over a stale suffix.
  int _skillTogglesGeneration = 0;

  /// The persisted per-skill toggles store ([AgentService.create] path
  /// only); [setSkillToggle] writes through fire-and-forget.
  final SkillsTogglesStore? _skillTogglesStore;

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

  @override
  PasswordPromptCallback? passwordPromptHandler;

  /// Jump-to-message executor installed by the scrolling chat surface
  /// (issue #102 AC5: the ✦ sheet scrolls a widget's message into view).
  @override
  void Function(String messageId)? scrollToMessageHandler;

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

  /// The custom-provider registry ([AgentService.create] path). Backs the
  /// issue #327 connection guards: reconfigure refuses a config whose
  /// model id and endpoint/auth resolve from different registry rows, and
  /// auth-error messages name the owning entry. `null` for services built
  /// around a pre-constructed [Agent] (tests) — guards stay silent.
  final ProviderRegistry? _providerRegistry;

  /// Per-task-role model overrides (`task_models.json`); `null` for services
  /// built around a pre-constructed [Agent] (tests). When the `smol` role
  /// carries an override, compaction uses that model instead of the main
  /// connection.
  final TaskModelsStore? _taskModelsStore;

  /// The owner context-window cap (`agent.contextWindowCap`, gh-1077):
  /// resolved from the app config chain in [_withEnv] (project < user),
  /// injected on the test constructor. Feeds the compaction wiring AND the
  /// loop's over-window guard (via the [Agent] constructor). Null =
  /// uncapped.
  int? _contextWindowCap;

  /// How many times the loop's over-window relief fired (gh-1077 AC4) —
  /// observability seam for the IT suite ("exactly ONE relief attempt").
  @visibleForTesting
  int overWindowReliefCountForTest = 0;

  /// The registry built in [_withEnv]; `null` for services constructed
  /// around a pre-constructed [Agent] (tests), where the registry is owned
  /// by the caller.
  ToolRegistry? _toolRegistry;

  /// The `compact_expand` controller (issue #148): per-turn expand budget
  /// + the tool bound to the live session. Built in [_withEnv] after the
  /// agent exists; null on the pre-constructed-agent (test) path.
  CompactExpandController? _compactExpand;

  /// Subagent manager (Phase 3a): tracks spawned children for the task tool.
  SubagentManager? _subagentManager;

  /// The app agent's opt-in hub membership (issue #402); owns its own
  /// settings store and lifecycle, disposed with the service. Null until
  /// [initialize] builds it — a service disposed without initializing
  /// (tests) has nothing to tear down.
  AgentNetworkController? _agentNetwork;

  /// The session's retained-subagent registry (null before the agent is
  /// built). The settings Agents section renders the live tree from it.
  SubagentManager? get subagentManager => _subagentManager;

  /// Test-only injection: the lightweight constructor (pre-built agent)
  /// never builds the messaging fabric, so widget tests that exercise
  /// subagent surfaces (badge, task list) install a bare manager here.
  @visibleForTesting
  set subagentManager(SubagentManager? manager) => _subagentManager = manager;

  /// Task tool config (child surface set after registry is built).
  TaskToolConfig? _taskConfig;


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
    Future<AppPreflightOutcome?> gate(String appId) =>
        runAppPreflight(appId, env);
    final registry = _toolRegistry;
    if (registry != null) {
      if (launcher == null) {
        registry.unregister(openAppToolName);
      } else {
        registry.register(
          openAppTool(env, launcher: launcher, preflight: gate),
        );
      }
      _agent.state.tools = registry.tools;
    } else {
      // Pre-constructed agent (tests): mirror the registration on the
      // advertised tool list — the tool's execute callback is self-contained.
      final tools = _agent.state.tools
          .where((tool) => tool.name != openAppToolName)
          .toList();
      if (launcher != null) {
        tools.add(openAppTool(env, launcher: launcher, preflight: gate));
      }
      _agent.state.tools = tools;
    }
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

  /// The receipt trail behind [_scheduledMessages] — and, since the
  /// review round, the app host's wake path (gh-1180 AC4): refused wake
  /// attempts are receipted here too, so a post-mortem on the app host
  /// can tell "timer never fired" from "wake refused" (a silent,
  /// unreceipted drop was the ticket's blind-window shape on the second
  /// host). The trail is the app's surfacing for a refusal: the only
  /// user-visible channels (the [error] banner, the Live Activity
  /// failure state) would misreport a healthy-but-held gate as a failed
  /// run. Test seam below.
  late final ScheduledReceiptLog _scheduledReceipts;

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
      final exists = await env.fileInfo(handle.sessionId);
      if (exists.valueOrNull == null) return const [];
      final session = await _repo.open(_subagentSessionMetadata(handle));
      return tailMessagePairs(await session.buildContextMessages(), tail);
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
    ensureSendableSubagent(handle, id);
    try {
      final session = await _repo.open(_subagentSessionMetadata(handle));
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


  /// A follow-up message needs a live-or-idle child; failed/aborted
  /// children have no session to append to.
  static void ensureSendableSubagent(SubagentHandle handle, String id) {
    if (handle.status == SubagentStatus.failed ||
        handle.status == SubagentStatus.aborted) {
      throw StateError('cannot send to ${handle.status.name} subagent "$id"');
    }
  }

  /// The last [tail] messages as `(role, text)` pairs — the observe
  /// payload. Public for tests.
  static List<(String, String)> tailMessagePairs(
    List<Message> messages,
    int tail,
  ) {
    final last = messages.length > tail
        ? messages.sublist(messages.length - tail)
        : messages;
    return [
      for (final message in last) (message.role, _previewMessageText(message)),
    ];
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

  /// Derives the ASR transcriber for jsr bridges (the media_models.json
  /// `transcription` slot, falling back to the active provider); null when
  /// no ASR-capable (OpenAI-compatible) endpoint is configured — the bridge
  /// then answers with an actionable error. Shared by the app view and the
  /// dynamic-message widgets (issue #102 AC6).
  Future<AsrTranscriber?> resolveAsrTranscriber() async {
    final gateway = _mediaGateway;
    if (gateway != null) return whisperTranscriberForGateway(gateway);
    final config = _config;
    return whisperTranscriberFor(
      providerKind: _providerKind,
      baseUrl: config?.baseUrl ?? '',
      apiKey: config?.apiKey ?? '',
    );
  }

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

  /// The yaml `redact:` section (AC4); null = the mask-mode default.
  RedactionConfig? _yamlRedactConfig;

  /// Boot secrets snapshot ([_attachRedactor]): the live re-enable seed.
  Map<String, String> _bootSecrets = const {};

  /// Rendered skills + project-context sections appended to the composed
  /// system prompt (discovered in [AgentService.create]; re-discovered by
  /// [setSkillsAccess] when the third-party consent changes).
  String _promptSuffix;



  /// The cached `<memory>` prompt section (durable facts from past
  /// sessions), refreshed asynchronously after create and on every
  /// `memory_add` — the prompt composition itself stays synchronous.
  String _memorySection = '';



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

  /// New-session support for services whose session does NOT live in this
  /// process (the relay's session is owned by the extension SW; cloning a
  /// local config is impossible there). When non-null, the UI's
  /// new-session flow calls this instead of manager.createSession(clone).
  Future<void> Function()? get newSessionAction => null;

  /// Open-past-session for relayed services (`null` locally): the UI asks
  /// the SW to restore the archive; the attach trio rebuilds the view.
  Future<void> Function(String sessionId)? get openSessionAction => null;

  /// The relayed session id currently attached to (the manager's entry
  /// key can lag it). `null` on local services.
  String? get liveSessionId => null;
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
      // Per-run sleep prevention (#326): the default hold acquires with
      // the run going in flight (the session-held opt-in acquired at
      // session open instead); fire-and-forget, never delays the turn.
      powerAssertion?.onRunStarted();
      unawaited(
        LiveActivity.start(
          sessionTitle: 'Fa agent run',
          statusText: _liveActivityStatusText(),
        ),
      );
    } else {
      unawaited(BackgroundExecution.setScreenAwake(false));
      // The run settled: drop the per-run sleep assertion so an idle
      // agent lets the machine sleep (#326). Idempotent/no-op for the
      // session-held mode's controller policy.
      unawaited(powerAssertion?.onRunSettled());
      final id = _backgroundTaskId;
      _backgroundTaskId = null;
      unawaited(BackgroundExecution.end(id));
      unawaited(_finishLiveActivity());
    }
  }

  bool _isStreaming = false;
  int? _backgroundTaskId;
  Timer? _liveActivityEndTimer;



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

  /// Test-only escape hatch: on macOS dev machines [listSessions] merges the
  /// shared App Group / `~/.fah/sessions` roots (host sessions leak into
  /// hermetic tests); tests pass `includeSharedSessionRoots: false`.
  final bool _includeSharedSessionRoots;

  /// The windowed storage when the open session was opened windowed
  /// (issue #135); null for full-open sessions — no paging surface.
  WindowedSessionStorage? get _windowed {
    final storage = _session?.getStorage();
    return storage is WindowedSessionStorage ? storage : null;
  }

  /// Transcript records sitting above the loaded window
  /// ([FaChatService.historyAboveCount]): `null` while the background
  /// count is still running or unknown (right after a jump), `0` once
  /// the whole transcript is loaded, `N` — what the "Load earlier"
  /// banner shows. A full-open session has no pages above anything —
  /// it reports the contract's complete-transcript `0`, so the banner
  /// never renders on it (issue #974: the first-message sticker).
  @override
  int? get historyAboveCount => _windowed == null ? 0 : _historyAboveCount;
  int? _historyAboveCount;

  /// Hidden-range drill-in (issue #385 F4): resolves a compacted row's
  /// covered records straight from the session file via the windowed
  /// chunk reader — bounded previews, missing ids render as explicit
  /// "not captured" placeholders. Full-open sessions have no hidden
  /// range, so they expose no resolver (the tab stays hidden).
  @override
  Future<List<TrajectoryHiddenRecordPreview>> Function(
    TrajectoryCompactedRecord record,
  )?
  get resolveHiddenRecords {
    final reader = _windowed?.reader;
    if (reader == null) return null;
    return (record) async {
      final ids = record.hiddenRecordIds ?? const <String>[];
      if (ids.isEmpty) return const [];
      try {
        final resolved = await reader.readRecordsByIds(ids.toSet());
        return projectHiddenRecordPreviews(recordIds: ids, resolved: resolved);
      } on Object {
        return [
          for (final id in ids)
            TrajectoryHiddenRecordPreview(
              id: id,
              type: 'missing',
              preview: '[hidden: not captured for this session]',
            ),
        ];
      }
    };
  }

  bool _loadingHistory = false;

  /// Whether a history page ([FaChatService.loadOlderHistory] or
  /// [loadNewerHistory]) is in flight — the banners' spinner state.
  @override
  bool get historyLoading => _loadingHistory;

  /// The exact total record count once the background count landed —
  /// the N of the terminal "Beginning of session (1 of N)" banner
  /// (issue #135 E6); `null` until then and for full-open sessions.
  @override
  int? get historyTotalCount => _windowed?.cachedTotalRecords;

  /// Transcript records BELOW the loaded window (deep paging evicted
  /// the newest side): what the "Load newer" banner shows. `0` for
  /// full-open sessions and at the live tail.
  @override
  bool get historyHasNewer => _windowed?.hasNewer ?? false;

  /// Transcript records below the loaded window; `null` while unknown
  /// (the UI keys banner visibility on [historyHasNewer]).
  @override
  int? get historyBelowCount => _windowed?.countBelow;

  /// The last history-page failure, shown by the history banner
  /// ([FaChatService.historyLoadError]); cleared by a successful retry.
  /// Kept separate from [error] so a failed history page never touches
  /// the live transcript's error line.
  @override
  String? get historyLoadError => _historyLoadError;
  String? _historyLoadError;

  /// The VIEW branch (issue #135 round 2): every loaded branch record,
  /// root-first — what the transcript renders. Paging in either
  /// direction only grows/sets this list; the provider context
  /// ([_agent.state.messages]) is NEVER touched by paging (windowing
  /// is a view concern, not a context concern). `null` for full-open
  /// sessions (rows come straight from the loaded context).
  List<SessionRecord>? _viewBranch;


  /// Pages one chunk of records above the window into the transcript
  /// ([FaChatService.loadOlderHistory]). Re-entrant taps are ignored, as
  /// is any tap mid-run.
  @override
  Future<void> loadOlderHistory() async {
    if (_loadingHistory || isStreaming) return;
    final windowed = _windowed;
    if (windowed == null) return;
    final gen = _loadGeneration;
    _loadingHistory = true;
    _notify();
    try {
      final joined = await windowed.loadOlder();
      if (gen != _loadGeneration) return;
      if (joined.isNotEmpty) {
        await _syncViewToWindow(windowed);
        await _applyViewBranch();
      }
      await _refreshHistoryAbove();
      if (gen != _loadGeneration) return;
      if (_historyLoadError != null) {
        _historyLoadError = null;
        _notify();
      }
    } on Object catch (e) {
      _historyLoadError = e is StateError ? e.message : e.toString();
      _notify();
    } finally {
      _loadingHistory = false;
      _notify();
    }
  }

  /// Pages the transcript back to the live tail
  /// ([FaChatService.loadNewerHistory]) — the page-down path after deep
  /// paging slid the newest side out. NEVER gated on [isStreaming]: the
  /// page-down is a VIEW operation, and mid-run is exactly when the banner
  /// must work — the run keeps appending below a deep-paged window while
  /// the tap was a no-op (issue #1159). One bounded tail read re-centers
  /// the window (jump-to-tail, no chunk crawl); the only guards are a
  /// concurrent page load and a stale load generation.
  @override
  Future<void> loadNewerHistory() async {
    if (_loadingHistory) return;
    final windowed = _windowed;
    if (windowed == null) return;
    // At-tail tap: nothing sits below — skip the rebuild and the
    // whole-file count re-scan entirely.
    if (!windowed.hasNewer) return;
    final gen = _loadGeneration;
    _loadingHistory = true;
    _notify();
    try {
      await windowed.jumpToTail();
      if (gen != _loadGeneration) return;
      // Let an in-flight persist pass flush first so the branch read
      // below observes just-finalized records: a turn boundary landing
      // mid-jump must not leave its row stranded out of view until the
      // next reprojection (review -FbK vanish variant). Best effort —
      // a failed persist must not break the jump.
      if (_persistPass case final pass?) {
        try {
          await pass;
        } on Object {
          // Ignored: the next persist pass retries.
        }
        if (gen != _loadGeneration) return;
      }
      await _syncViewToWindow(windowed);
      if (gen != _loadGeneration) return;
      await _applyViewBranch();
      if (gen != _loadGeneration) return;
      // Live rows the projection cannot know — in-flight tool activity
      // tiles and the streaming assistant/thinking bubbles are plain
      // rows in [messages], not records yet. Re-read AFTER the rebuild
      // settles: capturing earlier races a mid-jump turn boundary into
      // re-appending a bubble the finalize already landed as a record —
      // a duplicate (review -FbK). There is no await between the rebuild
      // and this capture, so the fields are read atomically with the
      // projection snapshot. The contains-check and the empty-bubble
      // guard mirror _finalizeAssistant's own invariants.
      final liveRows = [
        ..._inFlightToolRows.map((e) => e.row),
        if (_currentThinkingMessage case final t?) t,
        if (_currentAssistantMessage case final a?
            when a.content.trim().isNotEmpty)
          a,
      ].where((row) => !messages.contains(row)).toList();
      messages.addAll(liveRows);
      await _refreshHistoryAbove();
      if (gen != _loadGeneration) return;
      _historyLoadError = null;
      _notify();
    } on Object catch (e) {
      _historyLoadError = e is StateError ? e.message : e.toString();
      _notify();
    } finally {
      _loadingHistory = false;
      _notify();
    }
  }

  /// Jump-to-message (issue #135 AC6,
  /// [FaChatService.jumpToMessage]). Two mechanisms:
  ///
  /// - a RECORD id (search / ✦-list / trajectory-link hits): seeks by
  ///   byte offset through the storage's sparse offset map — explored
  ///   history jumps without a re-scan — and re-centers the window;
  /// - a positional `msg-<index>` (transcript row keys): pages older
  ///   history in until the target row is loaded. Bounded — a miss
  ///   resolves as `false`, never a full read.
  @override
  Future<bool> jumpToMessage(String messageId) async {
    final windowed = _windowed;
    if (windowed == null) {
      final index = _positionalRow(messageId);
      if (index == null) return _jumpLoadedRecord(messageId);
      return index >= 0 && index < messages.length;
    }
    if (!messageId.startsWith('msg-')) {
      return _jumpToRecord(windowed, messageId);
    }
    final index = _positionalRow(messageId);
    if (index == null) return false;
    if (_loadingHistory || isStreaming) return index < messages.length;
    final gen = _loadGeneration;
    _loadingHistory = true;
    _notify();
    var reached = index < messages.length;
    try {
      for (var pass = 0; !reached && pass < 100 && windowed.hasOlder; pass++) {
        final joined = await windowed.loadOlder();
        if (joined.isEmpty || gen != _loadGeneration) break;
        await _syncViewToWindow(windowed);
        await _applyViewBranch();
        reached = index < messages.length;
      }
    } on Object catch (e) {
      _historyLoadError = e is StateError ? e.message : e.toString();
    } finally {
      _loadingHistory = false;
      _notify();
    }
    return reached;
  }







  Session? _session;
  String? _sessionId;
  String? _sessionFile;
  int _persistedCount = 0;

  /// Monotonic load-generation counter (issue #199 AC5/E3): bumped by
  /// every path that swaps or clears the session ([loadSession], [reset],
  /// [initialize], [deleteSession]); page loads, external refreshes, and
  /// ledger folds capture it and bail when it moved — stale work must
  /// never land in the new session's state.
  int _loadGeneration = 0;

  /// Outbound-request capture records (issue #385: unseen prompt/manifest
  /// blobs, wire dumps, then the request summary) buffered by
  /// [AgentServiceEvents._persistModelRequest] until the next persist pass.
  final List<({String customType, Map<String, dynamic> data})>
  _pendingRequestRecords = [];

  /// Per-session blob persister (dedup sets); recreated when the session
  /// changes. Redaction uses the service's active pipeline — each wire
  /// dump is redacted under the config active at capture time (E1).
  TrajectoryBlobPersister? _trajectoryBlobPersister;
  Session? _trajectoryBlobPersisterSession;


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

  /// The inbox watcher: incoming inter-agent mail while IDLE wakes the
  /// agent into a turn (mid-run mail is already delivered by the steering
  /// poll). This is what makes two Fa instances chat live.
  Timer? _inboxWatchTimer;
  var _inboxWakeRunning = false;
  var _disposed = false;

  /// Background `task` job settlements (issue #958): each one re-enters the
  /// conversation as an async-result notice (see `_onTaskJobCompleted`).
  StreamSubscription<TaskJob>? _taskCompletionsSub;

  /// JS app error-channel deliveries (gh-1164 Part B): gated render/
  /// runtime/load notices re-enter the conversation (see `_onJsAppError`).
  StreamSubscription<JsAppErrorNotice>? _jsAppErrorSub;

  /// Opt-in for the real app bootstrap (main.dart): the periodic watcher
  /// never starts in tests (a pending periodic Timer fails flutter_test's
  /// invariants), so it is off by default.
  static bool enableInboxWatcher = false;

  /// The idle inbox-wake lane policy (gh-1180): user-kind mail always
  /// wakes; delivered scheduled self-mail (`schedule_message` reminders)
  /// is exempt from the chatter cap — a deliberate agent-chosen cadence
  /// wakes forever, cadence-floored against a disguised busy-spin; and
  /// foreign agent-to-agent chatter stays capped at
  /// [InboxWakePolicy.defaultMaxInboxWakeStreak] consecutive wakes
  /// without user input.
  final InboxWakePolicy _inboxWakePolicy = InboxWakePolicy();

  /// Test seam: observe/reset the inbox-wake streak without driving ten
  /// real runs — the same seam name the CLI keeps; the streak lives in
  /// [_inboxWakePolicy] (one source of truth).
  @visibleForTesting
  int get inboxWakeStreakForTest => _inboxWakePolicy.streak;
  @visibleForTesting
  set inboxWakeStreakForTest(int value) => _inboxWakePolicy.streak = value;

  /// Test seam: the persisted receipt trail (queue-side AND wake-path
  /// events, gh-1180 AC4).
  @visibleForTesting
  ScheduledReceiptLog get scheduledReceiptsForTest => _scheduledReceipts;

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

  /// Interactive dynamic messages of this session (issue #102): the host
  /// machinery behind the `dynamic_message` tool. UI reads it for the
  /// ✦ list, the inline widget tiles, and save-as-app.
  late final DynamicMessagesService dynamicMessages;



  /// Sends a plain-text user message. While the agent is already running the
  /// message is queued as a steering message and the UI shows it as pending
  /// until the next turn picks it up.
  @override
  Future<void> sendText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    // Real user input resets the inbox wake streak (the ping-pong guard);
    // the watcher itself calls sendText with the flag set.
    if (!_inboxWakeRunning) _inboxWakePolicy.resetStreak();
    // A fresh user text gets a fresh over-window auto-continuation budget.
    _overWindowAutoResumed = false;
    _clearError();
    if (_agent.state.isStreaming) {
      _agent.steer(UserMessage.text(trimmed));
      pendingSteerTexts.add(trimmed);
      notifyListeners();
      return;
    }
    final rowProblem = _liveConnectionRowProblem();
    if (rowProblem != null) {
      error = rowProblem;
      notifyListeners();
      return;
    }
    // Wall-clock catch-up (issue #259): records that came due while the
    // host slept are swept at turn start, not at the next timer tick, so
    // the fresh turn's steering poll already sees the fired reminder.
    // Lightweight test services (pre-constructed agent) have no fabric.
    if (_subagentManager != null) {
      try {
        // Awaited so the fresh turn really does see the fired reminder
        // (issue #270); the queue isolates per-record send failures.
        await _scheduledMessages.deliverDue();
      } on Object {
        // A sweep failure must never block the user's turn.
      }
    }
    _runWithTimeout(() => _agent.prompt(trimmed));
  }

  /// Directory (relative to [env]'s working directory) where chat
  /// attachments are staged before the outgoing message references them.
  static const String uploadsDir = uploadsDirName;

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
  }) => stageUpload(env, name: name, bytes: bytes);

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
    final rowProblem = _liveConnectionRowProblem();
    if (rowProblem != null) {
      error = rowProblem;
      notifyListeners();
      return;
    }
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
    final rowProblem = _liveConnectionRowProblem();
    if (rowProblem != null) {
      error = rowProblem;
      notifyListeners();
      return;
    }
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

  /// Idle watchdog: the run aborts only when NOTHING comes back for
  /// [_responseTimeout] — any event (tokens, tool calls) proves the model is
  /// alive and rearms it. Replaces the previous whole-run timeout, which
  /// killed long coding tasks ("Request was aborted" after 90 s of healthy
  /// streaming). Long tool calls suppress it via [_activeToolCalls].
  Timer? _idleWatchdog;
  int _activeToolCalls = 0;

  /// In-flight tool activity tiles (unpersisted live rows): start adds,
  /// end untracks, agent start clears. A mid-run view rebuild re-appends
  /// them so the jump-to-tail never drops a running tool from the
  /// transcript (issue #1159 review -Fl1).
  final List<({String toolName, FahChatMessage row})> _inFlightToolRows = [];

  /// Aborts the current run, if any.
  @override
  void abort() => _agent.abort();

  /// The in-flight `_persist` drain, or `null` when idle. While one pass
  /// sweeps the transcript, late triggers mark `_persistDirty` and await
  /// this drain instead of dropping their payload (issue #1102) — and a
  /// stored future from another zone can't stall a stored-null guard, so
  /// no cross-zone future capture is possible here.
  Future<void>? _persistPass;

  /// Set when a `_persist` trigger landed while a pass was in flight; the
  /// running drain re-runs the full-state sweep once more before it ends.
  bool _persistDirty = false;

  @override
  void dispose() {
    _disposeService();
    super.dispose();
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
  ///
  /// [fromProviderAddFlow] marks the switch an add-provider flow itself
  /// performs (gh-1044 I1): it bypasses the [beginProviderAddFlow] latch
  /// below. Every other call is refused while the latch is held — boot
  /// and session restores never reconfigure the active connection in the
  /// middle of a provider add (the F4 hijack: a codemie restore binding
  /// the connection while the AIIN flow runs).
  Future<void> reconfigure(
    AgentConfig config, {
    bool fromProviderAddFlow = false,
  }) async {
    if (reconfigureRefusedByAddFlow(fromProviderAddFlow)) {
      debugPrint(
        '[Fa] reconfigure refused: a provider add flow is in progress — '
        'the active connection stays untouched until it finishes',
      );
      return;
    }
    // Issue #327: refuse a connection whose model and auth resolve from
    // DIFFERENT registry rows, or a hosted/CodeMie endpoint with no
    // credential on this surface — before any state changes (fail fast,
    // no side effects; pickers surface the message verbatim).
    final problem = providerConnectionProblem(
      _providerRegistry,
      config,
      extensionHost: isExtensionHost(),
    );
    if (problem != null) {
      debugPrint('[Fa] reconfigure refused: $problem');
      throw ProviderConnectionException(problem);
    }
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
    // Post-await notify: a dispose landing inside the waitForIdle() drain
    // (the abort of the in-flight run) otherwise fires on the dead
    // notifier — the #1319 race class, same bridge as the paging methods.
    _notify();
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

  /// Lists persisted sessions, newest first (across all provider dirs
  /// under [sessionsRoot]). Cheap: reads only the JSONL headers.
  Future<List<SessionMetadata>> listSessions() async {
    try {
      final roots = _includeSharedSessionRoots
          ? allSessionRoots(sessionsRoot)
          : <String>[sessionsRoot];
      if (roots.length <= 1) {
        return await _repo.list();
      }
      return await mergeSessionsAcrossRoots(
        roots: roots,
        listRoot: (root) async => root == sessionsRoot
            ? _repo.list()
            : JsonlSessionRepo(fs: env, sessionsRoot: root).list(),
      );
    } on Object {
      return _repo.list();
    }
  }


  /// Add-provider-flow latch (gh-1044 I1/AC6): > 0 while a provider
  /// add/connect flow runs (AIIN sign-in and friends). While held,
  /// [reconfigure] refuses restore-shaped calls — the active connection
  /// is never hijacked mid-flow.
  int _providerAddFlowDepth = 0;

  /// Whether a provider add/connect flow is latched (gh-1044 I1/AC6).
  bool get providerAddFlowInProgress => _providerAddFlowDepth > 0;

  /// Whether a `reconfigure` from outside an add-provider flow is
  /// currently refused (the gh-1044 I1 latch): shared by the base
  /// [reconfigure] and subclass overrides (the extension relay) so the
  /// refusal rule exists in exactly one shape.
  bool reconfigureRefusedByAddFlow(bool fromProviderAddFlow) =>
      _providerAddFlowDepth > 0 && !fromProviderAddFlow;

  /// Marks a provider add/connect flow start (see [reconfigure]'s
  /// `fromProviderAddFlow`).
  void beginProviderAddFlow() => _providerAddFlowDepth++;

  /// Marks a provider add/connect flow end.
  void endProviderAddFlow() {
    if (_providerAddFlowDepth > 0) _providerAddFlowDepth--;
  }

  /// Bridge for the part-file extension members ([AgentServiceAssistant],
  /// [AgentServiceEvents]): `notifyListeners` is `@protected`, callable
  /// only inside the class. Fire-and-forget continuations can resume after
  /// dispose (issue #1319: openSession's background history count lands
  /// after the test/app tore the service down) and ChangeNotifier throws
  /// on a dead notifier — a notification nobody can receive is dropped.
  void _notify() {
    if (_disposed) return;
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
      final images = m.attachments.where((a) => a.bytes != null).length;
      if (images > 0) buffer.writeln('[image attached ×$images]');
      for (final attachment in m.attachments) {
        if (attachment.path != null && attachment.bytes == null) {
          buffer.writeln('[attached file: ${attachment.path}]');
        }
      }
      if (m.content.isNotEmpty) buffer.writeln(m.content);
      buffer.writeln();
    }
    return buffer.toString();
  }





  @override
  Stream<TrajectorySnapshot> get trajectory => _trajectory.stream;
}

/// Resolves the user-scope memory root for the app (gh-1276).
///
/// Precedence: the `~/.fah` home override (tests/issue #1078), then the
/// desktop home (CLI parity — the user store lands at `~/.fah/memory`
/// exactly where the CLI keeps it), then — on platforms with no OS home
/// (iOS/Android sandbox, web) — a sandbox-local root inside the env cwd so
/// user-scope notes persist next to the project store instead of being
/// silently dropped. The desktop home is a parameter (not read here) so
/// the precedence is table-testable on any host.
String appMemoryUserRoot({
  required String? configHomeDir,
  required String? desktopHome,
  required String envCwd,
}) =>
    configHomeDir ?? desktopHome ?? '$envCwd/home';

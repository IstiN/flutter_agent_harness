// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

part of 'agent_service.dart';

/// The builder seam (issue #1079, slice 5): the typed
/// [AgentCoreServices] this shell hands to `wireAgentCore`, and the
/// app-platform tool families packaged as a DECLARED [HostExtension]
/// (the slice-4 surface — canonical tail position, child-safe pool,
/// E6 states at birth, E8 hiding elsewhere).
///
/// Everything here is host glue: the platform bridges, the per-connection
/// provider choice, and the closures the builder calls back. The gating
/// decisions live in the builder, driven by `flutterAppHostProfile`.
extension AgentServiceHostBuilder on AgentService {
  /// The shell's typed services for `wireAgentCore`. Nullable facilities
  /// are absent-this-run states the builder run-narrows honestly (the
  /// hub, for one: the network controller swaps it in on opt-in).
  AgentCoreServices _appHostServices({
    required WebSearchConfig? webSearchConfig,
    required bool isOnDevice,
    required Future<Session> Function(String parentId, String childId)
    childSessionFactory,
    required ModelRolesResolver? rolesResolver,
    required OfficeApi? officeApi,
  }) => AgentCoreServices(
    baseEnv: env,
    // Session-correlation vars: the builder appends the layer (base →
    // session vars); disjoint FAH_ names can't shadow the secrets store.
    sessionEnvVars: () => _sessionEnvVars(),
    // Per-connection gating, exactly as pre-conversion: on-device
    // backends keep only the core tools (small tool-instruction block).
    webSearch: isOnDevice ? null : webSearchConfig,
    shellJobsFactory: (coreEnv) =>
        ShellJobRegistry(env: coreEnv, onSettled: _onShellJobSettled),
    // Self-configuration on every host (issue #29 S5/AC10/AC11): the same
    // core the `fa config` CLI verbs wrap, over THIS host's env — desktop
    // container, browser storage, or mobile sandbox. Hosts without
    // host-process spawning answer "not applicable" for stdio-only
    // config keys instead of writing dead config.
    configServiceFactory: (coreEnv) => ConfigService(
      env: coreEnv,
      homeDir: desktopHomeDir(),
      supportsProcesses: !_noProcessPlatforms.contains(currentFaPlatform),
    ),
    onPasswordPrompt: (prompt) async => passwordPromptHandler?.call(prompt),
    memory: _memoryController,
    onMemoryChanged: () => unawaited(_refreshMemorySection()),
    scheduledMessages: _scheduledMessages,
    scheduleSenderMailbox: () {
      // Inside a subagent run "your own mailbox" is the CHILD's — the
      // queue's selfMailbox always resolves main (gh-970).
      final id = activeSubagentId();
      final manager = _subagentManager;
      if (id == null || manager == null) return null;
      return manager.mailboxOf(id);
    },
    onAsk: (questions) => _answerAskQuestions(questions),
    onRequestSecret: (name, reason) => _handleSecretRequest(name, reason),
    // Presence markers (the builder registers no tool for these cells —
    // the extension below carries the surface): the dynamic-messages
    // machinery keeps `js_apps` honestly wired, and the shipped on-device
    // runtimes keep `on_device_providers` honest per platform.
    dynamicMessageSink: dynamicMessages,
    onDeviceProviderFactory: _onDeviceRuntimesShip ? Object() : null,
    extensions: [
      _appPlatformExtension(isOnDevice: isOnDevice, officeApi: officeApi),
    ],
    subagents: SubagentServices(
      // The app host arms no digest cadence — the kill switch (minutes 0)
      // starts no timer; the delivery path logs for when a host opts in.
      notifyHeartbeat: (digest) => AppLog.i('subagents', digest),
      heartbeatMinutes: () => 0,
      stallMinutes: () => 0,
      rolesResolver: rolesResolver,
      childSessionFactory: childSessionFactory,
    ),
    sessionRoot: sessionsRoot,
    // The mount-aware session scope: project folders group sessions (and
    // now mail) by the mounted host path, not the container cwd.
    sessionCwd: env.sessionCwd,
  );

  /// The app-platform extension: the shell's own tool families, spliced
  /// after the SDK core in the canonical tail position. `on` for this
  /// shell's profile; `off(reason)` for every built-in (E6 at birth, E8
  /// elsewhere — a host adopting another profile declares its own
  /// extension). Per-platform conditioning below is CONSTRUCTION glue
  /// (which bridges exist on this device), not capability gating.
  HostExtension _appPlatformExtension({
    required bool isOnDevice,
    required OfficeApi? officeApi,
  }) => HostExtension(
    name: 'app-platform',
    tools: [
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
      // main connection; the tools report an actionable error when the
      // slot has no usable endpoint. Skipped for the on-device backends,
      // which keep only the core coding tools (small tool-instruction
      // block).
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
      // the gate by the constructor.
      if (officeApi != null) ...outlookTools(officeApi),
    ],
    profileStates: {
      'flutter-app': const CapabilityOnState(),
      for (final profile in builtInProfiles.keys)
        profile: const CapabilityOffState(
          'the app-platform tools are a flutter-app shell surface; declare '
          'your own extension for this host',
        ),
    },
  );
}

/// Whether the on-device inference runtimes ship with THIS build
/// (webllm + transformers.js on web, gemma on iOS/Android): the honest
/// `on_device_providers` marker, per platform. Desktop builds target
/// server providers only.
bool get _onDeviceRuntimesShip {
  if (kIsWeb) return true;
  return switch (defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.android => true,
    _ => false,
  };
}

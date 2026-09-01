import 'package:firebase_analytics/firebase_analytics.dart';
import 'dart:ui' show PlatformDispatcher;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'dart:async' show unawaited;
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/app_log.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/app_launcher_screen.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:fa/ui/widgets/downloaded_models_quick_start.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/services/launcher_layout_store.dart';
import 'package:fa/services/upload.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/app_tile_host.dart';
import 'package:fa/ui/widgets/fa_mark.dart';
import 'package:fa/sandbox/env_factory.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/gemma/gemma_types.dart';
import 'package:fa/services/keychain_store.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/media_models_store.dart';
import 'package:fa/services/onboarding_store.dart';
import 'package:fa/services/ondevice_config_store.dart';
import 'package:fa/services/project_mount_env.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/sessions_root.dart';
import 'package:fa/services/skills_access_store.dart';
import 'package:fa/services/task_models_store.dart';
import 'package:fa/services/chat_text_store.dart';
import 'package:fa/services/theme_controller.dart';
import 'package:fa/ui/screens/onboarding_screen.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/transformers_js/transformers_js_types.dart';
import 'package:fa/webllm/webllm_types.dart';
import 'package:fa_ui/fa_ui.dart'
    show
        FaChatHost,
        FaUiHost,
        kWideLayoutBreakpoint,
        MediaModelsScope,
        SandboxAudioControllerFactory,
        SandboxVideoControllerFactory,
        TaskModelsScope;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:fa/sandbox/wasm_setup_stub.dart'
    if (dart.library.io) 'package:fa/sandbox/wasm_setup_io.dart';

import 'package:fa/services/openrouter_oauth_links_stub.dart'
    if (dart.library.io) 'package:fa/services/openrouter_oauth_links_io.dart'
    if (dart.library.html) 'package:fa/services/openrouter_oauth_links_web.dart';
import 'package:fa/services/platform_http_client.dart';

import 'package:fa/firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Use NSURLSession on iOS/macOS instead of dart:io HttpClient; this fixes
  // "Failed host lookup" failures on networks where the system resolver is
  // required (DNS-over-HTTPS, content filters, per-app VPNs).
  providerHttpClientFactory = createPlatformHttpClient;
  // The inter-agent inbox watcher (opt-in: never in tests).
  AgentService.enableInboxWatcher = true;
  // Tee debug output into the in-app log (settings → copy debug logs); the
  // original debugPrint still runs, so console output is unchanged.
  final originalDebugPrint = debugPrint;
  debugPrint = (message, {wrapWidth}) {
    originalDebugPrint(message, wrapWidth: wrapWidth);
    if (message != null) AppLog.i('debug', message);
  };
  final options = DefaultFirebaseOptions.currentPlatform;
  if (!options.apiKey.startsWith('YOUR_')) {
    await Firebase.initializeApp(options: options);
  }
  try {
    await setUpWasmRuntime();
    debugPrint('[fah] WASM runtime setup succeeded');
  } on Object catch (error) {
    // Wasm runtime setup is best-effort. If the native bindings are
    // unavailable the app should still start so the chat UI and other
    // providers remain usable.
    debugPrint('[fah] WASM runtime setup failed: $error');
  }
  try {
    await dotenv.load(fileName: '.env');
  } on Object {
    // .env is intentionally not committed. Values can be supplied via
    // --dart-define instead.
  }
  // The runtime FA_PROVIDERS override from `.env` (the --dart-define wins
  // in the core) — filtered-out providers never appear in the pickers,
  // the add-provider list, or onboarding.
  final faProviders = dotenv.isInitialized ? dotenv.env['FA_PROVIDERS'] : null;
  if (faProviders != null && faProviders.trim().isNotEmpty) {
    providerFilterEnvOverride = faProviders;
  }
  // One env for the whole app: the provider registry, the last-connection
  // store, and the agent share it (on web all ride the same IndexedDB
  // snapshot; two envs would clobber each other's persisted filesystem).
  final env = await createPlatformEnv();
  debugPrint('[fah] platform env created: ${env.runtimeType}, cwd=${env.cwd}');
  // From here the in-app log also persists to logs/app.log in the sandbox.
  AppLog.attach(env);
  // iOS/macOS persist API keys in the platform Keychain (see
  // [KeychainStore]); other platforms fall back to file/session storage.
  const keychain = KeychainStore();
  final sessionKeys = await SessionKeysStore.load(env, keychain: keychain);
  final registry = await ProviderRegistry.load(
    env,
    keychain: keychain,
    // Copilot deletes must reach the entry-scoped token's fallback home.
    sessionKeys: sessionKeys,
  );
  debugPrint('[fah] provider registry loaded');
  final lastConnection = await LastConnectionStore.load(env);
  debugPrint('[fah] last connection loaded');
  final themeController = await ThemeController.load(env);
  final onboardingStore = await OnboardingStore.load(env);
  final skillsAccessStore = SkillsAccessStore(env);
  final mediaModels = await MediaModelsStore.load(env);
  final taskModels = await TaskModelsStore.load(env);
  final onDeviceConfig = await OnDeviceConfigStore.load(env);
  // fa_ui's provider UI resolves named keys through the app's chain
  // (dart-defines → saved keys → .env), exactly like the connection form.
  FaUiHost.keyResolver = (name) => settingsKeyEnv(name, sessionKeys);
  // Analytics is strictly optional. On web with placeholder options
  // (`YOUR_*` — what CI builds) initializeApp above is skipped, and just
  // reading Firebase.apps can throw (no JS SDK loaded — seen on Safari,
  // where it killed startup before runApp); content blockers break it too.
  FirebaseAnalytics? analytics;
  try {
    if (Firebase.apps.isNotEmpty) {
      analytics = FirebaseAnalytics.instance;
    }
  } on Object catch (error) {
    debugPrint('[fah] analytics unavailable, continuing without: $error');
  }
  AppAnalytics.installFirebase(analytics);
  AppAnalytics.instance.appStart(analyticsAvailable: analytics != null);
  // The fa_ui chat widgets report through FaChatHost.track — route those
  // events into the app's analytics facade.
  FaChatHost.analytics = (event, [params = const {}]) {
    switch (event) {
      case 'approval_mode_changed':
        AppAnalytics.instance.approvalModeChanged(params['mode'] as String);
      case 'secret_request':
        AppAnalytics.instance.secretRequest(params['result'] as String);
      case 'message_sent':
        AppAnalytics.instance.messageSent(
          hasAttachments: params['has_attachments'] as bool,
          textLength: params['text_length'] as int,
        );
      case 'upload_added':
        AppAnalytics.instance.uploadAdded(params['count'] as int);
      case 'voice_input_used':
        AppAnalytics.instance.voiceInputUsed();
      case 'screen_opened':
        AppAnalytics.instance.screenOpened(params['screen_name'] as String);
      case 'files_opened':
        AppAnalytics.instance.filesOpened(params['source'] as String);
      case 'settings_opened':
        AppAnalytics.instance.settingsOpened();
    }
  };
  // Crashlytics: fatal Flutter errors + uncaught async errors flow into the
  // Firebase console (no web support — the guard skips both the placeholder
  // options used by CI builds and the web platform entirely).
  if (!kIsWeb) {
    try {
      if (Firebase.apps.isNotEmpty) {
        final crashlytics = FirebaseCrashlytics.instance;
        FlutterError.onError = crashlytics.recordFlutterFatalError;
        PlatformDispatcher.instance.onError = (error, stack) {
          crashlytics.recordError(error, stack, fatal: true);
          return true;
        };
        // Breadcrumbs: the debugPrint tee (already feeding AppLog) also
        // leaves a trail in the crash report.
        final baseDebugPrint = debugPrint;
        debugPrint = (message, {wrapWidth}) {
          baseDebugPrint(message, wrapWidth: wrapWidth);
          if (message != null) crashlytics.log(message);
        };
        debugPrint('[fah] crashlytics wired');
      }
    } on Object catch (error) {
      debugPrint('[fah] crashlytics unavailable, continuing without: $error');
    }
  }
  // intl date symbols for the app locales — DateFormat (derived session
  // titles) only ships en_US data compiled in; the rest must be loaded.
  for (final locale in AppLocalizations.supportedLocales) {
    await initializeDateFormatting(locale.languageCode);
  }
  debugPrint('[fah] starting runApp');
  runApp(
    MyApp(
      env: env,
      registry: registry,
      lastConnectionStore: lastConnection,
      themeController: themeController,
      onboardingStore: onboardingStore,
      skillsAccessStore: skillsAccessStore,
      sessionKeysStore: sessionKeys,
      mediaModelsStore: mediaModels,
      taskModelsStore: taskModels,
      onDeviceConfigStore: onDeviceConfig,
      analytics: analytics,
    ),
  );
  // Attach deep-link (mobile) and postMessage (web) listeners for the
  // OpenRouter OAuth callback. This is fire-and-forget: the coordinator
  // singleton forwards codes to any in-flight settings-sheet flow.
  unawaited(attachOpenRouterOAuthLinks());

  // On mobile web (iOS Safari / PWA) the popup cannot reliably hand the code
  // back, so OpenRouter redirects to the app URL with `?code=...&state=...`.
  // Exchange it after the first frame and persist the key.
  if (kIsWeb) {
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final key = await completeOpenRouterOAuthFromRedirect();
      if (key != null && key.isNotEmpty) {
        await sessionKeys.set('OPENROUTER_API_KEY', key);
        debugPrint('[Fa] OpenRouter key saved from redirect');
      }
    });
  }
}

class MyApp extends StatelessWidget {
  const MyApp({
    super.key,
    this.env,
    this.registry,
    this.lastConnectionStore,
    this.themeController,
    this.onboardingStore,
    this.skillsAccessStore,
    this.sessionKeysStore,
    this.mediaModelsStore,
    this.taskModelsStore,
    this.onDeviceConfigStore,
    this.chatTextStore,
    this.webLlmEngine,
    this.gemmaEngine,
    this.transformersJsEngine,
    this.analytics,
  });

  /// The shared execution env; `null` lets [AgentService.create] build the
  /// platform one (tests never reach that path).
  final ExecutionEnv? env;

  /// The persisted custom-provider registry; `null` falls back to an
  /// in-memory one (tests).
  final ProviderRegistry? registry;

  /// The persisted last-connection store; `null` skips prefill and
  /// persistence (tests).
  final LastConnectionStore? lastConnectionStore;

  /// The persisted appearance choice; `null` falls back to a shared
  /// in-memory controller defaulting to [FahThemeMode.system] (tests).
  final ThemeController? themeController;

  /// The persisted first-launch onboarding flag; `null` skips onboarding
  /// entirely (tests, and any host that never shows it).
  final OnboardingStore? onboardingStore;

  /// The persisted third-party skills consent store; `null` skips the
  /// one-time boot dialog (tests).
  final SkillsAccessStore? skillsAccessStore;

  /// The persisted saved-keys store; `null` skips the scope (the settings
  /// Keys section and form prefill hide, tests).
  final SessionKeysStore? sessionKeysStore;

  /// The persisted media-model overrides store; `null` skips the scope (the
  /// settings Media models section hides, tests).
  final MediaModelsStore? mediaModelsStore;

  /// The persisted task-model overrides store; `null` skips the scope (the
  /// settings Task models section hides, tests).
  final TaskModelsStore? taskModelsStore;

  /// The on-device engines the user configured (drives Providers rows); null
  /// skips the scope (tests).
  final OnDeviceConfigStore? onDeviceConfigStore;

  /// The persisted chat text-size choice; `null` skips the scope (the
  /// settings Chat text section hides, transcripts render at the default).
  final ChatTextStore? chatTextStore;

  /// Engine overrides for the on-device providers (tests); default to the
  /// platform singletons.
  final WebLlmEngineApi? webLlmEngine;
  final GemmaEngineApi? gemmaEngine;
  final TransformersJsEngineApi? transformersJsEngine;

  /// Firebase Analytics instance; null when Firebase is not initialized
  /// (e.g., tests or placeholder firebase_options.dart).
  final FirebaseAnalytics? analytics;

  /// Fallback for [themeController] when none is injected (tests): a single
  /// shared in-memory controller so every [MyApp] build sees the same one.
  static final ThemeController _fallbackThemeController =
      ThemeController.inMemory();

  @override
  Widget build(BuildContext context) {
    final theme = themeController ?? _fallbackThemeController;
    final sessionKeys = sessionKeysStore;
    final mediaModels = mediaModelsStore;
    final onDeviceConfig = onDeviceConfigStore;
    Widget child = ListenableBuilder(
      listenable: theme,
      builder: (context, _) {
        return MaterialApp(
          title: 'Fa',
          theme: buildFahThemeLight(),
          darkTheme: buildFahTheme(),
          themeMode: theme.themeMode,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          navigatorObservers: analytics != null
              ? [FirebaseAnalyticsObserver(analytics: analytics!)]
              : const <NavigatorObserver>[],
          // macOS desktop: the unified titlebar's traffic lights float over
          // Flutter content (fullSizeContentView). The content fills the
          // ENTIRE window — each screen handles its own traffic-light
          // clearance. A transparent drag strip overlays the top so the
          // window can still be moved.
          builder: (context, navigatorChild) {
            if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) {
              return navigatorChild ?? const SizedBox.shrink();
            }
            return Stack(
              children: [
                Positioned.fill(
                  child: navigatorChild ?? const SizedBox.shrink(),
                ),
                // Transparent drag strip for window movement.
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: 28,
                  child: _MacOSDragStrip(),
                ),
              ],
            );
          },
          home: BootstrapScreen(
            env: env,
            registry: registry,
            lastConnectionStore: lastConnectionStore,
            onboardingStore: onboardingStore,
            skillsAccessStore: skillsAccessStore,
            sessionKeysStore: sessionKeys,
            taskModelsStore: taskModelsStore,
            webLlmEngine: webLlmEngine,
            gemmaEngine: gemmaEngine,
            transformersJsEngine: transformersJsEngine,
          ),
        );
      },
    );
    child = FahThemeScope(controller: theme, child: child);
    if (sessionKeys != null) {
      child = SessionKeysScope(store: sessionKeys, child: child);
    }
    if (onDeviceConfig != null) {
      child = OnDeviceConfigScope(store: onDeviceConfig, child: child);
    }
    if (mediaModels != null) {
      child = MediaModelsScope(store: mediaModels, child: child);
    }
    final taskModels = taskModelsStore;
    if (taskModels != null) {
      child = TaskModelsScope(store: taskModels, child: child);
    }
    final chatText = chatTextStore;
    if (chatText != null) {
      child = ChatTextScope(store: chatText, child: child);
    }
    return child;
  }
}

/// Rebuilds the last connection's [AgentConfig] for the boot auto-connect,
/// or null when the setup screen should show instead: nothing configured,
/// an on-device connection (those re-offer the quick start instead of
/// silently loading multi-GB weights at boot), or a hosted connection
/// whose key is gone. Every hosted catalog kind restores
/// (`openai-completions`, `google`, `anthropic`, `dial`, `minimax`,
/// `chatgpt-codex`, `copilot`). Key order: the matching custom provider's
/// (Keychain-backed) registry key, then — for Copilot, whose tokens live
/// entry-scoped — `FA_KEY_COPILOT_<NAME>` from the saved-keys chain, then
/// the catalog kind's standard env names (`GOOGLE_API_KEY`, …), then the
/// legacy hosted key; keyless custom endpoints (llama.cpp/Ollama) connect
/// without a key.
AgentConfig? restorableBootConfig({
  required LastConnection? connection,
  required ProviderRegistry? registry,
  required SessionKeysStore? sessionKeysStore,
}) {
  if (connection == null) return null;
  final kind = connection.providerKind;
  // On-device backends re-offer the quick start instead of silently
  // loading multi-GB weights at boot. Every hosted catalog kind
  // (openai-completions, google, anthropic, dial, minimax,
  // chatgpt-codex) restores — a 'google' last connection used to fall
  // into the placeholder home here.
  if (kind == webLlmProviderKind ||
      kind == gemmaProviderKind ||
      kind == transformersJsProviderKind) {
    return null;
  }
  final baseUrl = connection.baseUrl ?? '';
  if (baseUrl.isEmpty) return null;
  CustomProvider? custom;
  if (registry != null) {
    for (final provider in registry.providers) {
      if (provider.baseUrl == baseUrl) {
        custom = provider;
        break;
      }
    }
  }
  var key = custom != null ? registry!.keyFor(custom.id) ?? '' : '';
  if (key.isEmpty && custom != null && kind == 'copilot') {
    // Copilot GitHub tokens are stored entry-scoped (FA_KEY_COPILOT_<NAME>,
    // the CLI contract); the entry name is the registry provider's name.
    key = settingsKeyEnv(
      CustomProviderRegistry.copilotEntryKeyName(custom.name),
      sessionKeysStore,
    );
  }
  if (key.isEmpty) {
    // Hosted catalog kinds resolve their standard key names
    // (GOOGLE_API_KEY, ANTHROPIC_API_KEY, …) from the saved-keys chain.
    for (final spec in providerCatalog.values) {
      if (spec.kind != kind) continue;
      for (final name in spec.apiKeyEnvNames) {
        key = settingsKeyEnv(name, sessionKeysStore);
        if (key.isNotEmpty) break;
      }
      break;
    }
  }
  if (key.isEmpty) {
    key = settingsKeyEnv('OPENROUTER_API_KEY', sessionKeysStore);
  }
  if (key.isEmpty && custom == null) return null;
  return AgentConfig(
    providerKind: kind,
    modelId: connection.modelId,
    baseUrl: baseUrl,
    apiKey: key,
    supportsImages: modelIdSuggestsVision(connection.modelId),
  );
}

/// A transparent 28px strip at the top of the macOS window that allows
/// dragging the window. The traffic lights float over this area (they're
/// drawn by the OS); the strip's only job is to register drag gestures.
class _MacOSDragStrip extends StatelessWidget {
  const _MacOSDragStrip();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) {
        // Trigger native window drag.
      },
      child: const SizedBox.expand(),
    );
  }
}

/// The app home after a successful connect: on wide screens (≥900px) the
/// [WideLayoutShell] (sidebar + content area), otherwise the [AppLauncherScreen]
/// with the floating session chat sheet.
Widget faHomeScreen({
  required BuildContext context,
  required FlutterSessionManager manager,
  ProviderRegistry? registry,
  LastConnectionStore? lastConnectionStore,
  SessionNamesStore? sessionNamesStore,
  UploadPicker? uploadPicker,
  AsrApi? asr,
  AsrTranscriber? asrTranscriber,
  SandboxAudioControllerFactory? audioControllerFactory,
  SandboxVideoControllerFactory? videoControllerFactory,
  TileEngineFactory? tileEngineFactory,
  LauncherLayoutStore? layoutStore,
  AppsStore? appsStore,
}) {
  final isWide = MediaQuery.sizeOf(context).width >= kWideLayoutBreakpoint;
  if (isWide) {
    return WideLayoutShell(
      manager: manager,
      registry: registry,
      lastConnectionStore: lastConnectionStore,
      sessionNamesStore: sessionNamesStore,
      uploadPicker: uploadPicker,
      asr: asr,
      asrTranscriber: asrTranscriber,
      audioControllerFactory: audioControllerFactory,
      videoControllerFactory: videoControllerFactory,
      tileEngineFactory: tileEngineFactory,
      layoutStore: layoutStore,
      appsStore: appsStore,
    );
  }
  return AppLauncherScreen(
    manager: manager,
    registry: registry,
    lastConnectionStore: lastConnectionStore,
    sessionNamesStore: sessionNamesStore,
    uploadPicker: uploadPicker,
    asr: asr,
    asrTranscriber: asrTranscriber,
    audioControllerFactory: audioControllerFactory,
    videoControllerFactory: videoControllerFactory,
    tileEngineFactory: tileEngineFactory,
    layoutStore: layoutStore,
    appsStore: appsStore,
  );
}

/// Boot decision screen: the setup form shows only when nothing was ever
/// configured (first run) or the last connection cannot be restored (its
/// key is gone, or it was an on-device model — those re-offer the quick
/// start instead of silently loading multi-GB weights at boot). A
/// restorable last connection goes straight to chat.
///
/// First launch (no restorable connection AND the onboarding flag unseen,
/// see [OnboardingStore]) shows the [OnboardingScreen] first; completing or
/// skipping it sets the flag and boot continues — a model preset applied
/// during onboarding persists a restorable connection, so boot re-evaluates
/// and can go straight to chat.
class BootstrapScreen extends StatefulWidget {
  const BootstrapScreen({
    super.key,
    this.env,
    this.registry,
    this.lastConnectionStore,
    this.onboardingStore,
    this.skillsAccessStore,
    this.sessionKeysStore,
    this.taskModelsStore,
    this.webLlmEngine,
    this.gemmaEngine,
    this.transformersJsEngine,
  });

  /// The shared execution env handed to [AgentService.create].
  final ExecutionEnv? env;

  /// The persisted custom-provider registry (its keys ride the Keychain on
  /// iOS/macOS — that is what makes a hosted auto-connect possible).
  final ProviderRegistry? registry;

  /// The persisted last-connection record being restored.
  final LastConnectionStore? lastConnectionStore;

  /// The persisted first-launch onboarding flag; `null` never shows
  /// onboarding (tests).
  final OnboardingStore? onboardingStore;

  /// The persisted third-party skills consent store; when onboarding was
  /// already seen and no consent is recorded, the boot flow asks once
  /// (non-blocking, after the first frame). `null` never asks (tests).
  final SkillsAccessStore? skillsAccessStore;

  /// The persisted saved-keys store (hosted key resolution).
  final SessionKeysStore? sessionKeysStore;

  /// The persisted task-model overrides store, passed to [AgentService.create].
  final TaskModelsStore? taskModelsStore;

  /// Engine overrides for the on-device providers (tests).
  final WebLlmEngineApi? webLlmEngine;
  final GemmaEngineApi? gemmaEngine;
  final TransformersJsEngineApi? transformersJsEngine;

  @override
  State<BootstrapScreen> createState() => _BootstrapScreenState();
}

class _BootstrapScreenState extends State<BootstrapScreen> {
  /// The connection being restored; null renders the setup form directly
  /// (no navigation, so the first frame already shows it).
  AgentConfig? _config;

  /// Set once the onboarding flow finishes (completed or skipped) so the
  /// boot continues to the setup form or the auto-connect.
  var _onboardingDone = false;

  /// The boot-time read of the third-party skills consent (started in
  /// [initState], so the dialog never waits on disk). Discovery is ON by
  /// default — the dialog fires only for an explicit `ask` choice (Settings),
  /// never on a fresh install.
  Future<SkillsAccess?>? _skillsAccessFuture;

  /// First-launch onboarding shows only when nothing can be restored
  /// (upgraders with a saved connection never see it) and the persisted
  /// flag is still unseen.
  bool get _showOnboarding {
    final store = widget.onboardingStore;
    return !_onboardingDone && _config == null && store != null && !store.seen;
  }

  @override
  void initState() {
    super.initState();
    _config = restorableBootConfig(
      connection: widget.lastConnectionStore?.connection,
      registry: widget.registry,
      sessionKeysStore: widget.sessionKeysStore,
    );
    // The skills-consent dialog fires only for an EXPLICIT `ask` choice
    // (Settings) — discovery is on by default, so a fresh install never
    // sees it. Mobile never asks: the third-party roots don't exist there.
    final onboarding = widget.onboardingStore;
    final skillsStore = widget.skillsAccessStore;
    if (skillsConsentSurfacesVisible &&
        onboarding != null &&
        onboarding.seen &&
        skillsStore != null) {
      _skillsAccessFuture = skillsStore.load();
      if (_config == null) {
        // No navigation ahead (the empty-manager home renders in place) —
        // ask right after the first frame, never blocking the build.
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => unawaited(_maybeAskSkillsAccess(context)),
        );
      }
    }
    if (_config != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_boot()));
    }
  }

  /// Shows the third-party skills consent dialog when the user explicitly
  /// chose "ask" in Settings. Allow persists `granted`; Not now persists
  /// `denied` (a boot-dialog answer must stick or the dialog would fire on
  /// every launch); a dismissed dialog stays `ask` and asks again next
  /// launch. Boot is never blocked on it.
  Future<void> _maybeAskSkillsAccess(BuildContext dialogContext) async {
    final future = _skillsAccessFuture;
    final store = widget.skillsAccessStore;
    if (future == null || store == null) return;
    _skillsAccessFuture = null;
    if (await future != SkillsAccess.ask) return; // only an explicit "ask"
    if (!dialogContext.mounted) return;
    AppAnalytics.instance.screenOpened('skills_access_dialog');
    final allow = await showDialog<bool>(
      context: dialogContext,
      builder: (context) => AlertDialog(
        title: Text(context.l10n.skillsAccessDialogTitle),
        content: Text(context.l10n.skillsAccessDialogBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.skillsAccessNotNow),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.l10n.skillsAccessAllow),
          ),
        ],
      ),
    );
    if (allow == null) return; // dismissed — ask again next launch
    final access = allow ? SkillsAccess.granted : SkillsAccess.denied;
    AppAnalytics.instance.skillsAccessChanged(access.name);
    await store.save(access);
  }

  Future<void> _boot() async {
    final config = _config!;
    try {
      final env = widget.env ?? await createPlatformEnv();
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: defaultSessionsRoot(env.sessionCwd),
      );
      // Resume the day's session (or an untouched empty one) instead of
      // stacking a fresh empty session on every cold launch.
      await manager.createOrResumeSession(
        config: config,
        createFactory: () => AgentService.create(
          config: config,
          env: env,
          sessionKeys: widget.sessionKeysStore,
          providerRegistry: widget.registry,
          taskModelsStore: widget.taskModelsStore,
        ),
        openFactory: () => AgentService.create(
          config: config,
          env: env,
          sessionKeys: widget.sessionKeysStore,
          providerRegistry: widget.registry,
          taskModelsStore: widget.taskModelsStore,
        ),
      );
      if (!mounted) return;
      AppAnalytics.instance.bootstrapResult('chat');
      // Use the Navigator's context, not the State's — after a hot restart
      // the State is defunct but the Navigator's context stays valid.
      final navigator = Navigator.of(context);
      final navigatorContext = navigator.context;
      await navigator.pushReplacement(
        MaterialPageRoute(
          builder: (_) => faHomeScreen(
            context: navigatorContext,
            manager: manager,
            registry: widget.registry,
            lastConnectionStore: widget.lastConnectionStore,
          ),
        ),
      );
      // The skills-consent dialog (undecided upgraders) rides above the
      // freshly pushed home — the BootstrapScreen state is defunct by now,
      // so the Navigator's context is the valid one.
      if (navigatorContext.mounted) {
        unawaited(_maybeAskSkillsAccess(navigatorContext));
      }
    } on Object catch (error, stack) {
      // A failed restore (endpoint down, key rejected) lands on the setup
      // form — prefilled by the same last-connection record. Log it: a
      // silent catch here used to leave the boot spinner up forever with
      // no clue why.
      debugPrint('[fah] boot restore failed: $error\n$stack');
      if (mounted) {
        AppAnalytics.instance.bootstrapResult('setup_restore_failed');
        setState(() => _config = null);
      }
    }
  }

  /// Lands the user on the home screen with an empty manager after
  /// onboarding (no provider applied during the walkthrough) — the
  /// launcher's empty state prompts them to open Settings → Providers
  /// rather than dumping them back into the legacy "Connect to Fa"
  /// form they just left.
  Widget _buildHomeWithEmptyManager() {
    AppAnalytics.instance.setupShown('onboarding_done_no_provider');
    return _EmptyManagerHome(
      env: widget.env,
      registry: widget.registry,
      lastConnectionStore: widget.lastConnectionStore,
    );
  }

  Widget _buildSetupScreen() {
    AppAnalytics.instance.setupShown(
      widget.lastConnectionStore?.connection != null
          ? 'restore_unavailable'
          : 'first_run',
    );
    return SetupScreen(
      env: widget.env,
      registry: widget.registry,
      lastConnectionStore: widget.lastConnectionStore,
      sessionKeysStore: widget.sessionKeysStore,
      webLlmEngine: widget.webLlmEngine,
      gemmaEngine: widget.gemmaEngine,
      transformersJsEngine: widget.transformersJsEngine,
    );
  }

  Widget _buildOnboardingScreen() {
    return OnboardingScreen(
      onboardingStore: widget.onboardingStore,
      registry: widget.registry,
      lastConnectionStore: widget.lastConnectionStore,
      onFinished: ({required bool skipped}) => _onboardingFinished(),
    );
  }

  /// The onboarding flow ended (completed or skipped — the screen already
  /// persisted the seen flag). A model preset applied during onboarding
  /// saves a restorable last connection, so boot re-evaluates: restorable →
  /// auto-connect, otherwise the setup form.
  void _onboardingFinished() {
    final config = restorableBootConfig(
      connection: widget.lastConnectionStore?.connection,
      registry: widget.registry,
      sessionKeysStore: widget.sessionKeysStore,
    );
    setState(() {
      _onboardingDone = true;
      _config = config;
    });
    if (config != null) unawaited(_boot());
  }

  @override
  Widget build(BuildContext context) {
    final config = _config;
    if (config == null) {
      if (_showOnboarding) return _buildOnboardingScreen();
      // After onboarding (seen flag set) the user has already walked
      // through the provider-first flow. Land them on the home screen
      // with an empty manager — the launcher's empty-state prompts
      // them to open Settings → Providers — rather than dumping them
      // back into the legacy "Connect to Fa" form. The pre-onboarding
      // (onboardingStore == null) path keeps the legacy SetupScreen
      // for upgraders / first-launch-without-onboarding.
      if (widget.onboardingStore != null) {
        return _buildHomeWithEmptyManager();
      }
      return _buildSetupScreen();
    }
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FaBrandTile(size: 48),
            SizedBox(height: 24),
            CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}

/// Home with an empty session manager (post-onboarding, no provider yet).
///
/// The env + manager + placeholder session are created ONCE in [initState]:
/// the previous FutureBuilder-in-build version minted a new manager and a
/// new session future on every rebuild (duplicate sessions stacked up) and
/// showed an infinite spinner when session creation failed (a FutureBuilder
/// error has no data). Errors now surface with a retry.
class _EmptyManagerHome extends StatefulWidget {
  const _EmptyManagerHome({this.env, this.registry, this.lastConnectionStore});

  final ExecutionEnv? env;
  final ProviderRegistry? registry;
  final LastConnectionStore? lastConnectionStore;

  /// A placeholder session so the home never lands empty: user always has
  /// an active session, apps render + open, the sessions list shows
  /// something to pick from. The placeholder uses a no-op stream (the LLM
  /// call errors gracefully) — when the user actually connects a provider
  /// via Settings, reconfigure takes over.
  static final placeholderConfig = AgentConfig(
    providerKind: 'openai-completions',
    modelId: 'placeholder',
    baseUrl: '',
    apiKey: '',
  );

  @override
  State<_EmptyManagerHome> createState() => _EmptyManagerHomeState();
}

class _EmptyManagerHomeState extends State<_EmptyManagerHome> {
  FlutterSessionManager? _manager;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final env = widget.env ?? await createPlatformEnv();
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: defaultSessionsRoot(env.sessionCwd),
      );
      await manager.createSession(
        config: _EmptyManagerHome.placeholderConfig,
        serviceFactory: () => AgentService.create(
          config: _EmptyManagerHome.placeholderConfig,
          env: env,
          providerRegistry: widget.registry,
        ),
      );
      if (!mounted) return;
      setState(() {
        _manager = manager;
        _error = null;
      });
    } on Object catch (error, stack) {
      debugPrint('[fah] empty-manager home failed: $error\n$stack');
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final manager = _manager;
    if (manager != null) {
      return faHomeScreen(
        context: context,
        manager: manager,
        registry: widget.registry,
        lastConnectionStore: widget.lastConnectionStore,
      );
    }
    final error = _error;
    if (error != null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const FaBrandTile(size: 48),
              const SizedBox(height: 24),
              Text(context.l10n.bootstrapSessionStartError(error)),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  setState(() => _error = null);
                  unawaited(_start());
                },
                child: Text(context.l10n.bootstrapRetry),
              ),
            ],
          ),
        ),
      );
    }
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FaBrandTile(size: 48),
            SizedBox(height: 24),
            CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}

/// First-run screen: bring-your-own-key connection form (see
/// [AgentSettingsForm]) with a one-tap "Downloaded models" quick start above
/// it (see [DownloadedModelsQuickStart]). Keys typed here stay in memory for
/// the session (explicit saving happens in the settings Keys section, see
/// [SessionKeysStore]); saved custom providers persist (see
/// [ProviderRegistry]) and are offered in the picker, and the last
/// successful connection persists (see [LastConnectionStore]) and
/// pre-selects the form.
class SetupScreen extends StatelessWidget {
  const SetupScreen({
    super.key,
    this.env,
    this.registry,
    this.lastConnectionStore,
    this.sessionKeysStore,
    this.webLlmEngine,
    this.gemmaEngine,
    this.transformersJsEngine,
    this.isWeb,
  });

  /// The shared execution env handed to [AgentService.create].
  final ExecutionEnv? env;

  /// The persisted custom-provider registry shown in the settings form.
  final ProviderRegistry? registry;

  /// The persisted last-connection store: pre-selects the form and is
  /// updated on every successful connect (quick start included).
  final LastConnectionStore? lastConnectionStore;

  /// The persisted saved-keys store: prefills key fields not covered by
  /// `--dart-define` or `.env` (see [SessionKeysStore]).
  final SessionKeysStore? sessionKeysStore;

  /// Engine overrides for the on-device providers (tests); default to the
  /// platform singletons.
  final WebLlmEngineApi? webLlmEngine;
  final GemmaEngineApi? gemmaEngine;
  final TransformersJsEngineApi? transformersJsEngine;

  /// Overrides `kIsWeb` for tests that need to exercise the web provider
  /// picker on a host test platform.
  final bool? isWeb;

  Future<void> _connect(BuildContext context, AgentConfig config) async {
    // An on-device connect marks the engine configured — its provider row
    // appears in the settings list from now on.
    const onDeviceKinds = {
      webLlmProviderKind,
      gemmaProviderKind,
      transformersJsProviderKind,
    };
    if (onDeviceKinds.contains(config.providerKind)) {
      await OnDeviceConfigScope.maybeOf(
        context,
      )?.markConfigured(config.providerKind);
    }
    final resolvedEnv = env ?? await createPlatformEnv();
    final manager = FlutterSessionManager(
      env: resolvedEnv,
      sessionsRoot: defaultSessionsRoot(resolvedEnv.sessionCwd),
    );
    await manager.createOrResumeSession(
      config: config,
      createFactory: () => AgentService.create(
        config: config,
        env: env,
        sessionKeys: sessionKeysStore,
        providerRegistry: registry,
      ),
      openFactory: () => AgentService.create(
        config: config,
        env: env,
        sessionKeys: sessionKeysStore,
        providerRegistry: registry,
      ),
    );
    // Connected — remember where we landed for the next boot (non-secret;
    // the key never reaches the store). Saved before navigation: the push
    // below completes only when the chat screen pops, which may be never.
    await lastConnectionStore?.saveFromConfig(config);
    if (!context.mounted) return;
    final navigator = Navigator.of(context);
    await navigator.pushReplacement(
      MaterialPageRoute(
        builder: (_) => faHomeScreen(
          context: navigator.context,
          manager: manager,
          registry: registry,
          lastConnectionStore: lastConnectionStore,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.setupAppBarTitle)),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DownloadedModelsQuickStart(
                  onConnect: (config) => _connect(context, config),
                  webLlmEngine: webLlmEngine,
                  gemmaEngine: gemmaEngine,
                  transformersJsEngine: transformersJsEngine,
                ),
                AgentSettingsForm(
                  registry: registry,
                  initialConnection: lastConnectionStore?.connection,
                  keysStore: sessionKeysStore,
                  webLlmEngine: webLlmEngine,
                  gemmaEngine: gemmaEngine,
                  transformersJsEngine: transformersJsEngine,
                  isWeb: isWeb,
                  onConnect: (config) => _connect(context, config),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

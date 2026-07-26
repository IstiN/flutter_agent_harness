import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'dart:async' show unawaited;
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/vision_models.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa/ui/widgets/downloaded_models_quick_start.dart';
import 'package:fa/ui/widgets/fa_mark.dart';
import 'package:fa/sandbox/env_factory.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/gemma/gemma_types.dart';
import 'package:fa/services/keychain_store.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/media_models_store.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/theme_controller.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/transformers_js/transformers_js_types.dart';
import 'package:fa/webllm/webllm_types.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'package:fa/sandbox/wasm_setup_stub.dart'
    if (dart.library.io) 'package:fa/sandbox/wasm_setup_io.dart';

import 'package:fa/firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
  // One env for the whole app: the provider registry, the last-connection
  // store, and the agent share it (on web all ride the same IndexedDB
  // snapshot; two envs would clobber each other's persisted filesystem).
  final env = await createPlatformEnv();
  debugPrint('[fah] platform env created: ${env.runtimeType}, cwd=${env.cwd}');
  // iOS/macOS persist API keys in the platform Keychain (see
  // [KeychainStore]); other platforms fall back to file/session storage.
  const keychain = KeychainStore();
  final registry = await ProviderRegistry.load(env, keychain: keychain);
  debugPrint('[fah] provider registry loaded');
  final lastConnection = await LastConnectionStore.load(env);
  debugPrint('[fah] last connection loaded');
  final themeController = await ThemeController.load(env);
  final sessionKeys = await SessionKeysStore.load(env, keychain: keychain);
  final mediaModels = await MediaModelsStore.load(env);
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
  debugPrint('[fah] starting runApp');
  runApp(
    MyApp(
      env: env,
      registry: registry,
      lastConnectionStore: lastConnection,
      themeController: themeController,
      sessionKeysStore: sessionKeys,
      mediaModelsStore: mediaModels,
      analytics: analytics,
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({
    super.key,
    this.env,
    this.registry,
    this.lastConnectionStore,
    this.themeController,
    this.sessionKeysStore,
    this.mediaModelsStore,
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

  /// The persisted saved-keys store; `null` skips the scope (the settings
  /// Keys section and form prefill hide, tests).
  final SessionKeysStore? sessionKeysStore;

  /// The persisted media-model overrides store; `null` skips the scope (the
  /// settings Media models section hides, tests).
  final MediaModelsStore? mediaModelsStore;

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
          // Flutter content (fullSizeContentView) — reserve a drag strip at
          // the top so they never overlap the app's own header row.
          builder: (context, navigatorChild) {
            if (kIsWeb || defaultTargetPlatform != TargetPlatform.macOS) {
              return navigatorChild ?? const SizedBox.shrink();
            }
            return Column(
              children: [
                Container(height: 28, color: FahPalette.bg),
                Expanded(child: navigatorChild ?? const SizedBox.shrink()),
              ],
            );
          },
          home: BootstrapScreen(
            env: env,
            registry: registry,
            lastConnectionStore: lastConnectionStore,
            sessionKeysStore: sessionKeys,
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
    if (mediaModels != null) {
      child = MediaModelsScope(store: mediaModels, child: child);
    }
    return child;
  }
}

/// Rebuilds the last connection's [AgentConfig] for the boot auto-connect,
/// or null when the setup screen should show instead: nothing configured,
/// an on-device connection (those re-offer the quick start instead of
/// silently loading multi-GB weights at boot), or a hosted connection
/// whose key is gone. Key order: the matching custom provider's
/// (Keychain-backed) registry key, then the saved hosted key; keyless
/// custom endpoints (llama.cpp/Ollama) connect without a key.
AgentConfig? restorableBootConfig({
  required LastConnection? connection,
  required ProviderRegistry? registry,
  required SessionKeysStore? sessionKeysStore,
}) {
  if (connection == null) return null;
  if (connection.providerKind != 'openai-completions') return null;
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
  if (key.isEmpty) {
    key = settingsKeyEnv('OPENROUTER_API_KEY', sessionKeysStore);
  }
  if (key.isEmpty && custom == null) return null;
  return AgentConfig(
    providerKind: connection.providerKind,
    modelId: connection.modelId,
    baseUrl: baseUrl,
    apiKey: key,
    supportsImages: modelIdSuggestsVision(connection.modelId),
  );
}

/// Boot decision screen: the setup form shows only when nothing was ever
/// configured (first run) or the last connection cannot be restored (its
/// key is gone, or it was an on-device model — those re-offer the quick
/// start instead of silently loading multi-GB weights at boot). A
/// restorable last connection goes straight to chat.
class BootstrapScreen extends StatefulWidget {
  const BootstrapScreen({
    super.key,
    this.env,
    this.registry,
    this.lastConnectionStore,
    this.sessionKeysStore,
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

  /// The persisted saved-keys store (hosted key resolution).
  final SessionKeysStore? sessionKeysStore;

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

  @override
  void initState() {
    super.initState();
    _config = restorableBootConfig(
      connection: widget.lastConnectionStore?.connection,
      registry: widget.registry,
      sessionKeysStore: widget.sessionKeysStore,
    );
    if (_config != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_boot()));
    }
  }

  Future<void> _boot() async {
    final config = _config!;
    try {
      final env = widget.env ?? await createPlatformEnv();
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '${env.cwd}/sessions',
      );
      await manager.createSession(
        config: config,
        serviceFactory: () => AgentService.create(
          config: config,
          env: env,
          sessionKeys: widget.sessionKeysStore,
          providerRegistry: widget.registry,
        ),
      );
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            manager: manager,
            registry: widget.registry,
            lastConnectionStore: widget.lastConnectionStore,
          ),
        ),
      );
    } on Object {
      // A failed restore (endpoint down, key rejected) lands on the setup
      // form — prefilled by the same last-connection record.
      if (mounted) setState(() => _config = null);
    }
  }

  Widget _buildSetupScreen() => SetupScreen(
    env: widget.env,
    registry: widget.registry,
    lastConnectionStore: widget.lastConnectionStore,
    sessionKeysStore: widget.sessionKeysStore,
    webLlmEngine: widget.webLlmEngine,
    gemmaEngine: widget.gemmaEngine,
    transformersJsEngine: widget.transformersJsEngine,
  );

  @override
  Widget build(BuildContext context) {
    final config = _config;
    if (config == null) return _buildSetupScreen();
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FaMark(size: 48),
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

  Future<void> _connect(BuildContext context, AgentConfig config) async {
    final manager = FlutterSessionManager(
      env: env ?? await createPlatformEnv(),
      sessionsRoot: '${(env ?? await createPlatformEnv()).cwd}/sessions',
    );
    await manager.createSession(
      config: config,
      serviceFactory: () => AgentService.create(
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
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
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

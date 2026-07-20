import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_example/agent_service.dart';
import 'package:flutter_agent_example/app_theme.dart';
import 'package:flutter_agent_example/chat_screen.dart';
import 'package:flutter_agent_example/downloaded_models_quick_start.dart';
import 'package:flutter_agent_example/env_factory.dart';
import 'package:flutter_agent_example/gemma/gemma_types.dart';
import 'package:flutter_agent_example/last_connection.dart';
import 'package:flutter_agent_example/provider_registry.dart';
import 'package:flutter_agent_example/settings.dart';
import 'package:flutter_agent_example/transformers_js/transformers_js_types.dart';
import 'package:flutter_agent_example/webllm/webllm_types.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'wasm_setup_stub.dart' if (dart.library.io) 'wasm_setup_io.dart';

import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final options = DefaultFirebaseOptions.currentPlatform;
  if (!options.apiKey.startsWith('YOUR_')) {
    await Firebase.initializeApp(options: options);
  }
  try {
    await setUpWasmRuntime();
  } on Object {
    // Wasm runtime setup is best-effort. If the native bindings are
    // unavailable the app should still start so the chat UI and other
    // providers remain usable.
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
  final registry = await ProviderRegistry.load(env);
  final lastConnection = await LastConnectionStore.load(env);
  final analytics = Firebase.apps.isNotEmpty
      ? FirebaseAnalytics.instance
      : null;
  runApp(
    MyApp(
      env: env,
      registry: registry,
      lastConnectionStore: lastConnection,
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

  /// Engine overrides for the on-device providers (tests); default to the
  /// platform singletons.
  final WebLlmEngineApi? webLlmEngine;
  final GemmaEngineApi? gemmaEngine;
  final TransformersJsEngineApi? transformersJsEngine;

  /// Firebase Analytics instance; null when Firebase is not initialized
  /// (e.g., tests or placeholder firebase_options.dart).
  final FirebaseAnalytics? analytics;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fa',
      theme: buildFahTheme(),
      navigatorObservers: analytics != null
          ? [FirebaseAnalyticsObserver(analytics: analytics!)]
          : const <NavigatorObserver>[],
      home: SetupScreen(
        env: env,
        registry: registry,
        lastConnectionStore: lastConnectionStore,
        webLlmEngine: webLlmEngine,
        gemmaEngine: gemmaEngine,
        transformersJsEngine: transformersJsEngine,
      ),
    );
  }
}

/// First-run screen: bring-your-own-key connection form (see
/// [AgentSettingsForm]) with a one-tap "Downloaded models" quick start above
/// it (see [DownloadedModelsQuickStart]). Keys are kept in memory only; saved
/// custom providers persist (see [ProviderRegistry]) and are offered in the
/// picker, and the last successful connection persists (see
/// [LastConnectionStore]) and pre-selects the form.
class SetupScreen extends StatelessWidget {
  const SetupScreen({
    super.key,
    this.env,
    this.registry,
    this.lastConnectionStore,
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

  /// Engine overrides for the on-device providers (tests); default to the
  /// platform singletons.
  final WebLlmEngineApi? webLlmEngine;
  final GemmaEngineApi? gemmaEngine;
  final TransformersJsEngineApi? transformersJsEngine;

  Future<void> _connect(BuildContext context, AgentConfig config) async {
    final service = await AgentService.create(config: config, env: env);
    await service.initialize();
    // Connected — remember where we landed for the next boot (non-secret;
    // the key never reaches the store). Saved before navigation: the push
    // below completes only when the chat screen pops, which may be never.
    await lastConnectionStore?.saveFromConfig(config);
    if (!context.mounted) return;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          service: service,
          registry: registry,
          lastConnectionStore: lastConnectionStore,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to fah')),
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

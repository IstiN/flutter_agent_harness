// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The app boot module (issue #483): `main()` delegates here.
///
/// The boot pipeline is a sequence of named stages — window → services →
/// storage → telemetry → routes — each a small, separately testable unit
/// (≤ CC 10). The storage stage accepts an injected [ExecutionEnv] so unit
/// tests exercise it without plugin channels; the routes stage is injected
/// by `main.dart` (it mounts the app UI, which the boot module must not
/// depend on). Stage order mirrors the historical inline `main()` exactly —
/// boot is semantics-preserving.
library;

import 'dart:async' show unawaited;
import 'dart:ui' show PlatformDispatcher;

import 'package:fa/firebase_options.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/sandbox/env_factory.dart';
import 'package:fa/sandbox/wasm_setup_stub.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/services/app_log.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/relay_agent_service.dart';
import 'package:fa/services/sessions_root.dart';
import 'package:fa/services/image_preview_store.dart';
import 'package:fa/services/keychain_store.dart';
import 'package:fa/services/project_mount_env.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/media_models_store.dart';
import 'package:fa/services/onboarding_store.dart';
import 'package:fa/services/ondevice_config_store.dart';
import 'package:fa/services/platform_http_client.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/settings_env.dart';
import 'package:fa/services/skills_access_store.dart';
import 'package:fa/services/task_models_store.dart';
import 'package:fa/services/theme_controller.dart';
import 'package:fa/services/theme_pack_store.dart';
import 'package:fa/services/web/sandbox_url_strategy.dart';
import 'package:fa/services/office/office_boot.dart';
import 'package:fa/services/office/office_fetch_bridge.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:intl/date_symbol_data_local.dart';

/// The stores and per-surface services the storage stage loads, consumed by
/// the routes stage (`MyApp`). Every field is final — loaded once at boot.
final class BootStores {
  const BootStores({
    required this.env,
    required this.sessionKeys,
    required this.registry,
    required this.lastConnection,
    required this.themeController,
    required this.themePacks,
    required this.onboarding,
    required this.skillsAccess,
    required this.mediaModels,
    required this.taskModels,
    required this.onDeviceConfig,
    required this.imagePreviews,
  });

  /// The shared execution env (also on [BootStores] so the routes stage
  /// hands the same instance to the app).
  final ExecutionEnv env;

  /// The saved-keys store (`SessionKeysScope` + connection form prefill).
  final SessionKeysStore sessionKeys;

  /// The custom-provider registry (Providers screen, key resolution).
  final ProviderRegistry registry;

  /// The persisted last connection (boot auto-connect + form prefill).
  final LastConnectionStore lastConnection;

  /// The persisted appearance choice.
  final ThemeController themeController;

  /// The installed theme packs.
  final ThemePackStore themePacks;

  /// The first-launch onboarding flag.
  final OnboardingStore onboarding;

  /// The third-party skills consent store.
  final SkillsAccessStore skillsAccess;

  /// The media-model overrides.
  final MediaModelsStore mediaModels;

  /// The task-model overrides.
  final TaskModelsStore taskModels;

  /// The on-device engine configuration.
  final OnDeviceConfigStore onDeviceConfig;

  /// The image-preview preference store.
  final ImagePreviewStore imagePreviews;
}

/// The boot pipeline. `main()` constructs it with the app's routes stage
/// and calls [run] — zero logic in `main()` itself.
final class FaAppBoot {
  const FaAppBoot({required this.routes});

  /// The routes stage: mounts the app UI (`runApp`) and attaches the
  /// boot-time OAuth listeners. Injected so this module stays UI-free.
  final Future<void> Function(BootStores stores, FirebaseAnalytics? analytics)
  routes;

  /// Runs the boot stages in the historical `main()` order:
  /// window → services → storage → telemetry → routes.
  Future<void> run() async {
    bootWindow();
    await bootServices();
    // One env for the whole app: the provider registry, the last-connection
    // store, and the agent share it (on web all ride the same IndexedDB
    // snapshot; two envs would clobber each other's persisted filesystem).
    final env = await createPlatformEnv();
    debugPrint(
      '[fah] platform env created: ${env.runtimeType}, cwd=${env.cwd}',
    );
    // From here the in-app log also persists to logs/app.log in the sandbox.
    AppLog.attach(env);
    final stores = await loadBootStores(env);
    final analytics = await bootTelemetry();
    await routes(stores, analytics);
  }
}

/// The window stage: binding, embedded-pane handshake, sandbox-safe URL
/// strategy, the platform HTTP transport, and the debug-print tee. All
/// synchronous, all before any async service work.
void bootWindow() {
  WidgetsFlutterBinding.ensureInitialized();
  // Office.onReady FIRST (issue #202): the pane's handshake starts before
  // any later boot step can die on a sandboxed host.
  bootOfficeApi();
  // The OWA iframe sandbox strips history.replaceState — the web engine's
  // default deep-link URL sync crashes on it mid-boot ("q.replaceState is
  // not a function"), graying the pane before the first frame. Probe the
  // History API and fall back to a no-op strategy in stripped frames
  // (issue #202); working hosts keep the default strategy.
  installSandboxSafeUrlStrategy();
  // Use NSURLSession on iOS/macOS instead of dart:io HttpClient; this fixes
  // "Failed host lookup" failures on networks where the system resolver is
  // required (DNS-over-HTTPS, content filters, per-app VPNs).
  // Issue #470: the embedded office pane routes provider HTTP through the
  // extension's SW fetch bridge (CORS); everywhere else this is null and the
  // direct platform transport stays.
  providerHttpClientFactory =
      installOfficeHttpBridge() ?? createPlatformHttpClient;
  // The inter-agent inbox watcher (opt-in: never in tests).
  AgentService.enableInboxWatcher = true;
  _teeDebugPrintIntoAppLog();
}

/// The services stage: Firebase app, the WASM runtime, and the `.env`
/// provider filter — the plugin-touching setup that must precede storage.
Future<void> bootServices() async {
  await _initFirebaseApp();
  await _setUpWasmRuntimeBestEffort();
  providerFilterEnvOverride = await _loadProviderFilterOverride();
}

/// The storage stage: every persisted store the app boots with, loaded over
/// the (injected) platform env. Unit tests pass a fake [env] — no plugin
/// channels involved.
Future<BootStores> loadBootStores(ExecutionEnv env) async {
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
  final themePacks = await ThemePackStore.load(env);
  final skillsAccessStore = SkillsAccessStore(env);
  final mediaModels = await MediaModelsStore.load(env);
  final taskModels = await TaskModelsStore.load(env);
  final onDeviceConfig = await OnDeviceConfigStore.load(env);
  final imagePreviews = ImagePreviewStore(env);
  await imagePreviews.load();
  // fa_ui's provider UI resolves named keys through the app's chain
  // (dart-defines → saved keys → .env), exactly like the connection form.
  FaUiHost.keyResolver = (name) => settingsKeyEnv(name, sessionKeys);
  return BootStores(
    env: env,
    sessionKeys: sessionKeys,
    registry: registry,
    lastConnection: lastConnection,
    themeController: themeController,
    themePacks: themePacks,
    onboarding: onboardingStore,
    skillsAccess: skillsAccessStore,
    mediaModels: mediaModels,
    taskModels: taskModels,
    onDeviceConfig: onDeviceConfig,
    imagePreviews: imagePreviews,
  );
}

/// The telemetry stage: analytics (strictly optional), the fa_ui chat-event
/// routing, Crashlytics breadcrumbs, and intl date symbols. Returns the
/// analytics instance for the routes stage (`MyApp`'s navigator observer).
Future<FirebaseAnalytics?> bootTelemetry() async {
  final analytics = _initAnalytics();
  AppAnalytics.installFirebase(analytics);
  AppAnalytics.instance.appStart(analyticsAvailable: analytics != null);
  // The fa_ui chat widgets report through FaChatHost.track — route those
  // events into the app's analytics facade.
  FaChatHost.analytics = routeFaChatAnalytics;
  _wireCrashlyticsBreadcrumbs();
  // intl date symbols for the app locales — DateFormat (derived session
  // titles) only ships en_US data compiled in; the rest must be loaded.
  await _loadIntlDateSymbols();
  return analytics;
}

/// Tees debug output into the in-app log (settings → copy debug logs); the
/// original debugPrint still runs, so console output is unchanged.
void _teeDebugPrintIntoAppLog() {
  final originalDebugPrint = debugPrint;
  debugPrint = (message, {wrapWidth}) {
    originalDebugPrint(message, wrapWidth: wrapWidth);
    if (message != null) AppLog.i('debug', message);
  };
}

/// Initializes Firebase unless running inside the browser-extension panel
/// or with placeholder CI options. The extension panel runs the same web
/// build under chrome-extension://, whose MV3 CSP blocks the inline-script
/// bootstrap firebase_core_web uses to load the JS SDK — initializing
/// there ends in an uncaught error, and the panel does not need Firebase.
///
/// The native Firebase SDK auto-configures the [DEFAULT] app from
/// GoogleService-Info.plist when the plugins register — a second
/// initializeApp throws [core/duplicate-app] and, unhandled, kills boot
/// before the first frame (black screen on macOS/iOS). Reuse the natively
/// configured app in that case.
Future<void> _initFirebaseApp() async {
  final options = DefaultFirebaseOptions.currentPlatform;
  final inExtension = Uri.base.scheme == 'chrome-extension';
  if (inExtension || options.apiKey.startsWith('YOUR_')) return;
  try {
    await Firebase.initializeApp(options: options);
  } on FirebaseException catch (error) {
    if (error.code != 'duplicate-app') rethrow;
    debugPrint(
      '[fa] Firebase [DEFAULT] already configured natively — reusing it',
    );
  }
}

/// Wasm runtime setup is best-effort. If the native bindings are
/// unavailable the app should still start so the chat UI and other
/// providers remain usable.
Future<void> _setUpWasmRuntimeBestEffort() async {
  try {
    await setUpWasmRuntime();
    debugPrint('[fah] WASM runtime setup succeeded');
  } on Object catch (error) {
    debugPrint('[fah] WASM runtime setup failed: $error');
  }
}

/// Loads `.env` (intentionally not committed; values can be supplied via
/// --dart-define instead) and returns its runtime FA_PROVIDERS override —
/// the --dart-define wins in the core, so this is `null` unless `.env`
/// carried the variable. Filtered-out providers never appear in the
/// pickers, the add-provider list, or onboarding.
Future<String?> _loadProviderFilterOverride() async {
  try {
    await dotenv.load(fileName: '.env');
  } on Object {
    return null;
  }
  final faProviders = dotenv.isInitialized ? dotenv.env['FA_PROVIDERS'] : null;
  if (faProviders == null || faProviders.trim().isEmpty) return null;
  return faProviders;
}

/// Analytics is strictly optional. On web with placeholder options
/// (`YOUR_*` — what CI builds) initializeApp is skipped, and just reading
/// Firebase.apps can throw (no JS SDK loaded — seen on Safari, where it
/// killed startup before runApp); content blockers break it too.
FirebaseAnalytics? _initAnalytics() {
  try {
    if (Firebase.apps.isNotEmpty) return FirebaseAnalytics.instance;
  } on Object catch (error) {
    debugPrint('[fah] analytics unavailable, continuing without: $error');
  }
  return null;
}

/// The fa_ui chat-event route table (the `_faCall` handler-map pattern,
/// PR #436): event name → analytics facade call. Unknown events are
/// ignored — same as the switch this replaced.
final Map<String, void Function(Map<String, Object> params)>
_faChatAnalyticsRoutes = {
  'approval_mode_changed': (params) =>
      AppAnalytics.instance.approvalModeChanged(params['mode'] as String),
  'secret_request': (params) =>
      AppAnalytics.instance.secretRequest(params['result'] as String),
  'message_sent': (params) => AppAnalytics.instance.messageSent(
    hasAttachments: params['has_attachments'] as bool,
    textLength: params['text_length'] as int,
  ),
  'upload_added': (params) =>
      AppAnalytics.instance.uploadAdded(params['count'] as int),
  'voice_input_used': (_) => AppAnalytics.instance.voiceInputUsed(),
  'screen_opened': (params) =>
      AppAnalytics.instance.screenOpened(params['screen_name'] as String),
  'files_opened': (params) =>
      AppAnalytics.instance.filesOpened(params['source'] as String),
  'settings_opened': (_) => AppAnalytics.instance.settingsOpened(),
};

/// Routes fa_ui chat-widget track events into the app's analytics facade.
/// Public so the boot assignment can tear it off and tests can drive it.
void routeFaChatAnalytics(
  String event, [
  Map<String, Object> params = const {},
]) {
  _faChatAnalyticsRoutes[event]?.call(params);
}

/// Crashlytics: fatal Flutter errors + uncaught async errors flow into the
/// Firebase console (no web support — the guard skips the web platform
/// entirely, and any Firebase setup error keeps boot going without it).
/// Breadcrumbs: the debugPrint tee (already feeding AppLog) also leaves a
/// trail in the crash report.
void _wireCrashlyticsBreadcrumbs() {
  if (kIsWeb) return;
  try {
    if (Firebase.apps.isEmpty) return;
    final crashlytics = FirebaseCrashlytics.instance;
    FlutterError.onError = crashlytics.recordFlutterFatalError;
    PlatformDispatcher.instance.onError = (error, stack) {
      crashlytics.recordError(error, stack, fatal: true);
      return true;
    };
    final baseDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      baseDebugPrint(message, wrapWidth: wrapWidth);
      if (message != null) crashlytics.log(message);
    };
    debugPrint('[fah] crashlytics wired');
  } on Object catch (error) {
    debugPrint('[fah] crashlytics unavailable, continuing without: $error');
  }
}

/// Loads intl date symbols for every supported app locale.
Future<void> _loadIntlDateSymbols() async {
  for (final locale in AppLocalizations.supportedLocales) {
    await initializeDateFormatting(locale.languageCode);
  }
}

/// The extension-panel relay boot (issue #34, decomposed by #483): builds
/// the session manager, attaches the SW relay, wires the live-session
/// adoption contract, seeds the persisted registry from the SW's active
/// provider, and hands the result to [onHome]. The widget layer (caller)
/// owns navigation and `mounted` checks; every failure path funnels into
/// [onError] — including a null [createRelay] result (not hosted) and a
/// throwing one.
Future<void> bootExtensionRelay({
  /// The panel env; `null` builds the platform one (real boots).
  ExecutionEnv? env,

  /// Overridable for tests; production tears off [RelayAgentService.create].
  Future<RelayAgentService?> Function()? createRelay,
  required Future<void> Function(
    FlutterSessionManager manager,
    ProviderRegistry registry,
  )
  onHome,
  required void Function(String message) onError,
}) async {
  final resolvedEnv = env ?? await createPlatformEnv();
  final manager = FlutterSessionManager(
    env: resolvedEnv,
    sessionsRoot: defaultSessionsRoot(resolvedEnv.sessionCwd),
  );
  try {
    final relay = await (createRelay ?? RelayAgentService.create)();
    if (relay == null) {
      debugPrint('[fah] relay create returned null (not hosted?)');
      onError('extension service worker not reachable');
      return;
    }
    manager.addSession(
      relay.relaySessionId.isEmpty ? 'relay' : relay.relaySessionId,
      relay,
    );
    // The SAME adoption contract as the desktop hosted boot (the
    // createRelayServiceIfHosted caller): a session_new/session_open from
    // ANY surface arrives as an attach broadcast — re-key the slot and the
    // selection source. Without this the panel kept its BOOT session id
    // forever: the drawer's live row pinned the stale dot, the real live
    // session rendered nowhere, and the archived twin of the stale slot
    // duplicated the row.
    relay.onLiveSessionIdChanged = (newId) {
      manager.hostedLiveId.value = newId;
      manager.rekeyActiveSession(newId);
    };
    // The hello/attach handshake may have completed BEFORE the callback
    // was assigned (RelayAgentService.create awaits it) — converge once
    // so hostedLiveId is authoritative from the first frame.
    final liveAtBoot = relay.liveSessionId;
    if (liveAtBoot != null && liveAtBoot.isNotEmpty) {
      manager.hostedLiveId.value = liveAtBoot;
      manager.rekeyActiveSession(liveAtBoot);
    }
    // The models/provider screens read this registry; in relay mode the
    // truth lives in the SW's chrome.storage, so seed one entry from the
    // attach-time settings snapshot. The key stays session-only
    // (rememberKey) — re-saving the form round-trips it via settings_put
    // instead of losing it. The persisted registry (providers.json) — the
    // Providers screen's adds live here across reloads. NEVER swap it for
    // a session-only in-memory instance: the Default-chat-model picker
    // shares this instance, and an empty one makes the picker show nothing
    // while the Providers screen (its own null-fallback registry) looks
    // fine.
    final registry = await ProviderRegistry.load(resolvedEnv);
    // Issue #327: the guard needs the registry rows to judge a
    // settings_put against (review MINOR - the relay path skipped it).
    relay.providerRegistry = registry;
    final sw = relay.swProvider;
    debugPrint(
      '[fah] relay boot: session=${relay.relaySessionId} '
      'swProvider=${sw == null ? 'none' : '${sw['baseUrl']} / ${sw['model']}'} '
      'registry=${registry.providers.length}',
    );
    await seedRelaySwProvider(registry, sw);
    await onHome(manager, registry);
  } on Object catch (e) {
    debugPrint('[fah] relay boot failed: $e');
    onError('$e');
  }
}

/// Makes sure the SW's active provider exists as a picker tile (the key
/// stays session-only; the apply flow round-trips it via settings_put).
/// A no-op when the SW has no active provider or the registry already
/// knows its base URL.
Future<void> seedRelaySwProvider(
  ProviderRegistry registry,
  Map<String, String>? sw,
) async {
  if (sw == null || sw['baseUrl']!.isEmpty) return;
  final known = registry.providers.any((p) => p.baseUrl == sw['baseUrl']);
  if (known) return;
  final base = Uri.tryParse(sw['baseUrl']!);
  final provider = await registry.add(
    name: base?.host ?? sw['baseUrl']!,
    baseUrl: sw['baseUrl']!,
    modelId: sw['model'] ?? '',
  );
  registry.rememberKey(provider.id, sw['apiKey'] ?? '');
}

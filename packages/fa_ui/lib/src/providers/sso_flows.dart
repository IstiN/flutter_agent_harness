// l10n:ignore-file — flow status surfaces — en-only by design (EPAM-internal
// tooling, the flutter_app flow services follow the same convention).
// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa_llm/fa_llm.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa_ui/src/providers/copilot_connect_sheet.dart';
import 'package:fa_ui/src/providers/sso_desktop_flows.dart';
import 'package:fa_ui/src/stores/keychain_store.dart';
import 'package:fa_ui/src/stores/provider_registry.dart';
import 'package:fa_ui/src/stores/session_keys_store.dart';
import 'package:fa_ui/src/strings/fa_ui_strings.dart';
import 'package:fa_ui/src/utils/page_presentation.dart';
import 'package:fa_ui/src/widgets/snackbars.dart';

/// The desktop sign-in hop for CodeMie: the CLI's loopback-callback SSO
/// flow, or an injected fake in tests.
typedef FaUiCodeMieSsoFlow =
    Future<CodeMieSsoCredentials?> Function(
      String orgUrl,
      void Function(String) onStatus,
    );

/// The desktop sign-in hop for ChatGPT (Codex): the CLI's OAuth flow, or
/// an injected fake in tests.
typedef FaUiChatGptOAuthFlow =
    Future<ChatGptOAuthCredentials?> Function(void Function(String) onStatus);

/// The desktop sign-in hop for AIIN: the CLI's sign-in + key
/// auto-register flow, or an injected fake in tests.
typedef FaUiAiinConnectFlow =
    Future<AiinConnectResult?> Function(void Function(String) onStatus);

/// Ready-made SSO/OAuth/device-flow connect flows for the four
/// callback-gated Add-provider tiles (issue #1321).
///
/// A thin-client host wires all four tiles with ONE line —
/// `AddProviderPresetPickerPage(registry: registry, sso: FaUiSso(registry:
/// registry))` — instead of re-implementing the enterprise sign-ins. The
/// LOGIC stays in the core package (loopback callback servers, token
/// exchange, model-list dialects, key-slot naming via
/// [CustomProviderRegistry]); [FaUiSso] only binds it to widgets and lands
/// the result through the host's existing store abstractions
/// ([ProviderRegistry], [KeychainStore], [SessionKeysStore]) — the
/// architecture-boundary contract on #1321. A host can still override any
/// single flow with its own picker callback (explicit callbacks win over
/// [FaUiSso]).
///
/// The default hops run on desktop (macOS/Windows/Linux — the CLI's
/// browser + localhost-callback flows); mobile hosts keep passing their
/// own WebView-backed callbacks, and the web build reports the platform as
/// unsupported instead of failing mid-flow.
class FaUiSso {
  /// Creates the flow bundle. [registry] is where completed sign-ins land
  /// (the same registry the picker saves key-based presets into).
  const FaUiSso({
    required this.registry,
    this.keychain,
    this.sessionKeys,
    this.onConnected,
    this.copilotCallbacks,
    this.codeMieSsoFn = desktopCodeMieSso,
    this.chatGptOAuthFn = desktopChatGptOAuth,
    this.aiinConnectFn = desktopAiinConnect,
    this.fetchCodeMieModelsFn = fetchCodeMieModels,
    this.modelsFetcher = fetchModelsForEndpoint,
  });

  /// The provider registry the connected entries are saved to. A host
  /// wiring `FaUiSso` into the add-provider picker or ProvidersSection
  /// MUST pass the same registry instance that widget receives — the
  /// picker asserts this in debug mode (a split silently partitions SSO
  /// landings away from the key-based saves).
  final ProviderRegistry registry;

  /// The secure store for the entry-scoped key slots (iOS/macOS Keychain,
  /// Android Keystore — the `fah/keychain` channel). Null uses a default
  /// [KeychainStore]; unavailability degrades to [sessionKeys].
  final KeychainStore? keychain;

  /// The saved-keys store, the portable fallback when no Keychain is
  /// available. Null resolves the nearest [SessionKeysScope] at connect
  /// time.
  final SessionKeysStore? sessionKeys;

  /// Called with the landed provider after every successful connect.
  final void Function(CustomProvider provider)? onConnected;

  /// Override for the Copilot device-flow chain (tests / hosts with their
  /// own wiring). Null builds the default from the fa_llm device flow.
  final CopilotConnectCallbacks? copilotCallbacks;

  /// The CodeMie sign-in hop (tests inject a fake).
  final FaUiCodeMieSsoFlow codeMieSsoFn;

  /// The ChatGPT sign-in hop (tests inject a fake).
  final FaUiChatGptOAuthFlow chatGptOAuthFn;

  /// The AIIN sign-in hop (tests inject a fake).
  final FaUiAiinConnectFlow aiinConnectFn;

  /// The CodeMie model-list fetch (tests inject a fake).
  final Future<List<String>> Function(String apiBase, String cookie)
  fetchCodeMieModelsFn;

  /// The `/models` dispatch behind the AIIN model pick (tests inject a
  /// fake).
  final ModelsEndpointFetcher modelsFetcher;

  /// Runs the CodeMie enterprise SSO: the CLI browser flow, then the org
  /// lands as a custom entry (`<org>/code-assistant-api/v1`) with the
  /// session cookie in the canonical `FA_KEY_<HOST>` slot. A completed
  /// sign-in on an endpoint that already has an entry re-auths it in place
  /// (name and model kept — the CLI re-auth semantics); a fresh org asks
  /// for a model. Returns whether a provider was connected.
  Future<bool> connectCodeMie(
    BuildContext context, {
    String orgUrl = defaultCodeMieBaseUrl,
  }) => _guarded('CodeMie', context, () => _connectCodeMie(context, orgUrl));

  Future<bool> _connectCodeMie(BuildContext context, String orgUrl) async {
    final credentials = await _runDesktopFlow(
      context,
      'CodeMie',
      () => codeMieSsoFn(orgUrl, _logStatus),
    );
    if (credentials == null || credentials.authToken.isEmpty) return false;
    final baseUrl = '${credentials.apiUrl}/v1';
    // Re-auth: the endpoint already has an entry — refresh its key only.
    final existing = registry.byBaseUrl(baseUrl);
    if (existing != null) {
      registry.rememberKey(existing.id, credentials.authToken);
      if (context.mounted) {
        showFahSnack(context, 'CodeMie re-authorized', hideCurrent: true);
      }
      return true;
    }
    final models = await _fetchLenient(
      () => fetchCodeMieModelsFn(baseUrl, credentials.authToken),
    );
    if (!context.mounted) return false;
    final modelId = await _pickModel(context, 'CodeMie', models);
    if (modelId == null || modelId.isEmpty) return false;
    final name = _uniqueEntryName(registry, _hostOf(orgUrl), baseUrl);
    final provider = await _landEntry(
      registry,
      name: name,
      baseUrl: baseUrl,
      modelId: modelId,
    );
    registry.rememberKey(provider.id, credentials.authToken);
    _notify(provider);
    if (context.mounted) {
      showFahSnack(context, 'CodeMie connected', hideCurrent: true);
    }
    return true;
  }

  /// Runs the ChatGPT (Codex) OAuth: the CLI browser flow, then the
  /// account lands as a `chatgpt-codex` custom entry named after the
  /// account email (the CLI contract — several accounts coexist), the
  /// encoded credential blob in the entry-scoped slot. Returns whether a
  /// provider was connected.
  Future<bool> connectChatGpt(BuildContext context) =>
      _guarded('ChatGPT', context, () => _connectChatGpt(context));

  Future<bool> _connectChatGpt(BuildContext context) async {
    final sessionKeys = this.sessionKeys ?? SessionKeysScope.maybeOf(context);
    final credentials = await _runDesktopFlow(
      context,
      'ChatGPT',
      () => chatGptOAuthFn(_logStatus),
    );
    if (credentials == null) return false;
    final identity = _chatGptEmail(credentials.idToken) ?? 'ChatGPT';
    final name = _uniqueEntryName(registry, identity, chatGptCodexBaseUrl);
    final provider = await _landEntry(
      registry,
      name: name,
      baseUrl: chatGptCodexBaseUrl,
      modelId: chatGptCodexDefaultModel,
      kind: chatgptCodexDispatchHint,
    );
    registry.rememberKey(provider.id, credentials.encode());
    await _persistEntryScopedKey(
      keychain: keychain,
      sessionKeys: sessionKeys,
      keyName: CustomProviderRegistry.keyNameFor(
        chatGptCodexBaseUrl,
        providerName: name,
      ),
      value: credentials.encode(),
    );
    _notify(provider);
    if (context.mounted) {
      showFahSnack(context, 'ChatGPT connected', hideCurrent: true);
    }
    return true;
  }

  /// Runs the AIIN sign-in + key auto-register: the CLI browser flow, then
  /// the account lands as a custom entry named after the account email
  /// with the `sk-aiin-…` key in the entry-scoped slot, and a model is
  /// picked (the manual entry covers a failed list fetch). Returns whether
  /// a provider was connected.
  Future<bool> connectAiin(BuildContext context) =>
      _guarded('AIIN', context, () => _connectAiin(context));

  Future<bool> _connectAiin(BuildContext context) async {
    final sessionKeys = this.sessionKeys ?? SessionKeysScope.maybeOf(context);
    final result = await _runDesktopFlow(
      context,
      'AIIN',
      () => aiinConnectFn(_logStatus),
    );
    if (result == null) return false;
    const baseUrl = '$aiinApiBaseUrl/v1';
    final identity = result.email ?? 'AIIN';
    final name = _uniqueEntryName(registry, identity, baseUrl);
    final models = await _fetchLenient(
      () async => (await modelsFetcher(baseUrl, apiKey: result.apiKey.raw)).$1,
    );
    if (!context.mounted) return false;
    final modelId = await _pickModel(context, 'AIIN', models);
    if (modelId == null || modelId.isEmpty) return false;
    final provider = await _landEntry(
      registry,
      name: name,
      baseUrl: baseUrl,
      modelId: modelId,
    );
    registry.rememberKey(provider.id, result.apiKey.raw);
    await _persistEntryScopedKey(
      keychain: keychain,
      sessionKeys: sessionKeys,
      keyName: CustomProviderRegistry.keyNameFor(baseUrl, providerName: name),
      value: result.apiKey.raw,
    );
    _notify(provider);
    if (context.mounted) {
      showFahSnack(context, 'AIIN connected', hideCurrent: true);
    }
    return true;
  }

  /// Runs the GitHub Copilot connect: the device-flow sheet (works on
  /// every non-web platform — no callback server needed), then the account
  /// lands as a `copilot` custom entry with the GitHub token stored
  /// entry-scoped (the CLI contract). Returns whether a provider was
  /// connected.
  Future<bool> connectCopilot(BuildContext context) =>
      _guarded('Copilot', context, () => _connectCopilot(context));

  Future<bool> _connectCopilot(BuildContext context) async {
    final sessionKeys = this.sessionKeys ?? SessionKeysScope.maybeOf(context);
    if (kIsWeb) {
      // github.com serves no CORS headers — the web build cannot run the
      // device flow. Say so instead of failing mid-sheet.
      showFahSnack(
        context,
        'GitHub Copilot sign-in is not available on web — use the desktop '
        'or mobile app.',
      );
      return false;
    }
    CopilotConnectResult? result;
    await showCopilotConnectSheet(
      context: context,
      callbacks:
          copilotCallbacks ??
          CopilotConnectCallbacks(
            requestDeviceCode: requestCopilotDeviceCode,
            pollAccessToken: (deviceCode) =>
                pollCopilotAccessToken(deviceCode: deviceCode.deviceCode),
            fetchLogin: (token) => fetchGithubLogin(githubToken: token),
            // The sheet's model step: the live /models of the resolved
            // endpoint (the Copilot token exchange runs inside the
            // dialect) — no default model exists.
            fetchModels: (token, baseUrl) async =>
                (await fetchModelsForEndpoint(
                  baseUrl,
                  apiKey: token,
                  provider: copilotDispatchHint,
                )).$1,
          ),
      onResult: (r) => result = r,
    );
    final connect = result;
    if (connect == null) return false;
    final CustomProvider? provider;
    try {
      provider = await landCopilotConnect(
        registry,
        connect,
        keychain: keychain,
        sessionKeys: sessionKeys,
      );
    } on Object catch (error) {
      _logStatus('Copilot connect failed: $error');
      if (context.mounted) {
        showFahErrorSnack(context, 'Copilot connect failed: $error');
      }
      return false;
    }
    if (provider == null) return false;
    _notify(provider);
    if (context.mounted) {
      showFahSnack(context, 'Copilot connected', hideCurrent: true);
    }
    return true;
  }

  /// Lands a completed [showCopilotConnectSheet] result in [registry]:
  /// re-auth refreshes the (name + endpoint)-matched entry's key in place,
  /// anything else adds `copilot-<login>`; the GitHub token is remembered
  /// for the session and persisted entry-scoped (`FA_KEY_COPILOT_<NAME>`,
  /// Keychain first, saved-keys store as the fallback). Public because a
  /// host running the sheet with its own callbacks lands through the same
  /// helper. Returns the landed provider, or null when [connect] carries
  /// no model.
  static Future<CustomProvider?> landCopilotConnect(
    ProviderRegistry registry,
    CopilotConnectResult connect, {
    KeychainStore? keychain,
    SessionKeysStore? sessionKeys,
  }) async {
    if (connect.modelId.isEmpty) return null;
    final baseUrl = copilotBaseUrl(
      accountType: connect.accountType,
      baseUrlOverride: connect.baseUrlOverride,
    );
    final existing = registry.providers
        .where((p) => p.name == connect.entryName && p.baseUrl == baseUrl)
        .firstOrNull;
    final CustomProvider provider;
    if (existing != null) {
      provider = existing;
    } else {
      provider = await registry.add(
        name: connect.entryName,
        baseUrl: baseUrl,
        modelId: connect.modelId,
        // Persist the provider identity so the model-list dispatch rides
        // the Copilot wire (token exchange) even if the URL is edited.
        kind: copilotDispatchHint,
      );
    }
    registry.rememberKey(provider.id, connect.githubToken);
    await _persistEntryScopedKey(
      keychain: keychain,
      sessionKeys: sessionKeys,
      keyName: CustomProviderRegistry.copilotEntryKeyName(connect.entryName),
      value: connect.githubToken,
    );
    return provider;
  }

  void _notify(CustomProvider provider) => onConnected?.call(provider);

  /// One sign-in flow per provider at a time — the CLI's
  /// `_providerFlowActive` latch. A second tap while a hop waits for its
  /// callback would bind a second loopback server and race the first
  /// landing's re-auth; the second caller gets a named snack instead.
  static final Set<String> _inFlight = {};

  Future<bool> _guarded(
    String provider,
    BuildContext context,
    Future<bool> Function() flow,
  ) async {
    if (!_inFlight.add(provider)) {
      if (context.mounted) {
        showFahSnack(context, 'A $provider sign-in is already running.');
      }
      return false;
    }
    try {
      return await flow();
    } finally {
      _inFlight.remove(provider);
    }
  }
}

/// The entry-scoped key persist shared by the connect methods (Keychain
/// first, the saved-keys store as the portable fallback — the CLI
/// contract).
Future<void> _persistEntryScopedKey({
  required KeychainStore? keychain,
  required SessionKeysStore? sessionKeys,
  required String keyName,
  required String value,
}) async {
  var persisted = false;
  final kc = keychain ?? const KeychainStore();
  if (await kc.isAvailable()) {
    persisted = await kc.set(keyName, value);
  }
  if (!persisted) {
    await sessionKeys?.set(keyName, value);
  }
}

/// Runs a desktop sign-in hop — the single error boundary for the three
/// desktop hops, mirroring the CLI's broad wrap of the same flows
/// (`catch (e) { io.writeln('… failed: $e'); }`). An unsupported platform
/// (web stub or the mobile refusal in `sso_desktop_flows_io.dart`) gets
/// the named platform snack; any other failure (loopback bind
/// `SocketException`, unexpected IO/process errors) surfaces as an error
/// snack instead of escaping into the tap handler's zone. Null otherwise
/// means the user cancelled or the flow reported its own failure through
/// the status channel.
Future<T?> _runDesktopFlow<T>(
  BuildContext context,
  String provider,
  Future<T?> Function() flow,
) async {
  if (context.mounted &&
      !kIsWeb &&
      const {
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.windows,
      }.contains(defaultTargetPlatform)) {
    // Desktop-only: the hop can legitimately wait minutes for the browser
    // callback — give the picker user visible in-flight feedback (the
    // status lines themselves stay debug-only diagnostics). Mobile/web
    // refuse synchronously below, so a waiting hint there would be noise
    // racing the refusal snack in the queue.
    showFahSnack(
      context,
      'Waiting for the $provider sign-in — complete it in your browser.',
      duration: const Duration(seconds: 30),
    );
  }
  try {
    return await flow();
  } on UnsupportedError {
    if (context.mounted) {
      showFahSnack(
        context,
        '$provider sign-in is not available on this platform.',
        hideCurrent: true,
      );
    }
    return null;
  } on Object catch (error) {
    _logStatus('$provider sign-in failed: $error');
    if (context.mounted) {
      showFahErrorSnack(
        context,
        '$provider sign-in failed: $error',
        hideCurrent: true,
      );
    }
    return null;
  }
}

/// Status lines from the core flows: diagnostics only — the browser page
/// itself is the user-facing progress surface.
void _logStatus(String message) {
  if (kDebugMode) debugPrint('fa_ui sso: $message');
}

/// Fetches a model list leniently — a network error yields an empty list
/// and the pick falls back to manual entry (the CLI/app convention).
Future<List<String>> _fetchLenient(
  Future<List<String>> Function() fetch,
) async {
  try {
    return await fetch();
  } on Object {
    return const [];
  }
}

/// The display host of an org URL (`https://codemie.lab.epam.com` →
/// `codemie.lab.epam.com`) — the CLI-parity default entry name.
String _hostOf(String url) => Uri.tryParse(url)?.host ?? url;

/// A name no OTHER-endpoint entry uses (`-2`, `-3` … suffixes), so a
/// second account never steals a name; a same-name SAME-endpoint entry
/// stays (the caller's reuse path treats it as re-auth).
String _uniqueEntryName(
  ProviderRegistry registry,
  String identity,
  String baseUrl,
) {
  var name = identity;
  var suffix = 2;
  var clash = registry.byName(name);
  while (clash != null && clash.baseUrl != baseUrl) {
    name = '$identity-${suffix++}';
    clash = registry.byName(name);
  }
  return name;
}

/// Adds or updates a registry entry keyed by (name, endpoint): the
/// name-on-same-endpoint shape updates in place (the id — and with it
/// every dropdown selection — survives), anything else adds.
Future<CustomProvider> _landEntry(
  ProviderRegistry registry, {
  required String name,
  required String baseUrl,
  required String modelId,
  String? kind,
}) async {
  final existing = registry.byName(name);
  if (existing != null && existing.baseUrl == baseUrl) {
    final updated = CustomProvider(
      id: existing.id,
      name: name,
      baseUrl: baseUrl,
      modelId: modelId.isEmpty ? existing.modelId : modelId,
      requiresKey: existing.requiresKey,
      provenance: existing.provenance,
      kind: existing.kind ?? kind,
    );
    await registry.update(updated);
    return updated;
  }
  return registry.add(
    name: name,
    baseUrl: baseUrl,
    modelId: modelId,
    kind: kind,
  );
}

/// The `email` claim of a JWT payload, or null when absent/malformed —
/// the account identity seeding ChatGPT/AIIN entry names.
String? _chatGptEmail(String idToken) {
  final parts = idToken.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    final email = payload['email'];
    return email is String && email.isNotEmpty ? email : null;
  } on Object {
    return null;
  }
}

/// Pushes the model pick for the CodeMie/AIIN flows: the fetched list,
/// with an always-available manual entry (the only entry when the list
/// fetch failed — network errors must not block the connect). Null means
/// cancelled.
Future<String?> _pickModel(
  BuildContext context,
  String provider,
  List<String> models,
) => pushFaPage<String>(
  context,
  _SsoModelPickPage(title: provider, models: models),
);

class _SsoModelPickPage extends StatelessWidget {
  const _SsoModelPickPage({required this.title, required this.models});

  final String title;
  final List<String> models;

  @override
  Widget build(BuildContext context) {
    final strings = FaUiStrings.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('${strings.settingsPickModelTitle} — $title')),
      body: SafeArea(
        child: ListView(
          children: [
            for (final model in models)
              ListTile(
                title: Text(model),
                onTap: () => Navigator.pop(context, model),
              ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(
                models.isEmpty
                    ? 'Enter a model id manually'
                    : 'Enter a different model id manually',
              ),
              onTap: () async {
                final typed = await showDialog<String>(
                  context: context,
                  builder: (dialogContext) {
                    var modelId = '';
                    return AlertDialog(
                      title: const Text('Model id'),
                      content: TextField(
                        autofocus: true,
                        onChanged: (value) => modelId = value,
                        onSubmitted: (value) =>
                            Navigator.pop(dialogContext, value),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: Text(strings.settingsCancelButton),
                        ),
                        TextButton(
                          onPressed: () =>
                              Navigator.pop(dialogContext, modelId),
                          child: Text(strings.settingsApplyButton),
                        ),
                      ],
                    );
                  },
                );
                if (typed != null && typed.isNotEmpty && context.mounted) {
                  Navigator.pop(context, typed);
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

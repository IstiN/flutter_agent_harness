// l10n:ignore-file — connect flow screens — en-only by design
import 'package:http/http.dart' as http;

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart'
    if (dart.library.html) 'package:fa/services/oauth_cli_flow_stubs.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/aiin_web_auth.dart';
import 'package:fa/services/keychain_store.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa_ui/fa_ui.dart' show pushFaPage;
import 'package:url_launcher/url_launcher.dart' as url_launcher;

/// Runs the full AIIN (aiin.by) connect flow:
///
/// **Desktop (macOS/Windows/Linux)** — an ephemeral loopback callback server
/// is started, the system browser is opened for the aiin.by sign-in (Google
/// by default), and the OAuth-proxy redirect is caught by the server. The
/// temporary code is exchanged for AIIN JWTs, and an `sk-aiin-…` API key is
/// registered automatically — no copy-pasting keys.
///
/// **Web/iOS/Android** — an honest "not yet available" note (the loopback
/// callback server needs the desktop app; the AIIN key can still be pasted
/// as a custom provider).
///
/// After the connect, the flow picks a model from the public `/v1/models`
/// list, saves the provider as a custom entry named after the account email
/// (several AIIN accounts coexist), persists the key under the entry's own
/// secure-store slot (the CLI contract), and reconfigures the service.
///
/// Returns `true` when the flow completed and the service was reconfigured,
/// `false` when the user cancelled at any step.
Future<bool> runAiinConnectFlow({
  required BuildContext context,
  required ProviderRegistry registry,
  required AgentService? service,
  required LastConnectionStore lastConnectionStore,
  SessionKeysStore? sessionKeysStore,
  KeychainStore? keychainStore,
  Future<AiinConnectResult?> Function()? aiinConnectFn,

  /// Injectable HTTP (tests): used for the AIIN service calls.
  http.Client? aiinHttpClient,

  /// Injectable popup plumbing (tests): the web flow's popup opener and
  /// navigator (defaults come from the conditional dart:html impl).
  bool Function()? aiinOpenPopupFn,
  void Function(String url)? aiinNavigatePopupFn,
}) async {
  if (kIsWeb) {
    // One-click web connect: a popup OAuth, no loopback server needed
    // (the hosted callback page posts the code back; both AIIN hosts send
    // `access-control-allow-origin: *`). Progress lands in SnackBars —
    // the popup opens before any await, inside the tap gesture.
    void webStatus(String message) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
      }
      debugPrint('[AIIN web] $message');
    }

    final coordinator = AiinWebAuthCoordinator.instance;
    final result = await coordinator.connect(
      provider: await _preferredAiinProvider(aiinHttpClient),
      onStatus: webStatus,
      client: aiinHttpClient,
      openFn: aiinOpenPopupFn,
      navigateFn: aiinNavigatePopupFn,
    );
    if (result == null) {
      // AIIN's OAuth proxy currently allowlists only its own redirect URIs
      // ("client_redirect_uri is not allowed") — the automatic flow cannot
      // complete until the service allowlists our callback. Fall back to
      // the cabinet + paste-key path so the connect still works today.
      final failure = coordinator.lastFailure ?? '';
      if (failure.contains('client_redirect_uri is not allowed') &&
          context.mounted) {
        final pasted = await _pasteAiinKeyFallback(context);
        if (pasted == null) return false;
        if (!context.mounted) return false;
        return _finishAiinConnect(
          context,
          registry: registry,
          service: service,
          lastConnectionStore: lastConnectionStore,
          sessionKeysStore: sessionKeysStore,
          keychainStore: keychainStore,
          apiKey: pasted,
        );
      }
      return false;
    }
    if (!context.mounted) return false;
    return _finishAiinConnect(
      context,
      registry: registry,
      service: service,
      lastConnectionStore: lastConnectionStore,
      sessionKeysStore: sessionKeysStore,
      keychainStore: keychainStore,
      apiKey: result.apiKey.raw,
      accountLabel: result.email,
    );
  }
  final desktop = !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);
  final fallbackKeys = SessionKeysScope.maybeOf(context);
  if (!desktop) {
    // Loopback callbacks are impossible here and the AIIN proxy currently
    // blocks cross-device redirects — paste the cabinet key instead.
    if (!context.mounted) return false;
    final pasted = await _pasteAiinKeyFallback(context);
    if (pasted == null) return false;
    if (!context.mounted) return false;
    return _finishAiinConnect(
      context,
      registry: registry,
      service: service,
      lastConnectionStore: lastConnectionStore,
      sessionKeysStore: sessionKeysStore,
      keychainStore: keychainStore,
      apiKey: pasted,
    );
  }

  // Preflight: the AIIN proxy rejects un-allowlisted redirect URIs; detect
  // that BEFORE bouncing the user through the browser.
  try {
    await initiateAiinOAuth(
      provider: await _preferredAiinProvider(aiinHttpClient),
      redirectUri: 'http://127.0.0.1:9/callback',
      client: aiinHttpClient,
    );
  } on AiinAuthException catch (error) {
    if (error.message.contains('client_redirect_uri is not allowed')) {
      if (!context.mounted) return false;
      final pasted = await _pasteAiinKeyFallback(context);
      if (pasted == null) return false;
      if (!context.mounted) return false;
      return _finishAiinConnect(
        context,
        registry: registry,
        service: service,
        lastConnectionStore: lastConnectionStore,
        sessionKeysStore: sessionKeysStore ?? fallbackKeys,
        keychainStore: keychainStore,
        apiKey: pasted,
      );
    }
    // A different (transient?) service error — let the flow surface it.
  } on Object {
    // Network hiccup — the flow below will retry and report.
  }

  if (!context.mounted) return false;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('Opening browser for AIIN sign-in…'),
      duration: Duration(seconds: 3),
    ),
  );

  final result = aiinConnectFn != null
      ? await aiinConnectFn()
      : await runAiinConnectCliFlow(
          provider: await _preferredAiinProvider(aiinHttpClient),
          onStatus: (message) => debugPrint('[AIIN] $message'),
          openBrowserFn: (url) => url_launcher.launchUrl(
            Uri.parse(url),
            mode: url_launcher.LaunchMode.externalApplication,
          ),
        );
  if (result == null) return false;
  if (!context.mounted) return false;
  return _finishAiinConnect(
    context,
    registry: registry,
    service: service,
    lastConnectionStore: lastConnectionStore,
    sessionKeysStore: sessionKeysStore ?? fallbackKeys,
    keychainStore: keychainStore,
    apiKey: result.apiKey.raw,
    accountLabel: result.email,
  );
}

/// The shared post-connect continuation: model pick from the public
/// `/v1/models`, a named registry entry (the account email), entry-scoped
/// key persistence, and the service reconnect. Returns whether the flow
/// completed and the service was reconfigured.
Future<bool> _finishAiinConnect(
  BuildContext context, {
  required ProviderRegistry registry,
  required AgentService? service,
  required LastConnectionStore lastConnectionStore,
  required SessionKeysStore? sessionKeysStore,
  required KeychainStore? keychainStore,
  required String apiKey,
  String? accountLabel,
}) async {
  // ── Pick a model (public /v1/models on api.aiin.by) ─────────────────
  const baseUrl = aiinDefaultChatBaseUrl;
  final key = apiKey;
  List<String> models = const [];
  try {
    models = (await fetchModelsForEndpoint(baseUrl, apiKey: key)).$1;
  } on Object {
    // Network error — the picker opens empty and takes a manual id.
  }
  if (!context.mounted) return false;
  final modelId = await pushFaPage<String>(
    context,
    _AiinModelPickerPage(models: models),
  );
  if (modelId == null || modelId.isEmpty) return false;
  if (!context.mounted) return false;

  // ── Save provider + key ─────────────────────────────────────────────
  // The entry name IS the signed-in account's email (fall back to 'AIIN');
  // de-duplicated so a second AIIN account gets its own entry.
  final identity = accountLabel ?? 'AIIN';
  var name = identity;
  var suffix = 2;
  while (registry.providers.any(
    (p) => p.name == name && p.baseUrl == baseUrl,
  )) {
    name = '$identity-${suffix++}';
  }
  final provider = await registry.add(
    name: name,
    baseUrl: baseUrl,
    modelId: modelId,
  );
  registry.rememberKey(provider.id, key);
  // Entry-scoped secure persistence (the CLI contract): Keychain first,
  // saved-keys store as the portable fallback.
  final keyName = CustomProviderRegistry.keyNameFor(
    baseUrl,
    providerName: name,
  );
  var persisted = false;
  final keychain = keychainStore ?? const KeychainStore();
  if (await keychain.isAvailable()) {
    persisted = await keychain.set(keyName, key);
  }
  if (!persisted) {
    await sessionKeysStore?.set(keyName, key);
  }

  // ── Connect ─────────────────────────────────────────────────────────
  final config = AgentConfig(
    providerKind: 'aiin',
    modelId: modelId,
    baseUrl: baseUrl,
    apiKey: key,
  );
  if (service != null) await service.reconfigure(config);
  await lastConnectionStore.saveFromConfig(config);

  return true;
}

/// The app-side default chat endpoint of the AIIN provider (the catalog
/// spec's default base URL).
const aiinDefaultChatBaseUrl = 'https://api.aiin.by/v1';

/// Whether [key] looks like an AIIN API key (`sk-aiin-…`).
bool isValidAiinApiKey(String key) {
  final trimmed = key.trim();
  return trimmed.startsWith('sk-aiin-') && trimmed.length > 15;
}

/// The AIIN cabinet entry point (the user creates/pastes keys there while
/// the automatic OAuth redirect is not allowlisted).
const aiinCabinetUrl = 'https://aiin.by/app';

/// The fallback when the automatic sign-in cannot complete: open the AIIN
/// cabinet, let the user create a key, and paste it here. Returns the key
/// or null on cancel.
Future<String?> _pasteAiinKeyFallback(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (_) => const _AiinKeyPasteDialog(),
  );
}

class _AiinKeyPasteDialog extends StatefulWidget {
  const _AiinKeyPasteDialog();

  @override
  State<_AiinKeyPasteDialog> createState() => _AiinKeyPasteDialogState();
}

class _AiinKeyPasteDialogState extends State<_AiinKeyPasteDialog> {
  final _controller = TextEditingController();
  bool _valid = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('AIIN API key'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'AIIN currently blocks automatic sign-in redirects. '
            'Create an API key in the AIIN cabinet and paste it here.',
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => url_launcher.launchUrl(
                Uri.parse(aiinCabinetUrl),
                mode: url_launcher.LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Open the AIIN cabinet'),
            ),
          ),
          TextField(
            controller: _controller,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'sk-aiin-…',
              labelText: 'API key',
            ),
            onChanged: (value) => setState(
              () => _valid = isValidAiinApiKey(value),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _valid
              ? () => Navigator.of(context).pop(_controller.text.trim())
              : null,
          child: const Text('Connect'),
        ),
      ],
    );
  }
}

/// The identity provider to sign in with: google when the AIIN service
/// offers it (its default), else the first offered provider.
Future<String> _preferredAiinProvider([http.Client? client]) async {
  try {
    final providers = await fetchAiinOAuthProviders(client: client);
    if (providers.contains('google')) return 'google';
    if (providers.isNotEmpty) return providers.first;
  } on Object {
    // Offline / standalone — google is the documented default.
  }
  return aiinDefaultOAuthProvider;
}

/// The AIIN model picker: the fetched id list with a manual-entry row.
class _AiinModelPickerPage extends StatelessWidget {
  const _AiinModelPickerPage({required this.models});

  final List<String> models;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AIIN model')),
      body: SafeArea(
        child: models.isEmpty
            ? const _AiinManualModelEntry()
            : _AiinModelList(models: models),
      ),
    );
  }
}

class _AiinModelList extends StatelessWidget {
  const _AiinModelList({required this.models});

  final List<String> models;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: models.length + 1,
      itemBuilder: (context, index) {
        if (index == models.length) {
          return const ListTile(title: _AiinManualModelEntry());
        }
        final id = models[index];
        return ListTile(
          title: Text(id),
          onTap: () => Navigator.of(context).pop(id),
        );
      },
    );
  }
}

class _AiinManualModelEntry extends StatefulWidget {
  const _AiinManualModelEntry();

  @override
  State<_AiinManualModelEntry> createState() => _AiinManualModelEntryState();
}

class _AiinManualModelEntryState extends State<_AiinManualModelEntry> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'model id'),
            onSubmitted: (value) {
              if (value.trim().isNotEmpty) {
                Navigator.of(context).pop(value.trim());
              }
            },
          ),
        ),
        TextButton(
          onPressed: () {
            final value = _controller.text.trim();
            if (value.isNotEmpty) Navigator.of(context).pop(value);
          },
          child: const Text('Use'),
        ),
      ],
    );
  }
}

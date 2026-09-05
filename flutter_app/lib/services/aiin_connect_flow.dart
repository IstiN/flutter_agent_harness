// l10n:ignore-file — connect flow screens — en-only by design
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
}) async {
  if (kIsWeb) {
    // One-click web connect: a popup OAuth, no loopback server needed
    // (the hosted callback page posts the code back; both AIIN hosts send
    // `access-control-allow-origin: *`).
    final result = await AiinWebAuthCoordinator.instance.connect(
      provider: await _preferredAiinProvider(),
    );
    if (result == null) return false;
    if (!context.mounted) return false;
    return _finishAiinConnect(
      context,
      registry: registry,
      service: service,
      lastConnectionStore: lastConnectionStore,
      sessionKeysStore: sessionKeysStore,
      keychainStore: keychainStore,
      result: result,
    );
  }
  final desktop = !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows ||
          defaultTargetPlatform == TargetPlatform.linux);
  if (!desktop) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'AIIN sign-in is not yet available on this platform. '
            'Add api.aiin.by/v1 as a custom provider with a key instead.',
          ),
        ),
      );
    }
    return false;
  }

  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('Opening browser for AIIN sign-in…'),
      duration: Duration(seconds: 3),
    ),
  );

  final fallbackKeys = SessionKeysScope.maybeOf(context);
  final result = aiinConnectFn != null
      ? await aiinConnectFn()
      : await runAiinConnectCliFlow(
          provider: await _preferredAiinProvider(),
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
    result: result,
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
  required AiinConnectResult result,
}) async {
  // ── Pick a model (public /v1/models on api.aiin.by) ─────────────────
  const baseUrl = aiinDefaultChatBaseUrl;
  final key = result.apiKey.raw;
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
  final identity = result.email ?? 'AIIN';
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

/// The identity provider to sign in with: google when the AIIN service
/// offers it (its default), else the first offered provider.
Future<String> _preferredAiinProvider() async {
  try {
    final providers = await fetchAiinOAuthProviders();
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

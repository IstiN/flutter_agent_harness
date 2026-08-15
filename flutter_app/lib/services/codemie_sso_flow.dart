// l10n:ignore-file — SSO flow screens — en-only by design (EPAM-internal tooling)
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart'
    if (dart.library.html) 'package:fa/services/oauth_cli_flow_stubs.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/ui/screens/codemie_sso_webview.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa_ui/fa_ui.dart' show pushFaPage;

/// Runs the full CodeMie SSO flow:
///
/// **macOS** — a local callback server is started on a random port (the
/// port is baked into the SSO login URL), the system browser is opened so
/// the user authenticates with real cookies/passwords, and the redirect to
/// `http://localhost:<port>/?token=...` is caught by the server. This
/// mirrors the CLI flow and gives the best UX (password manager, saved
/// sessions). The macOS sandbox's `network.server` entitlement covers it.
///
/// **iOS** — a system-browser auth session (`ASWebAuthenticationSession`
/// via the `fah/web_auth_session` channel): it shares Safari's WebAuthn /
/// passkey support (Face ID), which an embedded WKWebView cannot offer
/// without a `webcredentials` associated-domain relationship with the IdP.
/// The session intercepts the `http://localhost:<port>/?token=...` redirect
/// by its `http` scheme. When the session cannot start, the flow falls back
/// to the in-app WebView ([CodeMieSsoWebViewPage]), which intercepts the
/// same redirect via its `NavigationDelegate`.
///
/// After SSO completes on either platform, the flow continues with model
/// selection and provider/connection setup:
/// 1. Fetches available models from the CodeMie API and shows a picker.
/// 2. Saves the org as a [CustomProvider] (or updates an existing one —
///    re-login keeps the model) and stores the cookie as the provider key.
/// 3. Reconfigures [service] with the new connection (cookie auth via
///    `model.headers`, no Bearer key) and persists it as the last connection.
///
/// Returns `true` when the flow completed and the service was reconfigured,
/// `false` when the user cancelled at any step.
Future<bool> runCodemieSsoFlow({
  required BuildContext context,
  required ProviderRegistry registry,
  required AgentService? service,
  required LastConnectionStore lastConnectionStore,
  String orgUrl = defaultCodeMieBaseUrl,
}) async {
  // ── Step 1: SSO ─────────────────────────────────────────────────────
  CodeMieSsoCredentials? credentials;
  if (Platform.isMacOS) {
    // macOS: local server + system browser (real cookies, password manager).
    credentials = await _desktopSso(context, orgUrl);
  } else if (Platform.isIOS) {
    // iOS: system auth session (Safari-grade WebAuthn/passkey support).
    final session = await _systemAuthSessionSso(orgUrl);
    if (session.sessionUnavailable) {
      if (!context.mounted) return false;
      // Fallback: in-app WebView (no passkeys, but password login works).
      credentials = await Navigator.of(context).push<CodeMieSsoCredentials?>(
        MaterialPageRoute(
          builder: (_) => CodeMieSsoWebViewPage(orgUrl: orgUrl),
        ),
      );
    } else {
      credentials = session.credentials;
    }
  } else {
    // Other platforms: in-app WebView.
    credentials = await Navigator.of(context).push<CodeMieSsoCredentials?>(
      MaterialPageRoute(builder: (_) => CodeMieSsoWebViewPage(orgUrl: orgUrl)),
    );
  }
  if (credentials == null) return false; // cancelled / timed out

  if (!context.mounted) return false;

  // ── Step 2: Pick project ───────────────────────────────────────────
  final baseUrl = '${credentials.apiUrl}/v1';
  final cookie = credentials.authToken;

  // Check for an existing provider (re-login keeps the same model).
  final existing = registry.providers
      .where((p) => p.baseUrl == baseUrl)
      .firstOrNull;

  // Fetch projects (informational, like the CLI flow).
  List<String> projects = const [];
  try {
    projects = await fetchCodeMieProjects(credentials.apiUrl, cookie);
  } on Object {
    // Network error — skip the project picker.
  }

  if (!context.mounted) return false;
  if (projects.isNotEmpty) {
    await _pickProject(context, projects);
    if (!context.mounted) return false;
  }

  // ── Step 3: Pick model ──────────────────────────────────────────────
  String? modelId = existing?.modelId;

  // Fetch available models for the picker.
  List<String> models = const [];
  try {
    models = await fetchCodeMieModels(baseUrl, cookie);
  } on Object {
    // Network error — fall through to the picker with an empty list
    // (the user can type a model id manually).
  }

  if (!context.mounted) return false;

  if (modelId == null || modelId.isEmpty) {
    modelId = await _pickModel(context, models, preselected: modelId);
    if (modelId == null || modelId.isEmpty) return false;
  } else {
    // Re-login: briefly show the fetched models so the user can switch
    // if they want, but pre-select the current model.
    final switched = await _pickModel(
      context,
      models,
      preselected: modelId,
      allowCancel: true,
    );
    if (switched != null && switched.isNotEmpty) {
      modelId = switched;
    }
  }

  if (!context.mounted) return false;

  // ── Step 3: Save provider + key ─────────────────────────────────────
  final name = _hostFromUrl(orgUrl);
  if (existing != null) {
    final updated = CustomProvider(
      id: existing.id,
      name: existing.name,
      baseUrl: baseUrl,
      modelId: modelId,
    );
    await registry.update(updated);
    registry.rememberKey(updated.id, cookie);
  } else {
    final provider = await registry.add(
      name: name,
      baseUrl: baseUrl,
      modelId: modelId,
    );
    registry.rememberKey(provider.id, cookie);
  }

  // ── Step 4: Connect ─────────────────────────────────────────────────
  final config = AgentConfig(
    providerKind: 'openai-completions',
    modelId: modelId,
    baseUrl: baseUrl,
    apiKey: cookie,
  );
  // A null service (first-run onboarding) skips the live reconfigure —
  // the persisted last connection is picked up by the boot auto-connect.
  if (service != null) await service.reconfigure(config);
  await lastConnectionStore.saveFromConfig(config);

  return true;
}

/// Extracts the host name from [url] for the provider display name.
String _hostFromUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri != null && uri.host.isNotEmpty) {
    final port = uri.port;
    final defaultPort = uri.scheme == 'https' ? 443 : 80;
    return port != 0 && port != defaultPort ? '${uri.host}:$port' : uri.host;
  }
  return 'codemie';
}

/// Shows a simple project picker page (dialog on wide, full page on narrow).
/// Purely informational (like the CLI flow) — the selection does not affect
/// auth headers.
Future<void> _pickProject(BuildContext context, List<String> projects) async {
  await pushFaPage<void>(
    context,
    _ProjectPickerPage(projects: projects, onSelected: (_) {}),
  );
}

/// The method channel driving `ASWebAuthenticationSession` on iOS (implemented
/// in `ios/Runner/AppDelegate.swift`).
const _webAuthSessionChannel = MethodChannel('fah/web_auth_session');

/// iOS SSO via a system-browser auth session. Unlike the embedded WKWebView,
/// `ASWebAuthenticationSession` runs the page in a Safari-grade context, so
/// the IdP can offer WebAuthn / passkey (Face ID) sign-in.
///
/// The session intercepts the CodeMie callback by its scheme: every page in
/// the flow is `https`, the final `http://localhost:<port>/?token=...`
/// redirect is the only `http` navigation, so `callbackScheme: 'http'`
/// catches exactly the token hand-off (the redirect never leaves the OS
/// browser context).
///
/// Returns the decoded credentials, or a record with [sessionUnavailable]
/// set when the session could not even start (the caller falls back to the
/// in-app WebView). `null` credentials with `sessionUnavailable == false`
/// means the user cancelled or the callback carried no usable token.
Future<({CodeMieSsoCredentials? credentials, bool sessionUnavailable})>
_systemAuthSessionSso(String orgUrl) async {
  // Same dummy-port convention as the WebView page: the port is baked into
  // the login URL but never bound — the session intercepts the redirect.
  const dummyPort = 48127;
  final ssoUrl = buildCodeMieSsoUrl(orgUrl, dummyPort);
  final String? callbackUrl;
  try {
    callbackUrl = await _webAuthSessionChannel.invokeMethod<String>(
      'authenticate',
      {'url': ssoUrl, 'callbackScheme': 'http'},
    );
  } on PlatformException {
    return (credentials: null, sessionUnavailable: true);
  } on MissingPluginException {
    return (credentials: null, sessionUnavailable: true);
  }
  if (callbackUrl == null) {
    return (credentials: null, sessionUnavailable: false); // cancelled
  }
  final token = Uri.tryParse(callbackUrl)?.queryParameters['token'];
  if (token == null || token.isEmpty) {
    return (credentials: null, sessionUnavailable: false);
  }
  try {
    final cookies = decodeCodeMieSsoToken(token);
    return (
      credentials: CodeMieSsoCredentials(
        cookies: cookies,
        apiUrl: codeMieApiBase(orgUrl),
        expiresAt: deriveCodeMieExpiresAt(cookies),
      ),
      sessionUnavailable: false,
    );
  } on Object {
    return (credentials: null, sessionUnavailable: false);
  }
}

/// macOS desktop SSO: starts a local callback server, opens the system
/// browser (so the user gets their real cookies and password manager), and
/// waits for the CodeMie redirect to `http://localhost:<port>/?token=...`.
///
/// Shows a non-blocking [SnackBar] with status so the user knows what is
/// happening. Returns `null` if the browser could not be opened or the
/// callback timed out / was cancelled.
Future<CodeMieSsoCredentials?> _desktopSso(
  BuildContext context,
  String orgUrl,
) async {
  // The context might come from a dialog that was popped (the preset
  // picker) — wrap the snackbar so a missing Scaffold doesn't crash.
  try {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Opening browser for CodeMie sign-in…'),
        duration: Duration(seconds: 3),
      ),
    );
  } on Object {
    // No Scaffold ancestor — the snackbar is cosmetic, not critical.
  }
  return runCodeMieSsoCliFlow(
    codeMieUrl: orgUrl,
    onStatus: (msg) => debugPrint('[CodeMie SSO] $msg'),
    openBrowserFn: (url) async {
      return url_launcher.launchUrl(
        Uri.parse(url),
        mode: url_launcher.LaunchMode.externalApplication,
      );
    },
  );
}

/// Shows a model picker page (dialog on wide, full page on narrow) and
/// returns the chosen model id.
///
/// When [models] is non-empty, a list of radio tiles is shown with a manual
/// entry field at the bottom. When [models] is empty, only the manual entry
/// field is shown.
///
/// [preselected] highlights the current model. When [allowCancel] is true,
/// the user can dismiss the page without picking (returns null).
Future<String?> _pickModel(
  BuildContext context,
  List<String> models, {
  String? preselected,
  bool allowCancel = false,
}) async {
  return pushFaPage<String>(
    context,
    _ModelPickerPage(
      models: models,
      preselected: preselected,
      allowCancel: allowCancel,
    ),
  );
}

class _ProjectPickerPage extends StatefulWidget {
  const _ProjectPickerPage({required this.projects, required this.onSelected});

  final List<String> projects;
  final ValueChanged<String> onSelected;

  @override
  State<_ProjectPickerPage> createState() => _ProjectPickerPageState();
}

class _ProjectPickerPageState extends State<_ProjectPickerPage> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('CodeMie Project')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                itemCount: widget.projects.length,
                itemBuilder: (context, index) {
                  final project = widget.projects[index];
                  return ListTile(
                    title: Text(project),
                    dense: true,
                    trailing: _selected == project
                        ? const Icon(Icons.check_circle, size: 20)
                        : const Icon(Icons.radio_button_unchecked, size: 20),
                    onTap: () => setState(() => _selected = project),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton(
                onPressed: () {
                  widget.onSelected(_selected ?? widget.projects.first);
                  Navigator.of(context).pop();
                },
                child: const Text('Continue'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelPickerPage extends StatefulWidget {
  const _ModelPickerPage({
    required this.models,
    this.preselected,
    this.allowCancel = false,
  });

  final List<String> models;
  final String? preselected;
  final bool allowCancel;

  @override
  State<_ModelPickerPage> createState() => _ModelPickerPageState();
}

class _ModelPickerPageState extends State<_ModelPickerPage> {
  late final TextEditingController _manualController;
  String? _selected;

  @override
  void initState() {
    super.initState();
    _manualController = TextEditingController();
    _selected = widget.preselected;
  }

  @override
  void dispose() {
    _manualController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Select Model')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                children: [
                  if (widget.models.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Could not fetch the model list. Enter a model id manually.',
                        style: theme.textTheme.bodySmall,
                      ),
                    )
                  else
                    for (final model in widget.models)
                      ListTile(
                        title: Text(model),
                        dense: true,
                        trailing: _selected == model
                            ? Icon(
                                Icons.check_circle,
                                size: 20,
                                color: theme.colorScheme.primary,
                              )
                            : Icon(
                                Icons.radio_button_unchecked,
                                size: 20,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                        onTap: () => setState(() => _selected = model),
                      ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TextField(
                    controller: _manualController,
                    decoration: const InputDecoration(
                      labelText: 'Or enter model id',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (value) {
                      if (value.trim().isNotEmpty) {
                        setState(() => _selected = value.trim());
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (widget.allowCancel)
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Cancel'),
                        ),
                      FilledButton(
                        onPressed: () {
                          final manual = _manualController.text.trim();
                          Navigator.of(
                            context,
                          ).pop(manual.isNotEmpty ? manual : _selected);
                        },
                        child: const Text('Connect'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

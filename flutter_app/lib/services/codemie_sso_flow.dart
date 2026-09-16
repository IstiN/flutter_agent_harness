// l10n:ignore-file — SSO flow screens — en-only by design (EPAM-internal tooling)
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/codemie_sso_flow_steps.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/relay/ext_runtime.dart';
import 'package:fa/ui/screens/codemie_sso_pickers.dart';
import 'package:fa/ui/screens/codemie_sso_webview.dart';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

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
///
/// The per-surface hops and the credential assembly live in
/// `codemie_sso_flow_steps.dart` (issue #476); this function only sequences
/// the steps.
Future<bool> runCodemieSsoFlow({
  required BuildContext context,
  required ProviderRegistry registry,
  required AgentService? service,
  required LastConnectionStore lastConnectionStore,
  String orgUrl = defaultCodeMieBaseUrl,
  // Injectable hop seams (tests); production passes the defaults.
  Future<CodeMieSsoCredentials?> Function(BuildContext, String orgUrl)?
  authenticate,
  Future<List<String>> Function(String apiBase, String cookie)? fetchProjects,
  Future<List<String>> Function(String baseUrl, String cookie)? fetchModels,
}) async {
  // The web build cannot run the loopback callback server — but INSIDE
  // the extension it never needs one: the app page may open the login
  // tab and fetch with the browser jar (`chrome.tabs` + `credentials:
  // 'include'`, no CORS under host permissions). The redirect
  // interception is a desktop/mobile-only concern.
  if (kIsWeb) {
    return _webSignin(
      context: context,
      registry: registry,
      service: service,
      lastConnectionStore: lastConnectionStore,
      orgUrl: orgUrl,
    );
  }

  // ── Step 1: SSO ─────────────────────────────────────────────────────
  final credentials = await (authenticate ?? _authenticate)(context, orgUrl);
  if (credentials == null || !context.mounted) {
    return false; // cancelled / timed out
  }

  return _completeSignIn(
    context: context,
    registry: registry,
    service: service,
    lastConnectionStore: lastConnectionStore,
    orgUrl: orgUrl,
    credentials: credentials,
    fetchProjects: fetchProjects,
    fetchModels: fetchModels,
  );
}

Future<bool> _webSignin({
  required BuildContext context,
  required ProviderRegistry registry,
  required AgentService? service,
  required LastConnectionStore lastConnectionStore,
  required String orgUrl,
}) async {
  if (isExtensionHost()) {
    return extensionCookieCodeMieSignin(
      context: context,
      registry: registry,
      service: service,
      lastConnectionStore: lastConnectionStore,
      orgUrl: orgUrl,
    );
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'CodeMie sign-in needs the desktop or mobile app '
          '(a localhost callback server), or the browser extension '
          '(cookie sign-in). Use a key-based provider in the plain '
          'web build.',
        ),
      ),
    );
  }
  return false;
}

/// The per-surface SSO hop (Step 1): macOS uses the CLI flow (local server
/// + system browser), iOS the system auth session with the in-app WebView
/// as the fallback, every other platform the in-app WebView directly.
Future<CodeMieSsoCredentials?> _authenticate(
  BuildContext context,
  String orgUrl,
) async {
  if (Platform.isMacOS) return desktopCodeMieSso(context, orgUrl);
  if (Platform.isIOS) return _iosSso(context, orgUrl);
  return _webViewSso(context, orgUrl);
}

/// iOS: the system auth session first; when the session cannot even start
/// (`sessionUnavailable`), falls back to the in-app WebView (no passkeys,
/// but password login works).
Future<CodeMieSsoCredentials?> _iosSso(
  BuildContext context,
  String orgUrl,
) async {
  final session = await systemAuthSessionCodeMieSso(orgUrl);
  if (!session.sessionUnavailable) return session.credentials;
  if (!context.mounted) return null;
  return _webViewSso(context, orgUrl);
}

/// The in-app WebView hop: intercepts `http://localhost:<port>/?token=...`
/// via its `NavigationDelegate`.
Future<CodeMieSsoCredentials?> _webViewSso(
  BuildContext context,
  String orgUrl,
) {
  return Navigator.of(context).push<CodeMieSsoCredentials?>(
    MaterialPageRoute(builder: (_) => CodeMieSsoWebViewPage(orgUrl: orgUrl)),
  );
}

/// Steps 2-4 after a successful SSO: the informational project picker, the
/// model pick (fresh login MUST pick; re-login keeps the current model
/// unless the user switches), then the shared save + connect assembly.
Future<bool> _completeSignIn({
  required BuildContext context,
  required ProviderRegistry registry,
  required AgentService? service,
  required LastConnectionStore lastConnectionStore,
  required String orgUrl,
  required CodeMieSsoCredentials credentials,
  Future<List<String>> Function(String apiBase, String cookie)? fetchProjects,
  Future<List<String>> Function(String baseUrl, String cookie)? fetchModels,
}) async {
  final baseUrl = '${credentials.apiUrl}/v1';
  final cookie = credentials.authToken;

  // Check for an existing provider (re-login keeps the same model).
  final existing = registry.providers
      .where((p) => p.baseUrl == baseUrl)
      .firstOrNull;

  if (!await _projectStep(context, credentials, fetchProjects: fetchProjects)) {
    return false;
  }

  final models = await (fetchModels ?? fetchCodeMieModelsLenient)(
    baseUrl,
    cookie,
  );

  if (!context.mounted) return false;

  final modelId = await resolveCodeMieModelId(
    models: models,
    current: existing?.modelId,
    pick: (models, {preselected, allowCancel = false}) =>
        showCodeMieModelPicker(
          context,
          models,
          preselected: preselected,
          allowCancel: allowCancel,
        ),
  );
  if (modelId == null || !context.mounted) return false;

  await saveCodemieConnection(
    registry: registry,
    service: service,
    lastConnectionStore: lastConnectionStore,
    orgUrl: orgUrl,
    baseUrl: baseUrl,
    modelId: modelId,
    key: cookie,
    existing: existing,
  );
  return true;
}

/// Fetches the projects and shows the informational picker (network errors
/// skip it entirely). Returns false when the flow must abort (unmounted).
Future<bool> _projectStep(
  BuildContext context,
  CodeMieSsoCredentials credentials, {
  Future<List<String>> Function(String apiBase, String cookie)? fetchProjects,
}) async {
  final projects = await (fetchProjects ?? fetchCodeMieProjectsLenient)(
    credentials.apiUrl,
    credentials.authToken,
  );
  if (!context.mounted) return false;
  if (projects.isNotEmpty) {
    await showCodeMieProjectPicker(context, projects);
    if (!context.mounted) return false;
  }
  return true;
}

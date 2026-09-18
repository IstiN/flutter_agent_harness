// l10n:ignore-file — SSO flow screens — en-only by design (EPAM-internal tooling)
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/codemie_extension_signin.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/relay/ext_runtime.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart'
    if (dart.library.html) 'package:fa/services/oauth_cli_flow_stubs.dart';
import 'package:fa/ui/screens/codemie_sso_pickers.dart';

/// The per-surface sign-in hops of the CodeMie SSO flow (issue #476): the
/// macOS CLI flow, the iOS `ASWebAuthenticationSession`, the extension
/// cookie branch, and the credential assembly they all share. Each step is
/// a small public unit so the flow function stays pure sequencing and the
/// reauth semantics stay byte-equal and testable.

/// Extracts the host name from [url] for the provider display name.
String codeMieHostFromUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri != null && uri.host.isNotEmpty) {
    final port = uri.port;
    final defaultPort = uri.scheme == 'https' ? 443 : 80;
    return port != 0 && port != defaultPort ? '${uri.host}:$port' : uri.host;
  }
  return 'codemie';
}

/// Nulls out an empty string — an empty pick means "cancel", not ''.
String? nonEmptyCodeMieId(String? id) => (id == null || id.isEmpty) ? null : id;

/// A model pick over the fetched models: returns the chosen id, or null
/// when the user cancelled. The service layer injects the real picker;
/// tests inject fakes.
typedef CodeMieModelPick =
    Future<String?> Function(
      List<String> models, {
      String? preselected,
      bool allowCancel,
    });

/// Resolves the model id for the SSO connection: a fresh login MUST pick a
/// model (an empty or cancelled pick aborts the flow); a re-login keeps the
/// current model unless the user actively switches (that picker is
/// cancellable — dismissing it keeps [current]).
Future<String?> resolveCodeMieModelId({
  required List<String> models,
  required String? current,
  required CodeMieModelPick pick,
}) async {
  if (current != null && current.isNotEmpty) {
    final switched = await pick(
      models,
      preselected: current,
      allowCancel: true,
    );
    return nonEmptyCodeMieId(switched) ?? current;
  }
  return nonEmptyCodeMieId(await pick(models, preselected: current));
}

/// Fetches the CodeMie projects; a network error yields an empty list —
/// the flow then skips the informational picker.
Future<List<String>> fetchCodeMieProjectsLenient(
  String apiBase,
  String cookie,
) async {
  try {
    return await fetchCodeMieProjects(apiBase, cookie);
  } on Object {
    return const [];
  }
}

/// Fetches the model ids for the picker; a network error yields an empty
/// list (the user can type a model id manually).
Future<List<String>> fetchCodeMieModelsLenient(
  String apiBase,
  String cookie,
) async {
  try {
    return await fetchCodeMieModels(apiBase, cookie);
  } on Object {
    return const [];
  }
}

/// Saves the org as a [CustomProvider] (or updates the existing one —
/// a re-login keeps id and name) and reconfigures [service], then persists
/// the last connection.
///
/// The credential-assembly contract: [key] is the session cookie string for
/// the SSO surfaces and the EMPTY string for the extension branch (cookie
/// jar auth, a bearer key never exists there).
Future<void> saveCodemieConnection({
  required ProviderRegistry registry,
  required AgentService? service,
  required LastConnectionStore lastConnectionStore,
  required String orgUrl,
  required String baseUrl,
  required String modelId,
  required String key,
  CustomProvider? existing,
}) async {
  final name = codeMieHostFromUrl(orgUrl);
  if (existing != null) {
    final updated = CustomProvider(
      id: existing.id,
      name: existing.name,
      baseUrl: baseUrl,
      modelId: modelId,
    );
    await registry.update(updated);
    registry.rememberKey(updated.id, key);
  } else {
    final provider = await registry.add(
      name: name,
      baseUrl: baseUrl,
      modelId: modelId,
    );
    registry.rememberKey(provider.id, key);
  }

  final config = AgentConfig(
    providerKind: 'openai-completions',
    modelId: modelId,
    baseUrl: baseUrl,
    apiKey: key,
  );
  // A null service (first-run onboarding) skips the live reconfigure —
  // the persisted last connection is picked up by the boot auto-connect.
  if (service != null) {
    await service.reconfigure(config);
    // Issue #623: the transcript may still show the auth-expired card
    // this sign-in just fixed — resolve it, or the user is offered a
    // re-authorize for a session that is already refreshed.
    service.resolveAuthExpiredCards();
  }
  await lastConnectionStore.saveFromConfig(config);
}

/// Non-blocking status hint for the desktop sign-in: the system browser is
/// about to open. The context might come from a dialog that was popped (the
/// preset picker) — a missing Scaffold must not crash the flow.
void showCodeMieBrowserHint(BuildContext context) {
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
}

/// macOS desktop SSO: starts a local callback server, opens the system
/// browser (so the user gets their real cookies and password manager), and
/// waits for the CodeMie redirect to `http://localhost:<port>/?token=...`.
///
/// Returns `null` if the browser could not be opened or the callback timed
/// out / was cancelled.
Future<CodeMieSsoCredentials?> desktopCodeMieSso(
  BuildContext context,
  String orgUrl,
) {
  showCodeMieBrowserHint(context);
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

/// The method channel driving `ASWebAuthenticationSession` on iOS (implemented
/// in `ios/Runner/AppDelegate.swift`).
const _webAuthSessionChannel = MethodChannel('fah/web_auth_session');

/// iOS SSO via a system-browser auth session. Unlike the embedded WKWebView,
/// `ASWebAuthenticationSession` runs the page in a Safari-grade context, so
/// the IdP can offer WebAuthn / passkey (Face ID) sign-in.
///
/// The session's scheme interception does NOT fire for `http://` URLs, so
/// the WebView's dummy-port trick cannot work here. Instead the app runs the
/// REAL loopback callback server (same as the desktop flow — iOS allows
/// loopback binds) and the session's final
/// `http://localhost:<port>/?token=...` redirect loads it for real; the
/// session sheet is then dismissed programmatically via the channel's
/// `cancel`.
///
/// Returns the decoded credentials, or a record with [sessionUnavailable]
/// set when the session could not even start (the caller falls back to the
/// in-app WebView). `null` credentials with `sessionUnavailable == false`
/// means the user cancelled or the callback carried no usable token.
Future<({CodeMieSsoCredentials? credentials, bool sessionUnavailable})>
systemAuthSessionCodeMieSso(String orgUrl) async {
  final server = CodeMieSsoCallbackServer();
  final int port;
  try {
    port = await server.start();
  } on Object {
    return (credentials: null, sessionUnavailable: true);
  }
  final ssoUrl = buildCodeMieSsoUrl(orgUrl, port);
  var sessionFailed = false;
  // No callbackScheme: nothing to intercept — the token arrives through the
  // local server, the session future completes only on cancel/dismiss.
  unawaited(
    _webAuthSessionChannel
        .invokeMethod<String>('authenticate', {'url': ssoUrl})
        .then((_) => server.close()) // user cancelled the sheet
        .onError((_, _) {
          sessionFailed = true;
          return server.close();
        }),
  );
  final token = await server.waitForToken();
  // Dismiss the sheet (shows the "Authorized" page only for a split second).
  unawaited(
    _webAuthSessionChannel.invokeMethod<void>('cancel').onError((_, _) => null),
  );
  if (sessionFailed) {
    return (credentials: null, sessionUnavailable: true);
  }
  final usableToken = nonEmptyCodeMieId(token);
  if (usableToken == null) {
    return (credentials: null, sessionUnavailable: false); // cancelled
  }
  try {
    return (
      credentials: decodeCodeMieSsoCredentials(usableToken, orgUrl),
      sessionUnavailable: false,
    );
  } on Object {
    return (credentials: null, sessionUnavailable: false);
  }
}

/// Decodes the callback token into session credentials — the golden
/// credential assembly: the full cookie jar, the resolved API base, and the
/// JWT-derived expiry. Throws on a malformed token.
CodeMieSsoCredentials decodeCodeMieSsoCredentials(String token, String orgUrl) {
  final cookies = decodeCodeMieSsoToken(token);
  return CodeMieSsoCredentials(
    cookies: cookies,
    apiUrl: codeMieApiBase(orgUrl),
    expiresAt: deriveCodeMieExpiresAt(cookies),
  );
}

/// The extension-host branch of the CodeMie sign-in: no SSO redirect and
/// no key — the login page opens in a normal browser tab, the cookie jar
/// is shared with the extension, and the app page's fetch
/// (`credentials: 'include'`) polls the models endpoint until the session
/// lands. The saved provider keeps an EMPTY key: the service worker's
/// streaming fetch carries the jar; a bearer key never exists.
///
/// Tests inject [pollSession] and [pickModel] fakes (the browser/extension
/// hops are untestable outside a real extension host).
Future<bool> extensionCookieCodeMieSignin({
  required BuildContext context,
  required ProviderRegistry registry,
  required AgentService? service,
  required LastConnectionStore lastConnectionStore,
  required String orgUrl,
  Future<List<String>?> Function({
    required String orgUrl,
    required bool Function() cancelled,
  })?
  pollSession,
  CodeMieModelPick? pickModel,
}) async {
  final apiBase = codeMieApiBase(orgUrl);
  final baseUrl = '$apiBase/v1';

  // A cancellable wait — the dialog carries only the story and the
  // Cancel button; the poll below owns the actual waiting.
  var cancelled = false;
  if (context.mounted) {
    _showExtensionWaitDialog(context, () => cancelled = true);
  }

  final models = await (pollSession ?? _pollExtensionSession)(
    orgUrl: orgUrl,
    cancelled: () => cancelled,
  );
  if (context.mounted) _popExtensionWaitDialog(context);

  if (models == null) {
    if (context.mounted) _snackExtensionNotCompleted(context);
    return false;
  }

  if (!context.mounted) return false;

  return _completeExtensionSignin(
    context: context,
    registry: registry,
    service: service,
    lastConnectionStore: lastConnectionStore,
    orgUrl: orgUrl,
    baseUrl: baseUrl,
    models: models,
    pickModel: pickModel,
  );
}

/// The post-poll half of the extension branch: the model pick (a re-login
/// keeps the same model pre-selected; either way the flow REQUIRES a
/// confirmed pick — unlike the SSO surfaces) and the keyless save+connect.
Future<bool> _completeExtensionSignin({
  required BuildContext context,
  required ProviderRegistry registry,
  required AgentService? service,
  required LastConnectionStore lastConnectionStore,
  required String orgUrl,
  required String baseUrl,
  required List<String> models,
  CodeMieModelPick? pickModel,
}) async {
  // Re-login keeps the same model (pre-selected in the picker).
  final existing = registry.providers
      .where((p) => p.baseUrl == baseUrl)
      .firstOrNull;
  final chosenModel = await (pickModel ?? _uiModelPick(context))(
    models,
    preselected: existing?.modelId,
  );
  final modelId = nonEmptyCodeMieId(chosenModel);
  if (modelId == null || !context.mounted) return false;

  await saveCodemieConnection(
    registry: registry,
    service: service,
    lastConnectionStore: lastConnectionStore,
    orgUrl: orgUrl,
    baseUrl: baseUrl,
    modelId: modelId,
    key: '', // cookie-jar auth — a bearer key never exists here
    existing: existing,
  );
  return true;
}

/// The default model pick: the shared quick-filter picker page.
CodeMieModelPick _uiModelPick(BuildContext context) {
  return (models, {preselected, allowCancel = false}) => showCodeMieModelPicker(
    context,
    models,
    preselected: preselected,
    allowCancel: allowCancel,
  );
}

void _showExtensionWaitDialog(BuildContext context, VoidCallback onCancel) {
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('CodeMie cookie sign-in'),
        content: const Text(
          'A browser tab with the CodeMie login page is opening. '
          'Sign in there — this dialog closes the moment the session '
          'lands (the extension shares the browser cookie jar).',
        ),
        actions: [
          TextButton(
            onPressed: () {
              onCancel();
              Navigator.of(dialogContext).pop();
            },
            child: const Text('Cancel'),
          ),
        ],
      ),
    ),
  );
}

void _popExtensionWaitDialog(BuildContext context) {
  final navigator = Navigator.of(context);
  if (navigator.canPop()) navigator.pop(); // the wait dialog
}

void _snackExtensionNotCompleted(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text(
        'CodeMie sign-in did not complete — no live session appeared '
        'within the wait window (or it was cancelled). Try again.',
      ),
    ),
  );
}

/// Polls for the extension session: opens the login tab in a normal browser
/// page and fetches the models endpoint with the shared cookie jar until a
/// live session answers. Returns null when the wait was cancelled or timed
/// out.
Future<List<String>?> _pollExtensionSession({
  required String orgUrl,
  required bool Function() cancelled,
}) {
  return pollCodeMieSignIn(
    probe: () async {
      final result = await extFetchString(
        '${codeMieApiBase(orgUrl)}/v1/llm_models?include_all=true',
      );
      if (result == null) throw StateError('not an extension host');
      return result;
    },
    openLoginPage: () {
      unawaited(extOpenTab('$orgUrl/login'));
    },
    cancelled: cancelled,
  );
}

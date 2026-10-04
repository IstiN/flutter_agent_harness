// l10n:ignore-file — connect flow screens — en-only by design
import 'dart:async' show Completer;

import 'package:http/http.dart' as http;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart'
    if (dart.library.html) 'package:fa/services/oauth_cli_flow_stubs.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/aiin_web_auth.dart';
import 'package:fa/services/keychain_store.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_auth_surface.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa_ui/fa_ui.dart'
    show pushFaPage, showFahErrorSnack, showFahSnack;
import 'package:url_launcher/url_launcher.dart' as url_launcher;

/// Runs the full AIIN (aiin.by) connect flow:
///
/// **Desktop (macOS/Windows/Linux)** — an ephemeral loopback callback server
/// is started, the system browser is opened for the aiin.by sign-in (Google
/// by default), and the OAuth-proxy redirect is caught by the server. The
/// temporary code is exchanged for AIIN JWTs, and an `sk-aiin-…` API key is
/// registered automatically — no copy-pasting keys.
///
/// **Mobile (iOS/Android)** — issue #976: the SAME loopback flow, opened in
/// the platform browser surface. iOS opens the hosted sign-in page in an
/// `ASWebAuthenticationSession` system sheet (via the shared
/// `fah/web_auth_session` channel — an embedded WebView would break Google
/// sign-in); the sheet's `http` scheme interception catches the
/// `http://127.0.0.1` redirect (gh-1044 AC9) and hands the callback URL
/// back to the flow — the loopback server stays armed as the fallback
/// leg. Android opens the external browser, whose redirect reaches the
/// on-device loopback server. A failed/cancelled sign-in is a visible
/// error (gh-1044 I4 — SSO is the only path, no key-paste fallback).
///
/// **Web** — the popup OAuth round-trip ([runAiinWebConnect], issue #486).
///
/// After the connect, the flow picks a model from the public `/v1/models`
/// list, saves the provider as a custom entry named after the account email
/// (several AIIN accounts coexist), persists the key under the entry's own
/// secure-store slot (the CLI contract), and reconfigures the service.
///
/// Returns `true` when the flow completed and the service was reconfigured,
/// `false` when the user cancelled at any step.
///
/// Single flight (gh-1044 I2/AC3, the F3 listener leak): a second Add tap
/// while an attempt is running JOINS it — one loopback listener per
/// attempt, retries never stack servers.
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

  /// Injectable `/v1/models` fetcher (tests) — defaults to the live fetch.
  Future<List<String>> Function(String baseUrl, {required String apiKey})?
  aiinModelsFetcher,

  /// Injectable web-callback timeout (tests) — defaults to the
  /// coordinator's 5 minutes.
  Duration? aiinWebTimeout,

  /// Re-authenticate an EXISTING AIIN entry instead of adding a new one:
  /// the fresh key replaces the stored one, the entry keeps its name and
  /// model, and the service reconnects on it (the editor's
  /// "Re-authenticate" path).
  CustomProvider? reauthenticateFor,
}) {
  final inFlight = _activeAiinConnectFlow;
  if (inFlight != null) {
    debugPrint(
      '[AIIN] connect already in progress — joining the running attempt',
    );
    return inFlight;
  }
  final done = _runAiinConnectFlowAttempt(
    context: context,
    registry: registry,
    service: service,
    lastConnectionStore: lastConnectionStore,
    sessionKeysStore: sessionKeysStore,
    keychainStore: keychainStore,
    aiinConnectFn: aiinConnectFn,
    aiinHttpClient: aiinHttpClient,
    aiinOpenPopupFn: aiinOpenPopupFn,
    aiinNavigatePopupFn: aiinNavigatePopupFn,
    aiinModelsFetcher: aiinModelsFetcher,
    aiinWebTimeout: aiinWebTimeout,
    reauthenticateFor: reauthenticateFor,
  );
  _activeAiinConnectFlow = done;
  // `.ignore()`: whenComplete returns a NEW future that completes with
  // `done`'s error — awaiting caller and this mirror would otherwise
  // deliver the same failure twice (the second copy as an unhandled
  // async exception). The mirror exists only to clear the latch.
  done.whenComplete(() {
    if (identical(_activeAiinConnectFlow, done)) {
      _activeAiinConnectFlow = null;
    }
  }).ignore();
  return done;
}

/// The in-flight connect attempt (see [runAiinConnectFlow]).
Future<bool>? _activeAiinConnectFlow;

/// Test hook: the single-flight guard is module state; a test that
/// abandons a running flow (a pending model picker at teardown) must
/// clear it so the next test starts clean.
@visibleForTesting
void resetAiinConnectFlightForTests() => _activeAiinConnectFlow = null;

/// The [runAiinConnectFlow] body. While it runs, the service is latched
/// into an add-provider flow (gh-1044 I1/AC6): boot/session-restore
/// reconfigures are refused for the duration — the active connection is
/// never hijacked mid-flow; the flow's own switch bypasses the latch.
Future<bool> _runAiinConnectFlowAttempt({
  required BuildContext context,
  required ProviderRegistry registry,
  required AgentService? service,
  required LastConnectionStore lastConnectionStore,
  SessionKeysStore? sessionKeysStore,
  KeychainStore? keychainStore,
  Future<AiinConnectResult?> Function()? aiinConnectFn,
  http.Client? aiinHttpClient,
  bool Function()? aiinOpenPopupFn,
  void Function(String url)? aiinNavigatePopupFn,
  Future<List<String>> Function(String baseUrl, {required String apiKey})?
  aiinModelsFetcher,
  Duration? aiinWebTimeout,
  CustomProvider? reauthenticateFor,
}) async {
  service?.beginProviderAddFlow();
  try {
    return await _dispatchAiinConnectFlow(
      context: context,
      registry: registry,
      service: service,
      lastConnectionStore: lastConnectionStore,
      sessionKeysStore: sessionKeysStore,
      keychainStore: keychainStore,
      aiinConnectFn: aiinConnectFn,
      aiinHttpClient: aiinHttpClient,
      aiinOpenPopupFn: aiinOpenPopupFn,
      aiinNavigatePopupFn: aiinNavigatePopupFn,
      aiinModelsFetcher: aiinModelsFetcher,
      aiinWebTimeout: aiinWebTimeout,
      reauthenticateFor: reauthenticateFor,
    );
  } finally {
    service?.endProviderAddFlow();
  }
}

/// The per-surface dispatch (web → [runAiinWebConnect], mobile →
/// [runAiinMobileConnect], desktop → the loopback CLI flow).
Future<bool> _dispatchAiinConnectFlow({
  required BuildContext context,
  required ProviderRegistry registry,
  required AgentService? service,
  required LastConnectionStore lastConnectionStore,
  SessionKeysStore? sessionKeysStore,
  KeychainStore? keychainStore,
  Future<AiinConnectResult?> Function()? aiinConnectFn,
  http.Client? aiinHttpClient,
  bool Function()? aiinOpenPopupFn,
  void Function(String url)? aiinNavigatePopupFn,
  Future<List<String>> Function(String baseUrl, {required String apiKey})?
  aiinModelsFetcher,
  Duration? aiinWebTimeout,
  CustomProvider? reauthenticateFor,
}) async {
  if (kIsWeb) {
    return runAiinWebConnect(
      context: context,
      registry: registry,
      service: service,
      lastConnectionStore: lastConnectionStore,
      sessionKeysStore: sessionKeysStore,
      keychainStore: keychainStore,
      aiinHttpClient: aiinHttpClient,
      aiinOpenPopupFn: aiinOpenPopupFn,
      aiinNavigatePopupFn: aiinNavigatePopupFn,
      aiinModelsFetcher: aiinModelsFetcher,
      aiinWebTimeout: aiinWebTimeout,
      reauthenticateFor: reauthenticateFor,
    );
  }
  final platform = defaultTargetPlatform;
  final desktop =
      !kIsWeb &&
      (platform == TargetPlatform.macOS ||
          platform == TargetPlatform.windows ||
          platform == TargetPlatform.linux);
  final mobile =
      !kIsWeb &&
      (platform == TargetPlatform.iOS || platform == TargetPlatform.android);
  final fallbackKeys = SessionKeysScope.maybeOf(context);
  if (mobile) {
    return runAiinMobileConnect(
      context: context,
      registry: registry,
      service: service,
      lastConnectionStore: lastConnectionStore,
      sessionKeysStore: sessionKeysStore ?? fallbackKeys,
      keychainStore: keychainStore,
      aiinConnectFn: aiinConnectFn,
      aiinHttpClient: aiinHttpClient,
      aiinModelsFetcher: aiinModelsFetcher,
      reauthenticateFor: reauthenticateFor,
    );
  }
  if (!desktop) {
    // No browser surface to complete the loopback round-trip with (web is
    // handled above, mobile above). gh-1044 I4: SSO is the only path —
    // the failure is a visible error, never a paste sheet.
    if (!context.mounted) return false;
    showFahErrorSnack(context, _aiinSignInFailedMessage);
    return false;
  }
  return _runAiinDesktopConnect(
    context,
    registry: registry,
    service: service,
    lastConnectionStore: lastConnectionStore,
    sessionKeysStore: sessionKeysStore,
    fallbackKeys: fallbackKeys,
    keychainStore: keychainStore,
    aiinConnectFn: aiinConnectFn,
    aiinModelsFetcher: aiinModelsFetcher,
    reauthenticateFor: reauthenticateFor,
  );
}

/// The web one-click branch of [runAiinConnectFlow] (issue #486): a
/// popup OAuth round-trip through [AiinWebAuthCoordinator]; a
/// timeout/cancel falls back to the paste-key cabinet path. Public step
/// seam: the kIsWeb hop is unreachable from VM tests, which drive this
/// directly (the #476 recipe).
Future<bool> runAiinWebConnect({
  required BuildContext context,
  required ProviderRegistry registry,
  required AgentService? service,
  required LastConnectionStore lastConnectionStore,
  SessionKeysStore? sessionKeysStore,
  KeychainStore? keychainStore,
  http.Client? aiinHttpClient,
  bool Function()? aiinOpenPopupFn,
  void Function(String url)? aiinNavigatePopupFn,
  Future<List<String>> Function(String baseUrl, {required String apiKey})?
  aiinModelsFetcher,
  Duration? aiinWebTimeout,
  CustomProvider? reauthenticateFor,
}) async {
  // One-click web connect: a popup OAuth, no loopback server needed
  // (the hosted callback page posts the code back; both AIIN hosts send
  // `access-control-allow-origin: *`). Progress lands in SnackBars —
  // the popup opens before any await, inside the tap gesture.
  void webStatus(String message, {bool error = false}) {
    if (context.mounted) {
      error
          ? showFahErrorSnack(context, message)
          : showFahSnack(context, message);
    }
    debugPrint('[AIIN web] $message');
  }

  if (!context.mounted) return false;
  // The HOSTED AIIN sign-in page runs the whole round-trip (all
  // providers, silent for an existing session) — the popup goes straight
  // to it. A timeout/cancel falls back to the paste-key path.
  final coordinator = AiinWebAuthCoordinator.instance;
  final result = await coordinator.connect(
    onStatus: webStatus,
    client: aiinHttpClient,
    openFn: aiinOpenPopupFn,
    navigateFn: aiinNavigatePopupFn,
    timeout: aiinWebTimeout,
  );
  if (result == null) {
    final failure = coordinator.lastFailure ?? '';
    // Only a timeout/cancel falls back to paste; other failures abort.
    if (failure != 'timeout' && failure != 'cancelled') return false;
  }
  if (!context.mounted) return false;
  return _completeAiinConnect(
    context,
    registry: registry,
    service: service,
    lastConnectionStore: lastConnectionStore,
    sessionKeysStore: sessionKeysStore,
    keychainStore: keychainStore,
    result: result,
    aiinModelsFetcher: aiinModelsFetcher,
    reauthenticateFor: reauthenticateFor,
  );
}

/// The desktop branch (issue #486): the browser/CLI sign-in round-trip,
/// with the cabinet paste-key fallback when it fails.
Future<bool> _runAiinDesktopConnect(
  BuildContext context, {
  required ProviderRegistry registry,
  required AgentService? service,
  required LastConnectionStore lastConnectionStore,
  required SessionKeysStore? sessionKeysStore,
  required SessionKeysStore? fallbackKeys,
  required KeychainStore? keychainStore,
  Future<AiinConnectResult?> Function()? aiinConnectFn,
  Future<List<String>> Function(String baseUrl, {required String apiKey})?
  aiinModelsFetcher,
  CustomProvider? reauthenticateFor,
}) async {
  if (!context.mounted) return false;
  showFahSnack(
    context,
    'Opening browser for AIIN sign-in…',
    duration: const Duration(seconds: 3),
  );

  // gh-1044 AC2/AC4: the diagnostic bundle behind the visible failure.
  final trace = _AiinFlowTrace();
  final result = aiinConnectFn != null
      ? await aiinConnectFn()
      : await runAiinConnectCliFlow(
          onStatus: (message) {
            debugPrint('[AIIN] $message');
            trace.add(message);
          },
          openBrowserFn: (url) => url_launcher.launchUrl(
            Uri.parse(url),
            mode: url_launcher.LaunchMode.externalApplication,
          ),
        );
  if (!context.mounted) return false;
  return _completeAiinConnect(
    context,
    registry: registry,
    service: service,
    lastConnectionStore: lastConnectionStore,
    sessionKeysStore: sessionKeysStore ?? fallbackKeys,
    keychainStore: keychainStore,
    result: result,
    aiinModelsFetcher: aiinModelsFetcher,
    reauthenticateFor: reauthenticateFor,
    trace: trace,
  );
}

/// The shared tail of every automatic-sign-in branch (web, desktop,
/// mobile): the model-pick finish with the automatic key. The app
/// surfaces (mobile/desktop) own their visible failure BEFORE this tail
/// (gh-1044 I4 — SSO is the only path); [trace] carries their diagnostic
/// bundle. Only the web reference path still completes through the
/// cabinet paste-key fallback ([trace] == null).
Future<bool> _completeAiinConnect(
  BuildContext context, {
  required ProviderRegistry registry,
  required AgentService? service,
  required LastConnectionStore lastConnectionStore,
  required SessionKeysStore? sessionKeysStore,
  required KeychainStore? keychainStore,
  required AiinConnectResult? result,
  required Future<List<String>> Function(
    String baseUrl, {
    required String apiKey,
  })?
  aiinModelsFetcher,
  required CustomProvider? reauthenticateFor,
  _AiinFlowTrace? trace,
}) async {
  if (result == null) {
    if (trace != null) {
      // Automatic sign-in failed (cancelled, timeout, service error) — a
      // VISIBLE, actionable error state: what happened plus the
      // diagnostic bundle. Never a paste sheet, never a silent exit.
      if (context.mounted) _showAiinSignInError(context, trace);
      return false;
    }
    if (context.mounted) {
      // Web reference behavior (issue #486, untouched by gh-1044): the
      // cabinet + paste-key path still completes the web connect.
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
        aiinModelsFetcher: aiinModelsFetcher,
        reauthenticateFor: reauthenticateFor,
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
    aiinModelsFetcher: aiinModelsFetcher,
    reauthenticateFor: reauthenticateFor,
  );
}

/// The gh-1044 AC4 failure state: what happened plus the AC2 diagnostic
/// bundle. The snack carries a short human reason (never a raw internal
/// status line — those can carry login URLs with OAuth state tokens);
/// the full trace stays answerable from the log alone.
void _showAiinSignInError(BuildContext context, _AiinFlowTrace trace) {
  // hideCurrent: the flow's own progress snack ('Opening AIIN sign-in…')
  // would otherwise queue the failure behind it for its full 4 s duration —
  // the visible error state (gh-1044 AC4) must surface immediately.
  showFahErrorSnack(
    context,
    aiinSignInFailureMessage(trace.lastOutcome),
    hideCurrent: true,
  );
  debugPrint('[AIIN] flow trace: ${trace.summary}');
}

/// Maps a flow's last status line to the short visible failure message
/// (gh-1044 AC4). The internal status lines are log-grade — some embed
/// the login URL with its OAuth state token — so the snack only ever
/// shows a mapped, human reason, and the full trace stays in the debug
/// log where [runAiinMobileConnect] already prints it.
@visibleForTesting
String aiinSignInFailureMessage(String lastOutcome) {
  final outcome = lastOutcome.toLowerCase();
  // A deliberate user cancel is not an error to retry — no "try again".
  if (outcome.contains('user cancel')) {
    return '$_aiinSignInFailedMessage — the sign-in was cancelled.';
  }
  if (outcome.contains('could not start') ||
      outcome.contains('is unavailable on this host')) {
    return '$_aiinSignInFailedMessage — the system sign-in sheet could '
        'not start. Try again.';
  }
  // The headless/launch-failure status embeds the full login URL (with
  // its OAuth state token) — never surface that raw.
  if (outcome.contains('could not open browser') ||
      outcome.contains('open this url manually') ||
      outcome.contains('could not be opened')) {
    return '$_aiinSignInFailedMessage — the sign-in page could not be '
        'opened. Try again.';
  }
  if (outcome.contains('timed out') || outcome.contains('timeout')) {
    return '$_aiinSignInFailedMessage — the sign-in timed out. Try again.';
  }
  return '$_aiinSignInFailedMessage. Try again.';
}

/// The gh-1044 AC4 visible-failure headline (SSO is the only path).
const _aiinSignInFailedMessage = 'AIIN sign-in did not complete';

/// The gh-1044 AC2/AC4 diagnostic bundle: the flow's status lines plus
/// the sheet resolution, answerable from the log alone and surfaced in
/// the visible failure state.
final class _AiinFlowTrace {
  final List<String> _events = [];

  void add(String event) => _events.add(event);

  /// The last recorded outcome — the one-line reason for the failure.
  String get lastOutcome =>
      _events.isEmpty ? 'the sign-in did not complete' : _events.last;

  String get summary => _events.join(' | ');
}

/// Opens [url] in the iOS auth-session sheet and RETURNS the callback
/// URL the native scheme interception caught (gh-1044 AC9):
/// `callbackScheme: 'http'` makes `ASWebAuthenticationSession` intercept
/// the `http://127.0.0.1:<port>/callback` redirect and hand it back to
/// Dart, so completion never depends on the redirect physically loading
/// the loopback server inside the sheet. Interception matches the
/// redirect's SCHEME only (the host plays no role); the mechanism is
/// Apple-deprecated for `http`, so the loopback server stays armed as the
/// fallback leg for the day interception stops firing. Resolves `null`
/// when the sheet closed without a callback (user cancel) — a visible
/// error for the caller, never a fallback. A sheet that cannot even
/// start throws — the mobile flow surfaces it as the failure state.
Future<String?> _openAiinAuthSession(String url) {
  debugPrint('[AIIN mobile] opening the sign-in sheet (callbackScheme: http)');
  return systemAuthSessionChannel
      .invokeMethod<String>('authenticate', {
        'url': url,
        'callbackScheme': 'http',
      })
      .then((callbackUrl) {
        debugPrint(
          '[AIIN mobile] sign-in sheet resolved; callbackUrl='
          '${callbackUrl == null ? 'none (cancelled)' : 'returned'}',
        );
        return callbackUrl;
      });
}

/// Dismisses the active auth-session sheet (the callback landed on the
/// flow's loopback server). Best-effort: the sheet may already be gone.
Future<void> _dismissAiinAuthSession() async {
  try {
    await systemAuthSessionChannel.invokeMethod<void>('cancel');
  } on Object {
    // The sheet was never opened or is already dismissed.
  }
}

/// The mobile browser branch (issue #976): the SAME loopback CLI flow as
/// desktop, opened in the platform browser surface. iOS the
/// `ASWebAuthenticationSession` system sheet — it shares Safari's cookies
/// and passkey support, and Google refuses OAuth inside embedded WebViews.
/// gh-1044 AC9: the sheet is driven with `callbackScheme: 'http'` — the
/// native scheme interception catches the `http://127.0.0.1:<port>/callback`
/// redirect and returns it to the flow (the intercepted leg), while the
/// loopback server stays armed as the fallback leg for the surfaces that
/// navigate the redirect for real (dismissed via [_dismissAiinAuthSession];
/// interception is Apple-deprecated for `http`). The redirect advertises
/// `127.0.0.1` on every surface — scheme interception ignores the host,
/// and the literal loopback address always reaches the server's IPv4
/// bind (a `localhost` label could resolve to `::1`). Android the
/// external browser, whose redirect reaches the on-device server
/// directly. Public step seam (the #476 recipe): VM tests drive this
/// with an iOS platform override and a mocked channel.
Future<bool> runAiinMobileConnect({
  required BuildContext context,
  required ProviderRegistry registry,
  required AgentService? service,
  required LastConnectionStore lastConnectionStore,
  SessionKeysStore? sessionKeysStore,
  KeychainStore? keychainStore,
  Future<AiinConnectResult?> Function()? aiinConnectFn,
  http.Client? aiinHttpClient,
  Future<List<String>> Function(String baseUrl, {required String apiKey})?
  aiinModelsFetcher,
  CustomProvider? reauthenticateFor,
}) async {
  if (!context.mounted) return false;
  showFahSnack(
    context,
    'Opening AIIN sign-in…',
    duration: const Duration(seconds: 3),
  );

  final authSession = defaultTargetPlatform == TargetPlatform.iOS;
  // The sheet's completion value rides this completer: the same
  // `authenticate` call that opens the sheet resolves with the intercepted
  // callback URL (or null on a user cancel). It is the sheet's SINGLE
  // completion channel — the flow's cancel (null) and success (URL) both
  // ride it; the flow never treats the open future's bool as a second
  // cancel signal, because an async `return` completes its future
  // synchronously while `Completer.complete` defers to a later microtask
  // (an open-settle cancel evaluated in that cascade would always steal
  // the race from an intercepted URL queued one microtask earlier).
  final intercepted = authSession ? Completer<String?>() : null;
  // gh-1044 AC2/AC4: the diagnostic bundle behind the visible failure.
  final trace = _AiinFlowTrace();
  AiinConnectResult? result;
  try {
    result = aiinConnectFn != null
        ? await aiinConnectFn()
        : await runAiinConnectCliFlow(
            onStatus: (message) {
              debugPrint('[AIIN mobile] $message');
              trace.add(message);
            },
            client: aiinHttpClient,
            // The redirect advertises the literal loopback address on
            // every surface: interception is scheme-based (host plays no
            // role) and the fallback leg needs an address that reaches
            // the server's IPv4 loopback bind without resolver ambiguity
            // (`localhost` may answer `::1`).
            openBrowserFn: authSession
                ? (url) async {
                    final callbackUrl = await _openAiinAuthSession(url);
                    if (intercepted != null && !intercepted.isCompleted) {
                      intercepted.complete(callbackUrl);
                    }
                    return true;
                  }
                : (url) => url_launcher.launchUrl(
                    Uri.parse(url),
                    mode: url_launcher.LaunchMode.externalApplication,
                  ),
            interceptedCallback: intercepted == null
                ? null
                : () => intercepted.future,
            onCallback: authSession ? _dismissAiinAuthSession : null,
            // The iOS sheet resolving without a callback is a user
            // cancel — surface the failure immediately instead of
            // waiting out the callback timeout; the timeout there only
            // guards a stalled network, so it stays at the desktop
            // default. The external Android browser gives no cancel
            // signal — its 3 minute bound is the abandonment protection.
            cancelWhenOpenSettles: authSession,
            timeout: Duration(minutes: authSession ? 5 : 3),
          );
  } on AiinSurfaceClosedException {
    // The sheet closed without a callback — user cancel.
    result = null;
  } on PlatformException catch (error) {
    // The auth session could not start (no presentation context).
    result = null;
    trace.add('the system sign-in sheet could not start (${error.code})');
  } on MissingPluginException {
    // The native channel is missing (stale host).
    result = null;
    trace.add('the system sign-in sheet is unavailable on this host');
  }
  if (!context.mounted) return false;
  return _completeAiinConnect(
    context,
    registry: registry,
    service: service,
    lastConnectionStore: lastConnectionStore,
    sessionKeysStore: sessionKeysStore,
    keychainStore: keychainStore,
    result: result,
    aiinModelsFetcher: aiinModelsFetcher,
    reauthenticateFor: reauthenticateFor,
    trace: trace,
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
  Future<List<String>> Function(String baseUrl, {required String apiKey})?
  aiinModelsFetcher,

  /// Re-auth mode (see [runAiinConnectFlow]): refresh the existing entry's
  /// key and reconnect on its saved model — no model pick, no new entry.
  CustomProvider? reauthenticateFor,
}) async {
  final key = apiKey;
  // Re-auth mode: refresh the stored key on the existing entry (keeps its
  // name/model), persist like the connect flow does, and reconnect on the
  // saved model — no model pick, no new entry.
  if (reauthenticateFor case final existing?) {
    registry.rememberKey(existing.id, key);
    final keyName = CustomProviderRegistry.keyNameFor(
      existing.baseUrl,
      providerName: existing.name,
    );
    var persisted = false;
    final keychain = keychainStore ?? const KeychainStore();
    if (await keychain.isAvailable()) {
      persisted = await keychain.set(keyName, key);
    }
    if (!persisted) {
      await sessionKeysStore?.set(keyName, key);
    }
    final config = AgentConfig(
      providerKind: 'aiin',
      modelId: existing.modelId,
      baseUrl: existing.baseUrl,
      apiKey: key,
    );
    if (service != null) {
      await service.reconfigure(config, fromProviderAddFlow: true);
    }
    await lastConnectionStore.saveFromConfig(config);
    return true;
  }
  // ── Pick a model (public /v1/models on api.aiin.by) ─────────────────
  const baseUrl = aiinDefaultChatBaseUrl;
  List<String> models = const [];
  try {
    models = aiinModelsFetcher != null
        ? await aiinModelsFetcher(baseUrl, apiKey: key)
        : (await fetchModelsForEndpoint(baseUrl, apiKey: key)).$1;
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
  if (service != null) {
    await service.reconfigure(config, fromProviderAddFlow: true);
  }
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

/// The WEB reference path's fallback (issue #486 — untouched by
/// gh-1044): open the AIIN cabinet, let the user create a key, and paste
/// it here. Returns the key or null on cancel. The app surfaces (mobile,
/// desktop) do NOT reach this — their failed sign-in is a visible error
/// (gh-1044 I4: honest SSO, no key-paste fallback).
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
            'The automatic sign-in did not complete. '
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
            onChanged: (value) =>
                setState(() => _valid = isValidAiinApiKey(value)),
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

/// The app-side default chat endpoint of the AIIN provider (the catalog
/// spec's default base URL).
class _AiinModelPickerPage extends StatefulWidget {
  const _AiinModelPickerPage({required this.models});

  final List<String> models;

  @override
  State<_AiinModelPickerPage> createState() => _AiinModelPickerPageState();
}

class _AiinModelPickerPageState extends State<_AiinModelPickerPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final models = widget.models;
    return Scaffold(
      appBar: AppBar(title: const Text('AIIN model')),
      body: SafeArea(
        child: models.isEmpty
            ? const _AiinManualModelEntry()
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: TextField(
                      autofocus: true,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Filter models…',
                      ),
                      onChanged: (value) =>
                          setState(() => _query = value.trim().toLowerCase()),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _query.isEmpty
                            ? '${models.length} models'
                            : '${_filtered(models).length} of ${models.length}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                  Expanded(child: _AiinModelList(models: _filtered(models))),
                ],
              ),
      ),
    );
  }

  List<String> _filtered(List<String> models) => _query.isEmpty
      ? models
      : models
            .where((id) => id.toLowerCase().contains(_query))
            .toList(growable: false);
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

// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be
// found in the LICENSE file.

/// The `/oauth/callback` page's postMessage/BroadcastChannel hand-off
/// (issue #1117): the popup that completes the provider sign-in delivers
/// the grant to the app instead of relying solely on the opener's
/// same-origin location poll — that poll cannot read the popup whenever
/// the app runs cross-origin (browser-extension / Office pane embeds) or
/// its timers are throttled, and then the code died on the callback page.
///
/// Pure decoding/building only — the browser seams (window.onMessage,
/// BroadcastChannel) stay in `auth_loopback_web.dart`, so this file is
/// unit-testable on the VM.
library;

import 'production_origins.dart';

/// `type` marker every `/oauth/callback` hand-off message carries.
const faOAuthMessageType = 'fa_oauth_code';

/// BroadcastChannel name paired with [faOAuthMessageType].
const faOAuthBroadcastChannel = 'fa_oauth';

/// The localStorage key the callback page writes its last-resort
/// hand-off into — pairs with the page's
/// `localStorage.setItem('fa_oauth_code', …)` (same JS/Dart split as
/// [faOAuthBroadcastChannel]: JS cannot share the Dart symbol, keep the
/// literals in sync). The AIIN callback flow uses its own disjoint key
/// (`aiin_oauth_code`).
const faOAuthStorageKey = 'fa_oauth_code';

/// How far back the app's localStorage hand-off consumer accepts a
/// stored grant (mirrors the AIIN page's freshness window): a stale
/// entry must never complete a later flow.
const oauthCallbackStorageMaxAgeMs = 90000;

/// One delivered grant message from the callback page. All fields except
/// [type] mirror the callback URL's query parameters.
final class OAuthCallbackMessage {
  const OAuthCallbackMessage({
    required this.code,
    required this.state,
    required this.error,
    required this.errorDescription,
  });

  /// The temporary authorization code (null on a provider error).
  final String? code;

  /// The CSRF state echoed from the authorization URL.
  final String? state;

  /// The provider's `error` parameter, if any.
  final String? error;

  /// The provider's `error_description` parameter, if any.
  final String? errorDescription;

  /// Whether the message can complete a flow at all: a code or an
  /// explicit provider error must be present.
  bool get isCompletable =>
      (code != null && code!.isNotEmpty) || (error != null && error!.isNotEmpty);

  /// Whether the message may complete a flow that initiated with
  /// [expectedState]: a null expectation (the auth URL carried no state)
  /// stays ungated, otherwise the echoed state must match — a forged or
  /// stale hand-off for another flow is ignored instead of failing the
  /// live one with a confusing state-mismatch error.
  bool matchesExpectedState(String? expectedState) =>
      expectedState == null || state == expectedState;

  /// The callback URI [code]/[state]/[error]… resolve through — the same
  /// `{origin}/oauth/callback?code=…&state=…` shape the desktop loopback
  /// and the same-origin poll deliver, so `NetworkAuthFlow` consumes all
  /// three paths identically (state check, error surfacing, exchange).
  Uri toUri(String origin) {
    final base = Uri.parse('$origin/oauth/callback');
    return base.replace(
      queryParameters: {
        if (code != null && code!.isNotEmpty) 'code': code,
        if (state != null && state!.isNotEmpty) 'state': state,
        if (error != null && error!.isNotEmpty) 'error': error,
        if (errorDescription != null && errorDescription!.isNotEmpty)
          'error_description': errorDescription,
      },
    );
  }
}

/// Decodes a postMessage/BroadcastChannel payload into an
/// [OAuthCallbackMessage]; null when [data] is not a network-auth hand-off
/// (foreign messages share `window.onMessage`). JS objects arrive from
/// dart2js as native objects, not Dart Maps — index dynamically like
/// `aiin_oauth_web_impl.dart` does.
OAuthCallbackMessage? decodeOAuthCallbackMessage(Object? data) {
  if (data == null) return null;
  String type;
  String? code;
  String? state;
  String? error;
  String? errorDescription;
  try {
    final dynamic js = data;
    type = js['type'] as String? ?? '';
    code = js['code'] as String?;
    state = js['state'] as String?;
    error = js['error'] as String?;
    errorDescription = js['error_description'] as String?;
  } on Object {
    return null;
  }
  if (type != faOAuthMessageType) return null;
  final message = OAuthCallbackMessage(
    code: code,
    state: state,
    error: error,
    errorDescription: errorDescription,
  );
  return message.isCompletable ? message : null;
}

/// Whether a hand-off message posted from [origin] may complete the
/// flow started by an app served from [ownOrigin]: the production
/// callback page (cross-origin openers — extension/Office pane embeds)
/// or the app's own origin (same-origin deploys, local dev).
bool isTrustedCallbackOrigin(String origin, String ownOrigin) =>
    origin == productionSiteOrigin || origin == ownOrigin;

/// Decodes the localStorage hand-off the callback page writes as a
/// last-resort channel (key [faOAuthStorageKey], a JSON payload): same rules
/// as [decodeOAuthCallbackMessage] plus a freshness window of
/// [maxAgeMs] against [nowMs] via the payload's `ts` — a stale entry
/// (this or a previous browser session) must never complete a flow.
OAuthCallbackMessage? oauthCallbackFromStorage(
  Object? decoded,
  int nowMs, {
  int maxAgeMs = oauthCallbackStorageMaxAgeMs,
}) {
  final message = decodeOAuthCallbackMessage(decoded);
  if (message == null) return null;
  final dynamic anyMap = decoded;
  final dynamic ts = anyMap['ts'];
  if (ts is! int && ts is! num) return null;
  if (nowMs - ts > maxAgeMs || ts > nowMs) return null;
  return message;
}

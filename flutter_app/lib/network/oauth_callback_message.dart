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

/// `type` marker every `/oauth/callback` hand-off message carries.
const faOAuthMessageType = 'fa_oauth_code';

/// BroadcastChannel name paired with [faOAuthMessageType].
const faOAuthBroadcastChannel = 'fa_oauth';

/// Origin of the production callback page. The ai-native auth service
/// redirects the popup there regardless of where the app is embedded
/// (see aiin_web_auth.dart for the same constant in the AIIN flow), so a
/// cross-origin opener must trust messages posted from it.
const faOAuthSiteOrigin = 'https://fa1.dev';

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
    origin == faOAuthSiteOrigin || origin == ownOrigin;

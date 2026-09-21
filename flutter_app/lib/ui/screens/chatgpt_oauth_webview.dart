// l10n:ignore-file - OAuth flow screens - en-only by design

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:fa/services/analytics.dart';
import 'package:fa/ui/screens/oauth_webview_scaffold.dart';

/// The loopback redirect decision for [url] (issue #773): a hit to
/// `<loopback>/auth/callback` is auth.openai.com bouncing the
/// authorization code back — the callback port is never bound, so that
/// navigation is always prevented. A `code` + matching [expectedState]
/// hands the code to [onCode]; an OAuth `error` param or a `state`
/// mismatch surfaces a named message via [onError] (the user can retry
/// through the still-open authorize page). Everything else — including a
/// partial callback and an unparseable URL — navigates normally.
@visibleForTesting
NavigationDecision chatGptNavigationDecision(
  String url, {
  required String expectedState,
  void Function(String code)? onCode,
  void Function(String message)? onError,
}) {
  final uri = Uri.tryParse(url);
  if (uri == null) return NavigationDecision.navigate;
  final host = uri.host;
  if (host != 'localhost' && host != '127.0.0.1') {
    return NavigationDecision.navigate;
  }
  if (uri.path != '/auth/callback') return NavigationDecision.navigate;
  final error = uri.queryParameters['error'];
  if (error != null && error.isNotEmpty) {
    final description = uri.queryParameters['error_description'];
    onError?.call(
      'ChatGPT sign-in failed: $error'
      '${description == null || description.isEmpty ? '' : ' ($description)'}',
    );
    return NavigationDecision.prevent;
  }
  final code = uri.queryParameters['code'];
  final state = uri.queryParameters['state'];
  if (code == null || code.isEmpty || state == null || state.isEmpty) {
    // Not a callback we can act on; let the WebView show what the host
    // served (an unbound port fails loudly, which is honest).
    return NavigationDecision.navigate;
  }
  if (state != expectedState) {
    onError?.call(
      'ChatGPT sign-in failed: state mismatch — this callback does not '
      'belong to the current sign-in attempt.',
    );
    return NavigationDecision.prevent;
  }
  onCode?.call(code);
  return NavigationDecision.prevent;
}

/// The named message for Google's embedded-WebView OAuth block (issue #773
/// E3): Google refuses OAuth inside WKWebView-class browsers ("This browser
/// or app may not be secure" / `disallowed_useragent`). Null when the page
/// text does not match the block.
///
/// Best-effort by nature: the phrases are Google's **English** copy, so a
/// localized block page (the interstitial follows the Google account
/// locale, not the app locale) does not match and the user hits the raw
/// wall instead of the named banner. `disallowed_useragent` still fires on
/// every locale (it is a debug/code string in the served HTML). The banner
/// itself never blocks anything — password sign-in stays available either
/// way — so this stays an English-sniff heuristic rather than a locale
/// matrix.
@visibleForTesting
String? chatGptGoogleBlockMessage(String pageText) =>
    pageText.contains('may not be secure') ||
        pageText.contains('disallowed_useragent')
    ? 'Google blocks sign-in inside the in-app browser. Sign in with your '
          'ChatGPT email and password instead, or use the desktop app for '
          'Google sign-in.'
    : null;

/// Best-effort detection of Google's embedded-WebView OAuth block (E3):
/// the block page has no distinctive URL, only body text.
Future<void> _sniffGoogleBlock(OAuthWebViewOps<String> ops) async {
  try {
    final body = await ops.controller.runJavaScriptReturningResult(
      "(document.body && document.body.innerText) || ''",
    );
    final message = chatGptGoogleBlockMessage(body.toString());
    if (message != null) ops.showError(message);
  } on Object {
    // The sniff is cosmetic; a platform quirk must not break the flow.
  }
}

/// A full-screen WebView that walks the user through the ChatGPT (Codex
/// OAuth client) sign-in and intercepts the loopback redirect — the
/// mobile counterpart of the desktop local callback server (issue #773).
///
/// The authorize URL is built by the flow from the harness PKCE functions
/// with a loopback-shaped `redirect_uri`
/// (`http://localhost:<port>/auth/callback`); the port is never bound. The
/// [NavigationDelegate] intercepts the redirect inside the WebView and
/// extracts the `code` (state-validated) before the navigation happens.
///
/// Pops with the authorization `code` on success, or `null` when the user
/// cancels or the flow times out. A Google-SSO-only account hits the
/// embedded-WebView block (E3), surfaced as a named banner instead of an
/// infinite spinner.
class ChatGptOAuthWebViewPage extends StatefulWidget {
  /// Creates the OAuth page.
  const ChatGptOAuthWebViewPage({
    super.key,
    required this.authorizeUrl,
    required this.expectedState,
    this.timeout = const Duration(minutes: 5),
  });

  /// The PKCE authorize URL on auth.openai.com.
  final String authorizeUrl;

  /// The `state` the flow generated; callbacks carrying another one are
  /// rejected with a named banner.
  final String expectedState;

  /// How long to wait before giving up (the user may be slow on the login
  /// page). Defaults to 5 minutes.
  final Duration timeout;

  @override
  State<ChatGptOAuthWebViewPage> createState() =>
      _ChatGptOAuthWebViewPageState();
}

class _ChatGptOAuthWebViewPageState extends State<ChatGptOAuthWebViewPage> {
  @override
  void initState() {
    super.initState();
    AppAnalytics.instance.screenOpened('chatgpt_signin');
  }

  @override
  Widget build(BuildContext context) {
    return OAuthWebViewScaffold<String>(
      title: 'ChatGPT Sign In', // l10n:ignore — proper noun
      initialUrl: widget.authorizeUrl,
      timeout: widget.timeout,
      onNavigationRequest: (request, ops) => chatGptNavigationDecision(
        request.url,
        expectedState: widget.expectedState,
        onCode: ops.popWith,
        onError: ops.showError,
      ),
      onPageFinished: (url, ops) => _sniffGoogleBlock(ops),
    );
  }
}

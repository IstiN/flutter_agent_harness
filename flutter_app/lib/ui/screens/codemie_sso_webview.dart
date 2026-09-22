import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:fa/services/codemie_sso_flow_steps.dart';
import 'package:fa/ui/screens/oauth_webview_scaffold.dart';

/// The SSO callback redirect decision for [url]: any localhost/loopback
/// hit is the CodeMie backend bouncing the token back — hand a non-empty
/// token to [onToken] and prevent the navigation (no server listens
/// there); everything else (including an unparseable URL) navigates.
@visibleForTesting
NavigationDecision codeMieNavigationDecision(
  String url, {
  void Function(String token)? onToken,
}) {
  final uri = Uri.tryParse(url);
  if (uri == null) return NavigationDecision.navigate;
  final host = uri.host;
  if (host != 'localhost' && host != '127.0.0.1') {
    return NavigationDecision.navigate;
  }
  final token = uri.queryParameters['token'];
  if (token != null && token.isNotEmpty) onToken?.call(token);
  return NavigationDecision.prevent;
}

/// A dummy callback port baked into the SSO login URL. We never bind it —
/// the redirect is intercepted by the NavigationDelegate. Any non-privileged
/// port works; a fixed value keeps the URL predictable.
const _dummyPort = 48127;

/// A full-screen WebView that walks the user through the CodeMie SSO login
/// and intercepts the `http://localhost:<port>/?token=...` redirect.
///
/// CodeMie's SSO bakes the callback **port** into the login URL
/// (`/v1/auth/login/<port>`). After the user authenticates, the backend
/// redirects the browser to `http://localhost:<port>/?token=<base64>`. We
/// never bind that port — the [NavigationDelegate] intercepts the redirect
/// inside the WebView and extracts the token before the navigation happens.
///
/// Pops with [CodeMieSsoCredentials] on success, or `null` when the user
/// cancels / the flow times out.
class CodeMieSsoWebViewPage extends StatelessWidget {
  /// Creates the SSO page.
  const CodeMieSsoWebViewPage({
    super.key,
    required this.orgUrl,
    this.timeout = const Duration(minutes: 5),
  });

  /// The CodeMie organization URL (e.g. `https://codemie.lab.epam.com`).
  final String orgUrl;

  /// How long to wait before giving up (the user may be slow on the SSO
  /// page). Defaults to 5 minutes.
  final Duration timeout;

  @override
  Widget build(BuildContext context) {
    return OAuthWebViewScaffold<CodeMieSsoCredentials>(
      title:
          'CodeMie Sign In', // l10n:ignore — proper noun, fallback-only screen
      initialUrl: buildCodeMieSsoUrl(orgUrl, _dummyPort),
      timeout: timeout,
      onNavigationRequest: (request, ops) => codeMieNavigationDecision(
        request.url,
        onToken: (rawToken) {
          try {
            ops.popWith(decodeCodeMieSsoCredentials(rawToken, orgUrl));
          } on Object catch (e) {
            // The token never decodes: surface the error and re-arm the
            // flow (the user may retry through the SSO host).
            ops.showError('Failed to decode SSO token: $e');
          }
        },
      ),
    );
  }
}

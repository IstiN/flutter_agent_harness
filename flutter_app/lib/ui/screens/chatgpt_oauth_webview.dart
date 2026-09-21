import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';

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
@visibleForTesting
String? chatGptGoogleBlockMessage(String pageText) =>
    pageText.contains('may not be secure') ||
        pageText.contains('disallowed_useragent')
    ? 'Google blocks sign-in inside the in-app browser. Sign in with your '
          'ChatGPT email and password instead, or use the desktop app for '
          'Google sign-in.'
    : null;

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
  late final WebViewController _controller;
  var _loading = true;
  var _errorMessage = '';
  Timer? _timeoutTimer;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _controller = _createController();
    _timeoutTimer = Timer(widget.timeout, _onTimeout);
  }

  /// Builds the WebView controller: unrestricted JS, the navigation
  /// delegate (loopback-callback interception, loading/error surfacing,
  /// the Google-block sniff) and the authorize URL load.
  WebViewController _createController() {
    final authorizeUrl = widget.authorizeUrl;
    return WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigationRequest,
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: _onPageFinished,
          onWebResourceError: (error) {
            // Ignore sub-frame errors (ads, favicons); only surface
            // main-frame failures that would leave the user stuck.
            if (error.isForMainFrame == true && mounted) {
              setState(() => _errorMessage = error.description);
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(authorizeUrl));
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  NavigationDecision _onNavigationRequest(NavigationRequest request) =>
      chatGptNavigationDecision(
        request.url,
        expectedState: widget.expectedState,
        onCode: _completeWithCode,
        onError: _showError,
      );

  /// Best-effort detection of Google's embedded-WebView OAuth block (E3):
  /// the block page has no distinctive URL, only body text.
  Future<void> _onPageFinished(String url) async {
    if (mounted) setState(() => _loading = false);
    if (_completed || !mounted) return;
    try {
      final body = await _controller.runJavaScriptReturningResult(
        "(document.body && document.body.innerText) || ''",
      );
      final message = chatGptGoogleBlockMessage(body.toString());
      if (message != null && mounted && !_completed) {
        setState(() => _errorMessage = message);
      }
    } on Object {
      // The sniff is cosmetic; a platform quirk must not break the flow.
    }
  }

  void _showError(String message) {
    if (mounted && !_completed) setState(() => _errorMessage = message);
  }

  Future<void> _completeWithCode(String code) async {
    if (_completed) return;
    _completed = true;
    _timeoutTimer?.cancel();
    if (mounted) Navigator.of(context).pop(code);
  }

  void _onTimeout() {
    if (!_completed && mounted) {
      _completed = true;
      Navigator.of(context).pop(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: faAppBar(
        title: const Text(
          'ChatGPT Sign In',
        ), // l10n:ignore — proper noun, fallback-only screen
        actions: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_errorMessage.isNotEmpty)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(12),
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _errorMessage,
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

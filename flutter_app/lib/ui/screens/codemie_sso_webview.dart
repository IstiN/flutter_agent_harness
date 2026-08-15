import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

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
class CodeMieSsoWebViewPage extends StatefulWidget {
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
  State<CodeMieSsoWebViewPage> createState() => _CodeMieSsoWebViewPageState();
}

class _CodeMieSsoWebViewPageState extends State<CodeMieSsoWebViewPage> {
  late final WebViewController _controller;
  var _loading = true;
  var _errorMessage = '';
  Timer? _timeoutTimer;
  bool _completed = false;

  /// A dummy callback port baked into the SSO login URL. We never bind it —
  /// the redirect is intercepted by the NavigationDelegate. Any non-privileged
  /// port works; a fixed value keeps the URL predictable.
  static const _dummyPort = 48127;

  @override
  void initState() {
    super.initState();
    final ssoUrl = buildCodeMieSsoUrl(widget.orgUrl, _dummyPort);
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigationRequest,
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            // Ignore sub-frame errors (ads, favicons); only surface main-frame
            // failures that would leave the user stuck.
            if (error.isForMainFrame == true && mounted) {
              setState(() => _errorMessage = error.description);
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(ssoUrl));

    _timeoutTimer = Timer(widget.timeout, _onTimeout);
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    if (uri != null && (uri.host == 'localhost' || uri.host == '127.0.0.1')) {
      // This is the callback redirect — extract the token and finish.
      final token = uri.queryParameters['token'];
      if (token != null && token.isNotEmpty) {
        _completeWithToken(token);
      }
      // Prevent the WebView from actually navigating to localhost (there is
      // no server listening).
      return NavigationDecision.prevent;
    }
    return NavigationDecision.navigate;
  }

  Future<void> _completeWithToken(String rawToken) async {
    if (_completed) return;
    _completed = true;
    _timeoutTimer?.cancel();
    try {
      final cookies = decodeCodeMieSsoToken(rawToken);
      final apiBase = codeMieApiBase(widget.orgUrl);
      final credentials = CodeMieSsoCredentials(
        cookies: cookies,
        apiUrl: apiBase,
        expiresAt: deriveCodeMieExpiresAt(cookies),
      );
      if (mounted) Navigator.of(context).pop(credentials);
    } on Object catch (e) {
      if (mounted) {
        setState(() => _errorMessage = 'Failed to decode SSO token: $e');
        _completed = false;
      }
    }
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
      appBar: AppBar(
        title: const Text('CodeMie Sign In'), // l10n:ignore — proper noun, fallback-only screen
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

// l10n:ignore-file - OAuth/SSO flow screens - en-only by design

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';

/// The flow's handle on the [OAuthWebViewScaffold]: complete the flow by
/// popping the payload, surface a named error, or read the page DOM.
abstract final class OAuthWebViewOps<T> {
  /// The page's controller (e.g. to sniff the rendered body text).
  WebViewController get controller;

  /// Completes the flow exactly once: cancels the timeout and pops with
  /// [value] (the route's popped future carries it to the caller).
  void popWith(T value);

  /// Shows the named-error banner. The banner clears on the next page
  /// start — a fresh navigation re-arms the flow.
  void showError(String message);
}

/// Shared full-screen WebView for the hosted OAuth/SSO sign-in pages
/// (the CodeMie SSO fallback, the ChatGPT sign-in - issue #773): walks
/// the user through the hosted login and intercepts the loopback redirect
/// via the injected [OAuthWebViewScaffold.onNavigationRequest] decision -
/// the callback port is never bound.
///
/// Owns the chrome both flows share: the app-bar loading indicator,
/// main-frame-only error surfacing, the named-error banner, the timeout
/// (pops `null`) and the single-pop guard. The per-flow differences - the
/// redirect decision and any post-page work such as the ChatGPT
/// Google-block body sniff - are injected as callbacks.
class OAuthWebViewScaffold<T> extends StatefulWidget {
  /// Creates the scaffold.
  const OAuthWebViewScaffold({
    super.key,
    required this.title,
    required this.initialUrl,
    required this.onNavigationRequest,
    this.onPageFinished,
    this.timeout = const Duration(minutes: 5),
  });

  /// App-bar title (a proper noun for both flows, en-only by design).
  final String title;

  /// The hosted login URL to load (never a bound loopback port).
  final String initialUrl;

  /// The per-flow redirect decision (token vs code interception).
  final NavigationDecision Function(
    NavigationRequest request,
    OAuthWebViewOps<T> ops,
  )
  onNavigationRequest;

  /// Extra per-flow work after a page settles (the loading indicator has
  /// already toggled off), e.g. the ChatGPT Google-block body sniff.
  final Future<void> Function(String url, OAuthWebViewOps<T> ops)?
  onPageFinished;

  /// How long to wait before giving up (the user may be slow on the login
  /// page). Defaults to 5 minutes.
  final Duration timeout;

  @override
  State<OAuthWebViewScaffold<T>> createState() =>
      _OAuthWebViewScaffoldState<T>();
}

class _OAuthWebViewScaffoldState<T> extends State<OAuthWebViewScaffold<T>> {
  late final WebViewController _controller;
  var _loading = true;
  var _errorMessage = '';
  Timer? _timeoutTimer;
  bool _completed = false;
  late final _OAuthWebViewOps<T> _ops = _OAuthWebViewOps<T>(this);

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigationRequest,
          onPageStarted: (url) {
            // A fresh navigation re-arms the flow: clear any stale
            // banner so a retry does not sit under the old error.
            if (mounted) {
              setState(() {
                _loading = true;
                _errorMessage = '';
              });
            }
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
      ..loadRequest(Uri.parse(widget.initialUrl));
    _timeoutTimer = Timer(widget.timeout, _onTimeout);
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  NavigationDecision _onNavigationRequest(NavigationRequest request) =>
      widget.onNavigationRequest(request, _ops);

  Future<void> _onPageFinished(String url) async {
    if (mounted) setState(() => _loading = false);
    await widget.onPageFinished?.call(url, _ops);
  }

  void _onTimeout() {
    if (!_completed && mounted) {
      _completed = true;
      Navigator.of(context).pop();
    }
  }

  /// Completes the flow exactly once on behalf of the flow's ops handle.
  void completeWith(T value) {
    if (_completed) return;
    _completed = true;
    _timeoutTimer?.cancel();
    if (mounted) Navigator.of(context).pop(value);
  }

  /// Shows the named-error banner on behalf of the flow's ops handle.
  void surfaceError(String message) {
    if (mounted && !_completed) {
      setState(() => _errorMessage = message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: faAppBar(
        title: Text(
          widget.title,
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

final class _OAuthWebViewOps<T> implements OAuthWebViewOps<T> {
  _OAuthWebViewOps(this._state);

  final _OAuthWebViewScaffoldState<T> _state;

  @override
  WebViewController get controller => _state._controller;

  @override
  void popWith(T value) => _state.completeWith(value);

  @override
  void showError(String message) => _state.surfaceError(message);
}

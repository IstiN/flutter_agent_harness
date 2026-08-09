// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import 'package:fa/services/openrouter_oauth_callback.dart';
import 'package:fa/services/openrouter_oauth_launch_stub.dart'
    if (dart.library.html) 'package:fa/services/openrouter_oauth_launch_web.dart';

/// Coordinates the OpenRouter OAuth PKCE callback across desktop, mobile, and
/// web builds of the app.
///
/// - **Desktop** (macOS/Windows/Linux): starts a one-shot localhost server,
///   rewrites the authorization URL's `callback_url` to that server, launches
///   the browser, and returns the captured code.
/// - **Mobile** (iOS/Android): launches the browser with
///   `callback_url=<deepLinkScheme>://oauth/openrouter` and waits for a deep
///   link to call [complete].
/// - **Web**: launches the browser with `callback_url=<webCallbackUrl>` and
///   waits for a `postMessage` from that page to call [complete].
///
/// The coordinator is a singleton because the code can arrive through a
/// platform channel or a browser event while the settings sheet that started
/// the flow may already be disposed. Other apps can create non-shared
/// instances with custom [deepLinkScheme] / [webCallbackUrl] to reuse the
/// coordinator without rewriting it.
final class OpenRouterOAuthCoordinator {
  /// Creates a coordinator.
  ///
  /// [deepLinkScheme] is used for mobile deep links
  /// (`<scheme>://oauth/openrouter`).
  /// [webCallbackUrl] is the full page URL used for web `postMessage`
  /// callbacks.
  OpenRouterOAuthCoordinator({
    this.deepLinkScheme = 'fah',
    this.webCallbackUrl = 'https://fa1.dev/oauth/openrouter.html',
  });

  /// The shared coordinator instance with the Fa defaults.
  static final instance = OpenRouterOAuthCoordinator();

  /// Deep-link URL scheme for mobile OAuth callbacks.
  final String deepLinkScheme;

  /// Full web page URL that posts the authorization code back via
  /// `postMessage`.
  final String webCallbackUrl;

  Completer<String?>? _completer;
  OpenRouterOAuthCallbackServer? _server;

  /// The callback URL of the running localhost server, or `null` when no
  /// desktop capture is in progress. Exposed for tests.
  String? get currentCallbackUrl => _server?.callbackUrl;

  /// The platform-appropriate OAuth callback URL, or `null` on desktop where
  /// a localhost server is started lazily by [capture].
  String? get platformCallbackUrl {
    if (kIsWeb) return webCallbackUrl;
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) return null;
    return '$deepLinkScheme://oauth/openrouter';
  }

  /// Launches [authUrl] and waits for the authorization code.
  ///
  /// On desktop the `callback_url` query parameter is replaced with the local
  /// server URL. On mobile and web [authUrl] is launched as-is (the caller
  /// should already include [platformCallbackUrl] as `callback_url`).
  ///
  /// [launchUrl] is injectable for tests; when omitted the real
  /// `package:url_launcher` function is used.
  ///
  /// Returns `null` if the browser could not be launched, the user cancelled,
  /// or the flow timed out.
  Future<String?> capture(
    Uri authUrl, {
    Future<bool> Function(Uri url, {required url_launcher.LaunchMode mode})?
    launchUrl,
  }) async {
    await _reset();
    _completer = Completer<String?>();
    final future = _completer!.future;

    final doLaunch = launchUrl ?? url_launcher.launchUrl;

    if (!kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      _server = OpenRouterOAuthCallbackServer();
      final server = _server!;
      final callbackUrl = await server.start();
      authUrl = authUrl.replace(
        queryParameters: {
          ...authUrl.queryParameters,
          'callback_url': callbackUrl,
        },
      );
      final launched = await doLaunch(
        authUrl,
        mode: url_launcher.LaunchMode.externalApplication,
      );
      if (!launched) {
        await _reset();
        return future;
      }
      final code = await server.waitForCode();
      complete(code);
      await _reset();
      return future;
    }

    final webLaunch = createOpenRouterOAuthLauncher();
    final bool launched;
    if (kIsWeb && webLaunch != null) {
      // Web uses a named popup so that `window.opener` is preserved on the
      // callback page and `postMessage` can deliver the authorization code.
      // `url_launcher`'s `externalApplication` mode opens `_blank`, which
      // browsers treat as `noopener` and leaves `window.opener` null.
      launched = webLaunch(authUrl.toString());
    } else {
      launched = await doLaunch(
        authUrl,
        mode: url_launcher.LaunchMode.externalApplication,
      );
    }
    if (!launched) {
      await _reset();
      return future;
    }
    return future;
  }

  /// Completes an in-flight [capture] with [code] (from a deep link or a web
  /// `postMessage`). Passing `null` means the flow was cancelled or errored.
  void complete(String? code) {
    final c = _completer;
    if (c != null && !c.isCompleted) {
      c.complete(code);
    }
    _completer = null;
    // Close the web OAuth popup once the code has been handed off. On
    // non-web platforms this is a no-op.
    closeOpenRouterOAuthPopup();
  }

  /// Resets any in-flight capture by completing it with `null` and closing the
  /// local server. Exposed for tests.
  Future<void> reset() async {
    final c = _completer;
    if (c != null && !c.isCompleted) c.complete(null);
    _completer = null;
    await _server?.close();
    _server = null;
  }

  Future<void> _reset() async {
    _completer = null;
    await _server?.close();
    _server = null;
  }
}

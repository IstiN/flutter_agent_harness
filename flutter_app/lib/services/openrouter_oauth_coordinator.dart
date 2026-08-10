// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import 'package:fa/services/openrouter_oauth_callback.dart';
import 'package:fa/services/openrouter_oauth_launch_stub.dart'
    if (dart.library.html) 'package:fa/services/openrouter_oauth_launch_web.dart';

/// Coordinates the OpenRouter OAuth PKCE callback across desktop, mobile, and
/// web builds of the app.
///
/// - **Desktop** (Windows/Linux): starts a one-shot localhost server, rewrites
///   the authorization URL's `callback_url` to that server, launches the
///   browser, and returns the captured code.
/// - **iOS/macOS native**: launches the browser with
///   `callback_url=<nativeCallbackUrl>` (an HTTPS page that redirects back to
///   `<deepLinkScheme>://oauth/openrouter`) and waits for the deep link.
/// - **Android native**: launches the browser with
///   `callback_url=<deepLinkScheme>://oauth/openrouter` and waits for the deep
///   link.
/// - **Web**: launches the browser with `callback_url=<webCallbackUrl>` and
///   waits for a `postMessage` from that page to call [complete].
///
/// The coordinator is a singleton because the code can arrive through a
/// platform channel or a browser event while the settings sheet that started
/// the flow may already be disposed. Other apps can create non-shared
/// instances with custom [deepLinkScheme] / [webCallbackUrl] / [nativeCallbackUrl]
/// to reuse the coordinator without rewriting it.
final class OpenRouterOAuthCoordinator {
  /// Creates a coordinator.
  ///
  /// [deepLinkScheme] is used for native-app deep links
  /// (`<scheme>://oauth/openrouter`).
  /// [webCallbackUrl] is the full page URL used for web `postMessage`
  /// callbacks.
  /// [nativeCallbackUrl] is the full HTTPS page URL used for iOS/macOS native
  /// OAuth callbacks; the page redirects to `<deepLinkScheme>://oauth/openrouter`.
  OpenRouterOAuthCoordinator({
    this.deepLinkScheme = 'fah',
    this.webCallbackUrl = 'https://fa1.dev/oauth/openrouter.html',
    this.webAppCallbackUrl = 'https://fa1.dev/app/index.html',
    this.nativeCallbackUrl = 'https://fa1.dev/oauth/openrouter.html?scheme=fah',
  });

  /// The shared coordinator instance with the Fa defaults.
  static final instance = OpenRouterOAuthCoordinator();

  /// Deep-link URL scheme for native OAuth callbacks.
  final String deepLinkScheme;

  /// Full web page URL that posts the authorization code back via
  /// `postMessage`.
  final String webCallbackUrl;

  /// Full app URL used for mobile web/Safari where the popup cannot reliably
  /// post the code back. OpenRouter redirects here with `?code=...&state=...`,
  /// and the app completes the exchange on startup.
  final String webAppCallbackUrl;

  /// Full HTTPS page URL used for iOS/macOS native OAuth callbacks. The page
  /// redirects to `<deepLinkScheme>://oauth/openrouter` so the native app can
  /// receive the authorization code via its registered URL scheme.
  final String nativeCallbackUrl;

  Completer<String?>? _completer;
  OpenRouterOAuthCallbackServer? _server;

  /// The callback URL of the running localhost server, or `null` when no
  /// desktop capture is in progress. Exposed for tests.
  String? get currentCallbackUrl => _server?.callbackUrl;

  /// The platform-appropriate OAuth callback URL, or `null` on desktop where
  /// a localhost server is started lazily by [capture].
  String? get platformCallbackUrl {
    if (kIsWeb) {
      // Mobile Safari and PWAs cannot reliably return data from a popup,
      // so redirect back to the app URL and let the app read the code from
      // the query string on startup.
      final isMobileWeb =
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android;
      return isMobileWeb ? webAppCallbackUrl : webCallbackUrl;
    }
    if (Platform.isWindows || Platform.isLinux) return null;
    if (Platform.isIOS || Platform.isMacOS) return nativeCallbackUrl;
    return '$deepLinkScheme://oauth/openrouter';
  }

  /// Launches [authUrl] and waits for the authorization code.
  ///
  /// On Windows/Linux the `callback_url` query parameter is replaced with the
  /// local server URL. On iOS, macOS, Android, and web [authUrl] is launched
  /// as-is (the caller should already include [platformCallbackUrl] as
  /// `callback_url`).
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

    if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
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

// Copyright (c) 2026, The Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_test/flutter_test.dart';

import 'package:fa/services/provider_auth_surface.dart';

void main() {
  // The full platform sweep UT-1 (issue #861 AC3) runs for BOTH providers.
  for (final provider in ProviderAuthId.values) {
    group('$provider', () {
      test('macOS → system browser + loopback server, no webview fallback', () {
        final surface = resolveProviderAuthSurface(
          provider: provider,
          isMacOS: true,
          isIOS: false,
          isWeb: false,
        );
        expect(surface.primary, ProviderAuthSurfaceKind.systemBrowserLoopback);
        expect(surface.webViewFallback, isFalse);
      });

      test('iOS → system auth session, webview fallback allowed', () {
        final surface = resolveProviderAuthSurface(
          provider: provider,
          isMacOS: false,
          isIOS: true,
          isWeb: false,
        );
        expect(surface.primary, ProviderAuthSurfaceKind.systemAuthSession);
        expect(surface.webViewFallback, isTrue);
      });

      test('web → embedded WebView (degraded, notice applies)', () {
        final surface = resolveProviderAuthSurface(
          provider: provider,
          isMacOS: false,
          isIOS: false,
          isWeb: true,
        );
        expect(surface.primary, ProviderAuthSurfaceKind.embeddedWebView);
        expect(surface.webViewFallback, isFalse);
      });

      test('desktop-others → embedded WebView (degraded, notice applies)', () {
        final surface = resolveProviderAuthSurface(
          provider: provider,
          isMacOS: false,
          isIOS: false,
          isWeb: false,
        );
        expect(surface.primary, ProviderAuthSurfaceKind.embeddedWebView);
        expect(surface.webViewFallback, isFalse);
      });

      test('REG-1 (issue #861): on a passkey-capable platform the embedded '
          'WebView is never the primary surface', () {
        for (final (macos, ios) in [(true, false), (false, true)]) {
          final surface = resolveProviderAuthSurface(
            provider: provider,
            isMacOS: macos,
            isIOS: ios,
            isWeb: false,
          );
          expect(
            surface.primary,
            isNot(ProviderAuthSurfaceKind.embeddedWebView),
            reason:
                'platform macOS=$macos iOS=$ios must not degrade to a '
                'webview primary — an embedded WebView cannot offer '
                'passkeys',
          );
        }
      });

      test('the sessionUnavailable branch degrades to the webview, never '
          'to a silent failure (E2 shape)', () {
        // The iOS row is the only one with a fallback: the session cannot
        // start → the caller must have an in-app WebView escape hatch.
        final surface = resolveProviderAuthSurface(
          provider: provider,
          isMacOS: false,
          isIOS: true,
          isWeb: false,
        );
        expect(
          surface.primary == ProviderAuthSurfaceKind.systemAuthSession,
          surface.webViewFallback,
          reason:
              'the webview fallback exists exactly where the auth '
              'session is primary',
        );
      });
    });
  }

  test('AC3 parity: identical inputs → identical surface for both providers '
      '(rows differ only in credential assembly)', () {
    for (final (macos, ios, web) in [
      (true, false, false),
      (false, true, false),
      (false, false, true),
      (false, false, false),
    ]) {
      final chatgpt = resolveProviderAuthSurface(
        provider: ProviderAuthId.chatgpt,
        isMacOS: macos,
        isIOS: ios,
        isWeb: web,
      );
      final codemie = resolveProviderAuthSurface(
        provider: ProviderAuthId.codemie,
        isMacOS: macos,
        isIOS: ios,
        isWeb: web,
      );
      expect(chatgpt.primary, codemie.primary, reason: 'macos=$macos');
      expect(chatgpt.webViewFallback, codemie.webViewFallback);
    }
  });
}

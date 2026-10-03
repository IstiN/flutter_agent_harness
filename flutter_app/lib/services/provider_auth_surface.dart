// l10n:ignore-file — OAuth flow plumbing — en-only by design

import 'package:flutter/services.dart';

/// Which provider is signing in. The matrix rows are identical for both
/// today (issue #861: ChatGPT/CodeMie parity) — the id keeps the shared
/// surface honest about per-provider divergence if one ever lands, and the
/// AC3 parity test pins that no divergence sneaks in silently.
enum ProviderAuthId { chatgpt, codemie }

/// The sign-in surface a provider's hosted auth page opens on.
enum ProviderAuthSurfaceKind {
  /// Local callback server + system browser (macOS/CLI shape — passkey
  /// capable).
  systemBrowserLoopback,

  /// iOS `ASWebAuthenticationSession` via [systemAuthSessionChannel]
  /// (Safari-grade context — passkey/Face ID capable).
  systemAuthSession,

  /// In-app WebView. NEVER primary on a passkey-capable platform: an
  /// embedded WKWebView cannot offer platform passkeys, so when this
  /// surface runs the user must see the no-passkey notice BEFORE the page
  /// renders (see `OAuthWebViewScaffold.degradedNotice`).
  embeddedWebView,
}

/// The resolved surface for one sign-in attempt.
///
/// [webViewFallback]: the primary surface may degrade to the in-app WebView
/// when it cannot start (`sessionUnavailable` on iOS). The fallback always
/// carries the no-passkey notice.
typedef ProviderAuthSurface = ({
  ProviderAuthSurfaceKind primary,
  bool webViewFallback,
});

/// The ONE platform × provider matrix both sign-in flows resolve
/// (issue #861): identical inputs → identical surface; the
/// providers differ only in their credential assembly, never in the
/// surface choice.
///
/// REG-1 guard: on a passkey-capable platform (macOS, iOS) an embedded
/// WebView is never the primary surface.
///
/// [isWeb] is informational today: both flows refuse the web build BEFORE
/// resolving the matrix (ChatGPT via `_unsupportedMessage` — an
/// iframe-embedded OAuth page is blocked by the provider — CodeMie via its
/// extension branch), so the web row below is the documented target
/// surface if that ever changes, not a branch any current caller reaches.
ProviderAuthSurface resolveProviderAuthSurface({
  required ProviderAuthId provider,
  required bool isMacOS,
  required bool isIOS,
  required bool isWeb,
}) {
  if (isMacOS) {
    return (
      primary: ProviderAuthSurfaceKind.systemBrowserLoopback,
      webViewFallback: false,
    );
  }
  if (isIOS) {
    return (
      primary: ProviderAuthSurfaceKind.systemAuthSession,
      webViewFallback: true,
    );
  }
  // Web and desktop-others: the in-app WebView with the no-passkey
  // notice. (The ChatGPT flow additionally refuses the web build before
  // resolving the matrix — an iframe-embedded OAuth page is blocked by
  // the provider, so refusing stays the honest degradation there.)
  return (
    primary: ProviderAuthSurfaceKind.embeddedWebView,
    webViewFallback: false,
  );
}

/// The method channel driving `ASWebAuthenticationSession` on iOS
/// (implemented in `ios/Runner/AppDelegate.swift`): `authenticate {url}`
/// presents the session (no `callbackScheme` — the loopback redirect loads
/// the app's real callback server, the session future completes only on
/// cancel/dismiss), `cancel` dismisses it.
const MethodChannel systemAuthSessionChannel = MethodChannel(
  'fah/web_auth_session',
);

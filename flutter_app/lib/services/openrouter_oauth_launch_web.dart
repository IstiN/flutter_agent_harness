// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:html' as html;

/// Opens the OpenRouter OAuth authorization page in a named popup window so
/// that `window.opener` is preserved on the callback page. The standard
/// `package:url_launcher` `externalApplication` mode uses `_blank`, which
/// modern browsers treat as `noopener`, breaking `postMessage` back to the Fa
/// web app.
bool _launchOpenRouterOAuth(String url) {
  // A named window (not `_blank`) keeps `window.opener` set on the opened
  // page, allowing `site/oauth/openrouter.html` to call
  // `window.opener.postMessage`. The dimensions are large enough to show the
  // provider UI comfortably without being fullscreen.
  html.window.open(
    url,
    'openrouter_oauth',
    'width=520,height=720,scrollbars=yes,resizable=yes',
  );
  // The dart:html binding reports success/failure through the returned
  // [Window] reference; popup blockers are not surfaced as exceptions here.
  return true;
}

/// Factory selected by the conditional import at the call site.
bool Function(String url)? createOpenRouterOAuthLauncher() =>
    _launchOpenRouterOAuth;

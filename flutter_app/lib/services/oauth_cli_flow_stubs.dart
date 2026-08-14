// Web stubs for the CLI OAuth/SSO callback-server entry points exported
// from `package:flutter_agent_harness/io.dart`. The real implementations
// (lib/src/cli/codemie_sso_server.dart, lib/src/cli/chatgpt_oauth_server.dart)
// bind local HTTP servers via dart:io, which cannot compile for the web;
// this file is selected by the conditional import in codemie_sso_flow.dart
// and chatgpt_oauth_flow.dart so the web build stays green. The flows
// themselves are gated behind `Platform.isMacOS` checks, so these stubs are
// never reached at runtime on the web.

/// Always throws on the web — the desktop CLI flow needs a local server.
Never runCodeMieSsoCliFlow({
  required String codeMieUrl,
  required void Function(String) onStatus,
  Future<bool> Function(String)? openBrowserFn,
}) =>
    throw UnsupportedError(
      'CodeMie SSO sign-in is not supported on the web platform.',
    );

/// Always throws on the web — the desktop CLI flow needs a local server.
Never runChatGptOAuthCliFlow({
  required void Function(String) onStatus,
  Future<bool> Function(String)? openBrowserFn,
  Future<void> Function({
    required String code,
    required String redirectUri,
    required String verifier,
  })? exchangeFn,
  Duration? timeout,
}) =>
    throw UnsupportedError(
      'ChatGPT sign-in is not supported on the web platform.',
    );

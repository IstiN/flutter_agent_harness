import 'package:http/http.dart' as http;

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
}) => throw UnsupportedError(
  'CodeMie SSO sign-in is not supported on the web platform.',
);

/// Web stub for the loopback SSO callback server (dart:io only).
class CodeMieSsoCallbackServer {
  /// Always throws on the web.
  Future<int> start({Duration timeout = const Duration(minutes: 5)}) =>
      throw UnsupportedError('Local servers are not supported on the web.');

  /// Always throws on the web.
  Future<String?> waitForToken() =>
      throw UnsupportedError('Local servers are not supported on the web.');

  /// No-op on the web.
  Future<void> close() async {}
}

/// Web stub of the OAuth callback record — never constructed on the web
/// (the ChatGPT flows are gated behind non-web platform checks).
class ChatGptOAuthCallback {
  const ChatGptOAuthCallback({
    this.code,
    this.state,
    this.error,
    this.errorDescription,
  });

  final String? code;
  final String? state;
  final String? error;
  final String? errorDescription;
}

/// Web stub of the loopback OAuth callback server (dart:io only). The
/// issue #861 system-auth-session hop references this type from the
/// shared flow file; the web build never reaches it (the matrix refuses
/// the web surface before any hop runs).
class ChatGptOAuthLocalCallbackServer {
  /// Always throws on the web.
  Future<String> start({Duration timeout = const Duration(minutes: 5)}) =>
      throw UnsupportedError('Local servers are not supported on the web.');

  /// Always throws on the web.
  Future<ChatGptOAuthCallback?> waitForCallback() =>
      throw UnsupportedError('Local servers are not supported on the web.');

  /// No-op on the web.
  Future<void> close() async {}
}

/// Always throws on the web — the desktop CLI flow needs a local server.
Never runChatGptOAuthCliFlow({
  required void Function(String) onStatus,
  Future<bool> Function(String)? openBrowserFn,
  Future<void> Function({
    required String code,
    required String redirectUri,
    required String verifier,
  })?
  exchangeFn,
  Duration? timeout,
}) => throw UnsupportedError(
  'ChatGPT sign-in is not supported on the web platform.',
);

/// Web stub of the IO implementation's surface-cancel exception — never
/// constructed on the web (the AIIN flow throws before any surface opens).
final class AiinSurfaceClosedException implements Exception {}

/// Always throws on the web — the AIIN connect flow needs a local server.
Never runAiinConnectCliFlow({
  required void Function(String) onStatus,
  http.Client? client,
  Future<bool> Function(String)? openBrowserFn,
  void Function()? onCallback,
  bool cancelWhenOpenSettles = false,
  Duration? timeout,
}) => throw UnsupportedError(
  'AIIN sign-in is not supported on the web platform.',
);

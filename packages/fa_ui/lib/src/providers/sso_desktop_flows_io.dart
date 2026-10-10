// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The REAL desktop sign-in hops behind [FaUiSso] (issue #1321): thin
/// wrappers over the CLI's loopback-callback flows — the exact functions
/// the CLI runs (`runCodeMieSsoCliFlow`, `runChatGptOAuthCliFlow`,
/// `runAiinConnectCliFlow`). No flow logic lives here: endpoints, token
/// exchange, and error surfaces stay in the core package (the
/// architecture-boundary contract on #1321); fa_ui only binds them to
/// widgets.
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show AiinConnectResult, ChatGptOAuthCredentials, CodeMieSsoCredentials;
import 'package:flutter_agent_harness/io.dart'
    show runAiinConnectCliFlow, runChatGptOAuthCliFlow, runCodeMieSsoCliFlow;

/// Refuses the desktop hops on non-desktop platforms — LOUDLY.
///
/// `dart.library.io` is also true on iOS/Android, but the core flows'
/// browser hop only shells out (`open`/`xdg-open`/`start`): on a phone it
/// cannot launch anything, and the loopback callback server would sit out
/// its full 5-minute timeout with the status lines reaching no user
/// surface. Throwing [UnsupportedError] here routes the mobile failure
/// onto the already-tested "not available on this platform" snack path
/// (issue #1321 review: a mobile host adopting the bundle must get a
/// named refusal, never a silent hang). Uses Flutter's
/// [defaultTargetPlatform] so tests can force the mobile branches.
void _requireDesktop(String provider) {
  switch (defaultTargetPlatform) {
    case TargetPlatform.macOS:
    case TargetPlatform.linux:
    case TargetPlatform.windows:
      return;
    case TargetPlatform.iOS:
    case TargetPlatform.android:
    case TargetPlatform.fuchsia:
      throw UnsupportedError(
        '$provider sign-in needs a desktop platform (a browser plus a '
        'localhost callback server); pass your own WebView-backed '
        'callback on this platform.',
      );
  }
}

/// Runs the CodeMie browser SSO (localhost callback) — the CLI flow.
///
/// `shouldOpenBrowserFn: () => true`: a desktop app always has a display —
/// the CLI's headless auto-detect (stdout TTY probe) must not gate the
/// launch here (gh-1450).
Future<CodeMieSsoCredentials?> desktopCodeMieSso(
  String orgUrl,
  void Function(String) onStatus,
) {
  _requireDesktop('CodeMie');
  return runCodeMieSsoCliFlow(
    codeMieUrl: orgUrl,
    onStatus: onStatus,
    shouldOpenBrowserFn: () => true,
  );
}

/// Runs the ChatGPT (Codex) OAuth (localhost callback + PKCE) — the CLI
/// flow. Always launches (desktop host — see [desktopCodeMieSso]).
Future<ChatGptOAuthCredentials?> desktopChatGptOAuth(
  void Function(String) onStatus,
) {
  _requireDesktop('ChatGPT');
  return runChatGptOAuthCliFlow(
    onStatus: onStatus,
    shouldOpenBrowserFn: () => true,
  );
}

/// Runs the AIIN sign-in + API-key auto-register (localhost callback) —
/// the CLI flow. Always launches (desktop host — see [desktopCodeMieSso]).
Future<AiinConnectResult?> desktopAiinConnect(void Function(String) onStatus) {
  _requireDesktop('AIIN');
  return runAiinConnectCliFlow(
    onStatus: onStatus,
    shouldOpenBrowserFn: () => true,
  );
}

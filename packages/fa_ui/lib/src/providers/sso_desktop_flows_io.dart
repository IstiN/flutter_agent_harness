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

import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show AiinConnectResult, ChatGptOAuthCredentials, CodeMieSsoCredentials;
import 'package:flutter_agent_harness/io.dart'
    show runAiinConnectCliFlow, runChatGptOAuthCliFlow, runCodeMieSsoCliFlow;

/// Runs the CodeMie browser SSO (localhost callback) — the CLI flow.
Future<CodeMieSsoCredentials?> desktopCodeMieSso(
  String orgUrl,
  void Function(String) onStatus,
) => runCodeMieSsoCliFlow(codeMieUrl: orgUrl, onStatus: onStatus);

/// Runs the ChatGPT (Codex) OAuth (localhost callback + PKCE) — the CLI
/// flow.
Future<ChatGptOAuthCredentials?> desktopChatGptOAuth(
  void Function(String) onStatus,
) => runChatGptOAuthCliFlow(onStatus: onStatus);

/// Runs the AIIN sign-in + API-key auto-register (localhost callback) —
/// the CLI flow.
Future<AiinConnectResult?> desktopAiinConnect(void Function(String) onStatus) =>
    runAiinConnectCliFlow(onStatus: onStatus);

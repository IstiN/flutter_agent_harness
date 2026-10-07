// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Web stubs for the desktop sign-in hops behind [FaUiSso] (issue #1321).
///
/// The real hops (`sso_desktop_flows_io.dart`) reuse the CLI's loopback
/// callback-server flows from `package:flutter_agent_harness/io.dart`,
/// which cannot compile for the web — this file is selected by the
/// conditional export instead. Every stub throws [UnsupportedError]; the
/// [FaUiSso] connect methods catch it and surface the unavailable-platform
/// snack, matching the flutter_app host's web gating.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

Never _unsupported(String what) => throw UnsupportedError(
  '$what sign-in needs the desktop app (a localhost callback server); '
  'it is not available on the web platform.',
);

/// Web stub — never returns; throws [UnsupportedError].
Future<CodeMieSsoCredentials?> desktopCodeMieSso(
  String orgUrl,
  void Function(String) onStatus,
) => _unsupported('CodeMie');

/// Web stub — never returns; throws [UnsupportedError].
Future<ChatGptOAuthCredentials?> desktopChatGptOAuth(
  void Function(String) onStatus,
) => _unsupported('ChatGPT');

/// Web stub — never returns; throws [UnsupportedError].
Future<AiinConnectResult?> desktopAiinConnect(void Function(String) onStatus) =>
    _unsupported('AIIN');

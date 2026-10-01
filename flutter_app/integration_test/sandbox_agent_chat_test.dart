// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by an MIT-style license that can be
// found in the LICENSE file.
//
/// AC7 mini-test entry for the iOS-simulator lane (issue #1156). The probe
/// body lives in `e2e_support/sandbox_agent_chat_probe.dart` so the host
/// entry (`test/sandbox_agent_chat_host_test.dart`) can prove the same chat
/// loop on the desktop shell.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'e2e_support/sandbox_agent_chat_probe.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('chat loop drives the sandbox shell via the bash tool', (
    tester,
  ) async {
    await sandboxAgentChatProbe(
      tester,
      screenshot: (name) =>
          IntegrationTestWidgetsFlutterBinding.instance.takeScreenshot(name),
    );
  });
}

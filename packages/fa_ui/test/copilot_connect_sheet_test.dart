// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa_llm/fa_llm.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _deviceCode = CopilotDeviceCode(
  deviceCode: 'dev123',
  userCode: 'ABCD-1234',
  verificationUri: 'https://github.com/login/device',
  expiresIn: 900,
  interval: Duration(seconds: 5),
);

CopilotConnectCallbacks _fakes({
  Future<CopilotDeviceCode> Function()? start,
  Future<String> Function(CopilotDeviceCode deviceCode)? poll,
  Future<String> Function(String githubToken)? login,
}) {
  return CopilotConnectCallbacks(
    requestDeviceCode: start ?? (() async => _deviceCode),
    pollAccessToken: poll ?? ((_) async => 'gho_token'),
    fetchLogin: login ?? ((_) async => 'octocat'),
  );
}

Future<void> _pump(
  WidgetTester tester,
  CopilotConnectCallbacks callbacks,
  ValueChanged<CopilotConnectResult> onResult,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showCopilotConnectSheet(
              context: context,
              callbacks: callbacks,
              onResult: onResult,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('device flow: code display, entry name default, result payload', (
    tester,
  ) async {
    CopilotConnectResult? result;
    await _pump(tester, _fakes(), (r) => result = r);

    await tester.tap(find.text('Sign in with GitHub'));
    await tester.pumpAndSettle();

    // The fake poll resolves immediately, so the sheet lands on the form
    // (the waiting step with the code display is covered by the cancel
    // test below). The resolved login seeds the entry name.

    // The poll completed: the form shows the resolved login as the default
    // entry name, the individual plan preselected.
    expect(find.widgetWithText(TextField, 'copilot-octocat'), findsOneWidget);
    expect(find.text('Individual'), findsOneWidget);

    await tester.tap(find.text('Connect Copilot'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.githubToken, 'gho_token');
    expect(result!.login, 'octocat');
    expect(result!.entryName, 'copilot-octocat');
    expect(result!.accountType, CopilotAccountType.individual);
    expect(result!.baseUrlOverride, isNull);
    // The sheet popped after finishing.
    expect(find.text('Connect Copilot'), findsNothing);
  });

  testWidgets(
    'pending and slow_down keep the sheet waiting, then it finishes',
    (tester) async {
      // The REAL poll loop over a scripted GitHub: pending → slow_down → token.
      final responses = [
        '{"error":"authorization_pending"}',
        '{"error":"slow_down"}',
        '{"access_token":"gho_slow"}',
      ];
      var call = 0;
      final client = MockClient(
        (_) async => http.Response(responses[call++ % 3], 200),
      );
      final waits = <Duration>[];
      final callbacks = CopilotConnectCallbacks(
        requestDeviceCode: () async => _deviceCode,
        pollAccessToken: (deviceCode) => pollCopilotAccessToken(
          deviceCode: deviceCode.deviceCode,
          expiresIn: 900,
          client: client,
          delay: (wait) async {
            waits.add(wait);
          },
        ),
        fetchLogin: (_) async => 'octocat',
      );

      CopilotConnectResult? result;
      await _pump(tester, callbacks, (r) => result = r);

      await tester.tap(find.text('Sign in with GitHub'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 16));
      await tester.pumpAndSettle();

      // slow_down grew the interval: 5s after pending, 10s after slow_down.
      expect(waits, [const Duration(seconds: 5), const Duration(seconds: 10)]);

      await tester.tap(find.text('Connect Copilot'));
      await tester.pumpAndSettle();
      expect(result!.githubToken, 'gho_slow');
    },
  );

  testWidgets('paste-token mode skips start and poll', (tester) async {
    var started = false;
    var polled = false;
    CopilotConnectResult? result;
    await _pump(
      tester,
      _fakes(
        start: () async {
          started = true;
          return _deviceCode;
        },
        poll: (_) async {
          polled = true;
          return 'gho_x';
        },
      ),
      (r) => result = r,
    );

    await tester.tap(find.text('Paste a GitHub token instead'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'GitHub token'),
      'ghp_pasted',
    );
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(started, isFalse);
    expect(polled, isFalse);
    await tester.tap(find.text('Connect Copilot'));
    await tester.pumpAndSettle();
    expect(result!.githubToken, 'ghp_pasted');
  });

  testWidgets('an endpoint-disabled exchange failure surfaces a clear message '
      'and the paste-token path', (tester) async {
    CopilotConnectResult? result;
    await _pump(
      tester,
      _fakes(
        poll: (_) => throw CopilotTokenExchangeException(
          'Copilot token exchange failed: 403 endpoint disabled',
        ),
      ),
      (r) => result = r,
    );

    await tester.tap(find.text('Sign in with GitHub'));
    await tester.pumpAndSettle();

    expect(find.textContaining('disabled'), findsWidgets);
    expect(find.text('Paste a GitHub token instead'), findsOneWidget);

    // The flow is recoverable through the paste-token path.
    await tester.tap(find.text('Paste a GitHub token instead'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'GitHub token'),
      'ghp_after_error',
    );
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect Copilot'));
    await tester.pumpAndSettle();
    expect(result!.githubToken, 'ghp_after_error');
  });

  testWidgets('cancelling mid-poll pops cleanly and never reports', (
    tester,
  ) async {
    final pollGate = Completer<String>();
    var reported = 0;
    await _pump(
      tester,
      _fakes(poll: (_) => pollGate.future),
      (_) => reported++,
    );
    // Start the device flow; the poll future never settles until the gate
    // below. Pump fixed amounts (a live spinner never lets pumpAndSettle
    // settle).
    await tester.tap(find.text('Sign in with GitHub'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('ABCD-1234'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('ABCD-1234'), findsNothing);

    // The poll settles after the sheet is gone: no result may escape.
    pollGate.complete('gho_late');
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(reported, 0);
  });

  testWidgets('plan picker: business preselects nothing custom; custom mode '
      'collects a base URL override', (tester) async {
    CopilotConnectResult? result;
    await _pump(tester, _fakes(), (r) => result = r);

    await tester.tap(find.text('Sign in with GitHub'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom endpoint'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Custom Copilot API base URL'),
      'https://copilot-proxy.corp/api',
    );
    await tester.tap(find.text('Connect Copilot'));
    await tester.pumpAndSettle();

    expect(result!.accountType, CopilotAccountType.individual);
    expect(result!.baseUrlOverride, 'https://copilot-proxy.corp/api');
  });

  testWidgets('business plan is reported in the result', (tester) async {
    CopilotConnectResult? result;
    await _pump(tester, _fakes(), (r) => result = r);

    await tester.tap(find.text('Sign in with GitHub'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Business'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect Copilot'));
    await tester.pumpAndSettle();

    expect(result!.accountType, CopilotAccountType.business);
    expect(result!.baseUrlOverride, isNull);
  });
}

// Issue #1117 review follow-up: the receiver seam — `bind()`'s
// window.onMessage + BroadcastChannel + localStorage subscriptions, the
// expected-state gate, `_completeGrant`'s exactly-once + popup-close
// behavior, and `close()` teardown — exercised against REAL browser
// primitives, since the grant hand-off is browser-only by nature.
//
// Runs on the CHROME platform only (dart:html receivers):
//   flutter test test/web --platform chrome
// (the office-addin CI job already runs the test/web suite this way).
@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

import 'package:fa/network/auth_loopback_web.dart';
import 'package:fa/network/auth_flow.dart';
import 'package:fa/network/oauth_callback_message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Dead local port: if the headless browser happens to allow
  // gesture-less window.open, the popup navigates to an instant
  // connection-refused — never the network.
  final authUrl = Uri.parse('http://127.0.0.1:1/?state=st-1&client_id=x');

  /// The production seam: bind → openAuthUrl. The gesture-less popup
  /// open itself usually throws (blocked) — the flow handles that
  /// through the same receiver — but the expected state is captured
  /// BEFORE the open attempt either way.
  Future<WebOAuthReceiver> bindWithState() async {
    final receiver = await (startOAuthCallbackReceiverImpl()
        as Future<WebOAuthReceiver>);
    try {
      await openAuthUrlImpl(authUrl);
    } on AuthFlowException {
      // Popup blocked without a user gesture — expected headless.
    }
    return receiver;
  }

  Map<String, Object?> grant(String state) => {
    'type': faOAuthMessageType,
    'code': 'c-1',
    'state': state,
    'error': null,
    'error_description': null,
    'ts': DateTime.now().millisecondsSinceEpoch,
  };

  test('a trusted postMessage with the expected state completes the flow',
      () async {
    final receiver = await bindWithState();
    html.window.postMessage(grant('st-1'), html.window.location.origin);
    final callback = await receiver.callback.timeout(
      const Duration(seconds: 5),
    );
    expect(callback.host, html.window.location.host);
    expect(callback.path, '/oauth/callback');
    expect(callback.queryParameters['code'], 'c-1');
    expect(callback.queryParameters['state'], 'st-1');
    receiver.close();
  });

  test('a hand-off echoing another flow\'s state is ignored', () async {
    final receiver = await bindWithState();
    // Trusted origin (our own window), but the state belongs to a
    // different flow — must not complete, must not clobber.
    html.window.postMessage(grant('st-forged'), html.window.location.origin);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(receiver.isCompleted, isFalse);
    // The real grant still lands afterwards.
    html.window.postMessage(grant('st-1'), html.window.location.origin);
    final callback = await receiver.callback.timeout(
      const Duration(seconds: 5),
    );
    expect(callback.queryParameters['state'], 'st-1');
    receiver.close();
  });

  test('the localStorage hand-off is consumed fresh and cleared', () async {
    final receiver = await bindWithState();
    html.window.localStorage['fa_oauth_code'] = jsonEncode(grant('st-1'));
    final callback = await receiver.callback.timeout(
      const Duration(seconds: 5),
    );
    expect(callback.queryParameters['code'], 'c-1');
    // Consumed, not left for a later flow.
    expect(html.window.localStorage['fa_oauth_code'], isNull);
    receiver.close();
  });

  test('close() tears the listeners down — no late completion', () async {
    final receiver = await bindWithState();
    receiver.close();
    html.window.postMessage(grant('st-1'), html.window.location.origin);
    html.window.localStorage['fa_oauth_code'] = jsonEncode(grant('st-1'));
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(receiver.isCompleted, isFalse);
  });
}

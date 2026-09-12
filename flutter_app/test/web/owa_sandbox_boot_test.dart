// Boot in a history-less iframe — the OWA sandbox reproduction (issue
// #202): its taskpane iframes ship a `history` stub without the mutation
// methods, and the web engine's default deep-link URL sync died on
// `replaceState` mid-boot, graying the pane before Office.onReady.
//
// Runs on the CHROME platform only (the guards touch real web bindings):
//   flutter test test/web --platform chrome --dart-define=FA_HOST=office
// The FA_HOST=office flag compiles the real boot seam in (the office
// branch of office_boot_web.dart) so the onReady-first path is exercised.
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:fa/services/office/office_boot.dart';
import 'package:fa/services/web/sandbox_url_strategy_web.dart';
import 'package:fa_office_agent/fa_office_agent.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

void main() {
  // Order matters: the healthy-history probe runs BEFORE the frame strips
  // the History API (state persists across tests in one browser page).
  test('healthy frame: the History probe reports usable', () {
    expect(historyApiUsable(), isTrue);
  });

  test('history-less frame: probe fails, no-op strategy installs', () async {
    // The OWA reproduction: the methods exist on the prototype; OWA's
    // sandbox effectively removes them. Shadow with undefined on the
    // instance — `q.replaceState is not a function`, exactly the crash.
    (web.window.history as JSObject).setProperty('replaceState'.toJS, null);
    (web.window.history as JSObject).setProperty('pushState'.toJS, null);
    addTearDown(() {
      final history = web.window.history as JSObject;
      history.delete('replaceState'.toJS);
      history.delete('pushState'.toJS);
    });

    expect(historyApiUsable(), isFalse);

    installSandboxSafeUrlStrategy();
    final strategy = ui_web.urlStrategy;
    expect(strategy, isA<NoOpUrlStrategy>());

    // Every mutation the engine's deep-link sync performs must be a
    // silent no-op against the broken History API, while the entry
    // bookkeeping still round-trips through the in-memory store (the
    // engine null-asserts the restored state mid-boot).
    strategy!.pushState(null, '', '/turn-1');
    expect(strategy.getState(), isNull);
    final entry = <String, String>{'route': '/turn-2'};
    strategy.replaceState(entry, '', '/turn-2');
    expect(strategy.getState(), same(entry));
    await strategy.go(-1);
    expect(strategy.getPath(), '/');
    expect(
      web.window.history.state,
      isNull,
      reason: 'the real History API stays untouched',
    );
    // Installing twice is idempotent (the main() prologue plus any later
    // defensive call must not stack strategies).
    installSandboxSafeUrlStrategy();
    expect(ui_web.urlStrategy, same(strategy));
  });

  test('onReady-first: bootOfficeApi starts the handshake once, memoizes '
      'the instance, and never lets a missing Office.js crash boot', () {
    // Chrome test page: no Office.js — the handshake must resolve into the
    // memoized office_unavailable failure, surfacing per tool call later,
    // NEVER as an unhandled boot error (the gray pane of issue #202).
    final first = bootOfficeApi();
    expect(first, isNotNull);
    expect(first!.isReady, isFalse);
    final second = bootOfficeApi();
    expect(second, same(first), reason: 'single handshake, one api');
    expectLater(first.onReady(), throwsA(isA<OfficeApiException>()));
  });
}
